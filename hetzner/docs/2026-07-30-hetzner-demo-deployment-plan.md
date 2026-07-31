# Hetzner Demo Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the whole web_ai stack as a public demo at https://jinifai.com from one €5.99/mo Hetzner VPS, verified end-to-end including real RunPod image generation.

**Architecture:** Docker Compose on a single `cx23`. Caddy terminates TLS and path-routes to three backends and an nginx-served SPA on one origin. Postgres/Redis/RabbitMQ stay on the internal Docker network with no published ports. Container build files live in `hetzner_container/` inside each service repo; orchestration and lifecycle scripts live in `deployment/hetzner`.

**Tech Stack:** Docker Compose v2, Caddy 2, nginx, Django 4.1 + gunicorn, FastAPI + uvicorn, React 16 (CRA), Postgres 14, Redis 7, RabbitMQ 3.11, Hetzner Cloud API, Bash.

**Spec:** `deployment/hetzner/docs/2026-07-30-hetzner-demo-deployment-design.md`

## Global Constraints

Every task's requirements implicitly include this section.

- **Domain:** `jinifai.com` (apex). `www.jinifai.com` 301-redirects to it.
- **Server:** type `cx23`, location `nbg1`, image `ubuntu-24.04`, name `web-ai-demo`.
- **Shared JWT key:** `auth.DJANGO_SECRET_KEY` == `payments.JWT_SECRET` == `pre_inference.JWT_SECRET` == `${JWT_SIGNING_KEY}`. `payments.DJANGO_SECRET_KEY` is a *different* value, `${PAYMENTS_DJANGO_SECRET_KEY}`.
- **`RABBITMQ_BROKER_ID` must never be set.** Setting it switches `consumer.py`/`publisher.py` to the AmazonMQ TLS path and breaks messaging.
- **`AUTH_PRJ_MODE=prod`** in both `auth` and `payments` (payments reuses that variable name).
- **`REACT_APP_DEMO_LOGIN` and `REACT_APP_DEMO_PASSWORD` build as empty strings** so the login form renders blank. No credential of any kind may appear in the bundle except the knowingly-accepted `REACT_APP_RUNPOD_API_KEY`.
- **Never publish** 5432, 6379, 5672 or 15672 to any host interface. Public ports are 80/443 only, plus `127.0.0.1:8000` for `auth` (admin over SSH).
- **Pinned base images:** `python:3.10.7-bullseye` (auth), `python:3.10.10-bullseye` (payments, pre_inference), `node:18.12.1-bullseye`, `nginx:1.27-alpine`, `caddy:2.8-alpine`, `postgres:14.6-bullseye`, `redis:7.0-bullseye`, `rabbitmq:3.11.9-management`.
- **Line endings:** `core.autocrlf=true` is set globally on this workstation, which would rewrite `*.sh` to CRLF on any checkout and produce `bad interpreter` inside Linux containers. Every repo touched gets a `.gitattributes` pinning `*.sh` to LF.
- **Secrets:** `deployment/hetzner/.secrets/` and `deployment/hetzner/.env` are gitignored and must never be staged. Verify with `git status --porcelain` before every commit.
- **Branches:** commit to `hetzner-demo-deployment` in the `deployment` repo (already created) and to a new `hetzner-container` branch in each service repo. Do not push; the user has not asked for that.
- **Verification is evidence-based.** Never mark a step done from expectation — run the command and read the output.

## File Structure

| file | responsibility |
|---|---|
| `<repo>/hetzner_container/Dockerfile` | how that one service becomes a production image |
| `<repo>/hetzner_container/entrypoint.sh` | migrate + start server (auth, payments only) |
| `<repo>/hetzner_container/nginx.conf` | SPA serving rules (web_client only) |
| `<repo>/.dockerignore` | keeps `.env`, `node_modules`, `.git` out of build contexts. Must sit at the context root — Docker gives no choice |
| `<repo>/.gitattributes` | LF for `*.sh` |
| `deployment/hetzner/docker-compose.yml` | service graph, env wiring, port policy |
| `deployment/hetzner/Caddyfile` | TLS + path routing |
| `deployment/hetzner/init-databases.sql` | creates `auth_prj`, `payments_prj` |
| `deployment/hetzner/seed_accounts.py` | idempotent superuser + demo user |
| `deployment/hetzner/lib/common.sh` | shared: env loading, SSH args, logging, secret generation |
| `deployment/hetzner/provision.sh` | create SSH key, firewall, server; generate `.env` |
| `deployment/hetzner/cloud-init.yaml` | docker, swap, `/opt/web_ai` |
| `deployment/hetzner/deploy.sh` | ship source, build, up, seed |
| `deployment/hetzner/verify.sh` | the acceptance gate |
| `deployment/hetzner/destroy.sh` | delete server, firewall, key |
| `deployment/hetzner/ssh.sh` | SSH wrapper using the generated key |
| `deployment/hetzner/README.md` | runbook |

---

### Task 1: Production images for the three Python services

Builds and locally proves the `auth`, `payments` and `pre_inference` images. Grouped because they share one Dockerfile shape and one `.dockerignore`; a reviewer would accept or reject them together.

**Files:**
- Create: `auth/auth_src/hetzner_container/Dockerfile`
- Create: `auth/auth_src/hetzner_container/entrypoint.sh`
- Create: `auth/auth_src/.dockerignore`
- Create: `auth/auth_src/.gitattributes`
- Create: `payments/payments_src/hetzner_container/Dockerfile`
- Create: `payments/payments_src/hetzner_container/entrypoint.sh`
- Create: `payments/payments_src/.dockerignore`
- Create: `payments/payments_src/.gitattributes`
- Create: `pre_inference/pre_inference_src/hetzner_container/Dockerfile`
- Create: `pre_inference/pre_inference_src/.dockerignore`
- Create: `pre_inference/pre_inference_src/.gitattributes`

**Interfaces:**
- Produces: images buildable with context `<service_src>` and `dockerfile: hetzner_container/Dockerfile`. `auth` listens on 8000, `payments` 8001, `pre_inference` 8002. `auth` and `payments` run migrations in their entrypoint before serving.
- Consumes: nothing.

- [ ] **Step 1: Write the `.gitattributes` for all three repos**

Identical content in `auth/auth_src/.gitattributes`, `payments/payments_src/.gitattributes`, `pre_inference/pre_inference_src/.gitattributes`:

```gitattributes
# core.autocrlf=true on the dev workstation would otherwise rewrite these to CRLF on
# checkout, which makes Linux containers fail with "bad interpreter: no such file or directory".
* text=auto
*.sh text eol=lf
Dockerfile text eol=lf
```

- [ ] **Step 2: Write the `.dockerignore` for all three repos**

Identical content in each of the three service source roots:

```gitignore
.git
.gitignore
.gitattributes
.idea
.github
__pycache__
**/__pycache__
*.pyc
# Never bake development secrets into a production image. Container env supplies everything;
# django-environ read_env() and python-dotenv load_dotenv() both defer to existing env vars.
.env
*.env
db.sqlite3
app.log
py3107
py31010
dev_container
aws_ecs_container
```

- [ ] **Step 3: Write `auth/auth_src/hetzner_container/Dockerfile`**

```dockerfile
# Production image for the auth service. Differs from dev_container/Dockerfile in three ways:
# no source bind mount (code is baked in), no gunicorn --reload, and no vim/htop/gdal.
# gdal-bin/libproj-dev are dropped deliberately: nothing in requirements.txt is geospatial,
# and they cost ~300MB and several minutes of build time on a 2-vCPU server.
FROM python:3.10.7-bullseye

WORKDIR /usr/src/auth_src

# psycopg2 (source distribution, not -binary) needs pg_config, which the non-slim
# python image already provides via buildpack-deps. No apt-get needed.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY ./ ./

RUN chmod +x hetzner_container/entrypoint.sh

EXPOSE 8000

ENTRYPOINT ["hetzner_container/entrypoint.sh"]
```

- [ ] **Step 4: Write `auth/auth_src/hetzner_container/entrypoint.sh`**

Must be saved with LF endings.

```sh
#!/bin/sh
# Production entrypoint for the auth service.
# Note: the EOL characters of this file must be UNIX style (LF).
set -e

echo "Applying database migrations..."
python manage.py migrate --noinput

# The RabbitMQ consumer receives payment events from the payments service and upgrades the
# user's tier. Under gunicorn, Django's RUN_MAIN is unset, so the thread must be started here
# rather than from an AppConfig.ready() hook.
echo "Starting RabbitMQ consumer thread..."
python manage.py start_consumer_thread &

# exec so gunicorn becomes PID 1 and receives SIGTERM directly on `docker compose down`.
# Accounts are NOT created here; deploy.sh runs seed_accounts.py so that a redeploy
# never silently resets a password.
exec gunicorn auth_prj.wsgi \
  --bind 0.0.0.0:8000 \
  --workers 2 \
  --log-level info \
  --capture-output \
  --timeout 60
```

- [ ] **Step 5: Write `payments/payments_src/hetzner_container/Dockerfile`**

```dockerfile
# Production image for the payments service. See auth/auth_src/hetzner_container/Dockerfile
# for why no apt-get layer is needed.
FROM python:3.10.10-bullseye

WORKDIR /usr/src/payments_src

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY ./ ./

RUN chmod +x hetzner_container/entrypoint.sh

EXPOSE 8001

ENTRYPOINT ["hetzner_container/entrypoint.sh"]
```

- [ ] **Step 6: Write `payments/payments_src/hetzner_container/entrypoint.sh`**

LF endings. Payments only publishes to RabbitMQ, so there is no consumer thread here.

```sh
#!/bin/sh
# Production entrypoint for the payments service.
# Note: the EOL characters of this file must be UNIX style (LF).
set -e

echo "Applying database migrations..."
python manage.py migrate --noinput

exec gunicorn payments_prj.wsgi \
  --bind 0.0.0.0:8001 \
  --workers 2 \
  --log-level info \
  --capture-output \
  --timeout 60
```

- [ ] **Step 7: Write `pre_inference/pre_inference_src/hetzner_container/Dockerfile`**

```dockerfile
# Production image for the pre_inference service (FastAPI). No entrypoint script: there are
# no migrations and uvicorn is started directly.
FROM python:3.10.10-bullseye

WORKDIR /usr/src/pre_inference_src

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY ./ ./

EXPOSE 8002

# No --reload: WATCHFILES_FORCE_POLLING in the dev compose exists only for hot reload on Windows.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8002", "--timeout-keep-alive", "60"]
```

- [ ] **Step 8: Run the verification BEFORE building, to confirm it fails**

The three images do not exist yet, so this must fail. Run:

```bash
cd /d/Projects/web_ai
docker image inspect web-ai-auth:test >/dev/null 2>&1 && echo "EXISTS" || echo "ABSENT (expected)"
```

Expected: `ABSENT (expected)`

- [ ] **Step 9: Build the three images**

```bash
cd /d/Projects/web_ai
docker build -t web-ai-auth:test          -f auth/auth_src/hetzner_container/Dockerfile                     auth/auth_src
docker build -t web-ai-payments:test      -f payments/payments_src/hetzner_container/Dockerfile             payments/payments_src
docker build -t web-ai-preinference:test  -f pre_inference/pre_inference_src/hetzner_container/Dockerfile   pre_inference/pre_inference_src
```

Expected: three successful builds. If `psycopg2` fails to compile, the assumption that the non-slim python image ships `pg_config` is wrong — add `RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev && rm -rf /var/lib/apt/lists/*` before the `pip install` layer and rebuild.

- [ ] **Step 10: Verify the images are correct**

Four properties: dependencies importable, dev `.env` excluded, entrypoint has no CR bytes, entrypoint executable.

```bash
for img in web-ai-auth:test web-ai-payments:test; do
  echo "=== $img"
  docker run --rm --entrypoint python "$img" -c "import django, psycopg2, pika; print('imports ok', django.get_version())"
  docker run --rm --entrypoint sh "$img" -c 'test ! -f .env && echo "no dev .env baked in: ok"'
  docker run --rm --entrypoint sh "$img" -c 'head -1 hetzner_container/entrypoint.sh | od -c | grep -q "\\\\r" && echo "CRLF FOUND - FAIL" || echo "LF endings: ok"'
  docker run --rm --entrypoint sh "$img" -c 'test -x hetzner_container/entrypoint.sh && echo "executable: ok"'
done
echo "=== web-ai-preinference:test"
docker run --rm --entrypoint python web-ai-preinference:test -c "import fastapi, slowapi, redis, jwt; print('imports ok')"
docker run --rm --entrypoint sh web-ai-preinference:test -c 'test ! -f .env && echo "no dev .env baked in: ok"'
```

Expected: every line reports `ok`; no `CRLF FOUND` and no `ImportError`.

- [ ] **Step 11: Commit, in each of the three repos**

Confirm no secrets are staged first.

```bash
cd /d/Projects/web_ai/auth/auth_src
git checkout -b hetzner-container
git status --porcelain            # must NOT list .env or prod.env
git add hetzner_container .dockerignore .gitattributes
git commit -m "Add hetzner_container production image for auth.

Bakes the source in, runs migrations and the RabbitMQ consumer from the
entrypoint, and serves via gunicorn without --reload."
```

Repeat identically in `payments/payments_src` and `pre_inference/pre_inference_src`, adjusting the service name in the message.

---

### Task 2: Production image for the web_client SPA

**Files:**
- Create: `web_client/web_client_src/hetzner_container/Dockerfile`
- Create: `web_client/web_client_src/hetzner_container/nginx.conf`
- Create: `web_client/web_client_src/.dockerignore`
- Create: `web_client/web_client_src/.gitattributes`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: an image serving the built SPA on port 80. Accepts build args `REACT_APP_AUTH_API_SERVICE`, `REACT_APP_PAYMENTS_API_SERVICE`, `REACT_APP_TEXT_TO_IMG_API_SERVICE`, `REACT_APP_RUNPOD_API_KEY`, `REACT_APP_DEMO_LOGIN`, `REACT_APP_DEMO_PASSWORD`.

- [ ] **Step 1: Write `web_client/web_client_src/.gitattributes`**

```gitattributes
* text=auto
*.sh text eol=lf
Dockerfile text eol=lf
```

- [ ] **Step 2: Write `web_client/web_client_src/.dockerignore`**

`node_modules` matters most here: without it, `COPY ./ ./` would overwrite the freshly installed modules with the host's, and the context would balloon from ~5 MB to hundreds.

```gitignore
node_modules
build
.git
.gitignore
.gitattributes
.idea
.github
.env
*.env
!.env.example
dev_container
npm-debug.log*
```

- [ ] **Step 3: Write `web_client/web_client_src/hetzner_container/Dockerfile`**

```dockerfile
# Multi-stage production image for the React SPA.
# The dev image ships node, node_modules and the source and runs the CRA dev server (~1.5GB).
# Here node only builds; the runtime image is nginx plus static files (~50MB).

FROM node:18.12.1-bullseye AS build

WORKDIR /usr/src/web_client_src

# npm install (not npm ci) to match the dev image: the lockfile predates npm 7's strict
# peer-dependency resolution and npm ci would reject it.
COPY package.json package-lock.json ./
RUN npm install --no-audit --no-fund

COPY ./ ./

# CRA inlines these at build time via webpack DefinePlugin; they are baked into the bundle and
# cannot be changed without rebuilding. Shell env takes precedence over any .env file.
ARG REACT_APP_AUTH_API_SERVICE
ARG REACT_APP_PAYMENTS_API_SERVICE
ARG REACT_APP_TEXT_TO_IMG_API_SERVICE
ARG REACT_APP_RUNPOD_API_KEY
# Empty on purpose: the login form must render blank rather than prefilled with credentials.
ARG REACT_APP_DEMO_LOGIN=""
ARG REACT_APP_DEMO_PASSWORD=""

ENV REACT_APP_AUTH_API_SERVICE=$REACT_APP_AUTH_API_SERVICE \
    REACT_APP_PAYMENTS_API_SERVICE=$REACT_APP_PAYMENTS_API_SERVICE \
    REACT_APP_TEXT_TO_IMG_API_SERVICE=$REACT_APP_TEXT_TO_IMG_API_SERVICE \
    REACT_APP_RUNPOD_API_KEY=$REACT_APP_RUNPOD_API_KEY \
    REACT_APP_DEMO_LOGIN=$REACT_APP_DEMO_LOGIN \
    REACT_APP_DEMO_PASSWORD=$REACT_APP_DEMO_PASSWORD \
    GENERATE_SOURCEMAP=false \
    CI=false \
    NODE_OPTIONS=--max-old-space-size=3072

# package.json runs `react-scripts --openssl-legacy-provider build`; react-scripts finds the
# `build` argument by name and forwards the leading flag to node, which is required for
# webpack 4's use of MD4 hashing under node 18's OpenSSL 3.
RUN npm run build

FROM nginx:1.27-alpine

COPY hetzner_container/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /usr/src/web_client_src/build /usr/share/nginx/html

EXPOSE 80
```

- [ ] **Step 4: Write `web_client/web_client_src/hetzner_container/nginx.conf`**

```nginx
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    # CRA emits content-hashed filenames under /static/, so these are safe to cache forever.
    location /static/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # index.html must never be cached, or a returning visitor keeps loading the previous
    # deploy's bundle references after a redeploy.
    location = /index.html {
        add_header Cache-Control "no-store";
    }

    # Client-side routing: unknown paths are React Router routes, not 404s.
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

- [ ] **Step 5: Confirm the image does not exist yet**

```bash
docker image inspect web-ai-web:test >/dev/null 2>&1 && echo "EXISTS" || echo "ABSENT (expected)"
```

Expected: `ABSENT (expected)`

- [ ] **Step 6: Build with the production build args**

Takes roughly 10 minutes; the `npm install` layer dominates.

```bash
cd /d/Projects/web_ai
docker build -t web-ai-web:test \
  -f web_client/web_client_src/hetzner_container/Dockerfile \
  --build-arg REACT_APP_AUTH_API_SERVICE=https://jinifai.com/ \
  --build-arg REACT_APP_PAYMENTS_API_SERVICE=https://jinifai.com/ \
  --build-arg REACT_APP_TEXT_TO_IMG_API_SERVICE=https://jinifai.com/api/preinference/ \
  --build-arg REACT_APP_RUNPOD_API_KEY=<RUNPOD_API_KEY> \
  web_client/web_client_src
```

Expected: `Compiled successfully` (warnings are fine), then a successful nginx stage.

- [ ] **Step 7: Verify serving behaviour and bundle contents**

```bash
docker rm -f web-ai-web-test 2>/dev/null
docker run -d --name web-ai-web-test -p 8080:80 web-ai-web:test
sleep 2
echo "root:        $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/)"
echo "has root div: $(curl -s http://localhost:8080/ | grep -c 'id="root"')"
echo "spa fallback: $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/app/some/deep/route)"
echo "missing asset 404: $(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/static/js/nope.js)"
```

Expected: `root: 200`, `has root div: 1`, `spa fallback: 200`, `missing asset 404: 404`.

- [ ] **Step 8: Verify what did and did not get baked into the bundle**

This is the evidence for the accepted-risk decision and for the empty-login-form requirement.

```bash
docker run --rm --entrypoint sh web-ai-web:test -c '
  cd /usr/share/nginx/html
  printf "api base url present : %s\n" "$(grep -rlo "https://jinifai.com" static/js | head -1)"
  printf "runpod key present   : %s\n" "$(grep -ro "<RUNPOD_API_KEY>" static/js | wc -l)"
  printf "demo password present: %s\n" "$(grep -ro "<dev-password>" static/js | wc -l)"
  printf "personal email present: %s\n" "$(grep -ro "you@example.com" static/js | wc -l)"
  printf "sourcemaps present   : %s\n" "$(ls static/js/*.map 2>/dev/null | wc -l)"
'
docker rm -f web-ai-web-test
```

Expected: api base url non-empty; **runpod key >= 1** (the accepted exposure, recorded deliberately); **demo password 0**; **personal email 0**; **sourcemaps 0**. If the demo password or personal email is non-zero, the empty-string build args did not apply — stop and fix before continuing.

- [ ] **Step 9: Commit**

```bash
cd /d/Projects/web_ai/web_client/web_client_src
git checkout -b hetzner-container
git status --porcelain            # must NOT list .env
git add hetzner_container .dockerignore .gitattributes
git commit -m "Add hetzner_container production image for web_client.

Multi-stage: node builds the CRA bundle, nginx:alpine serves it. Demo
credential build args are empty so the login form renders blank."
```

Note: `package.json` has a pre-existing uncommitted modification (the `--openssl-legacy-provider` flags) that the build depends on. Leave it unstaged — it is the user's change to commit or not, but flag it in the task report because a fresh clone of this repo would not build.

---

### Task 3: Orchestration, and a full local smoke test

Proves the whole graph works before any money is spent or any 15-minute remote build is attempted.

**Files:**
- Create: `deployment/hetzner/docker-compose.yml`
- Create: `deployment/hetzner/Caddyfile`
- Create: `deployment/hetzner/init-databases.sql`
- Create: `deployment/hetzner/seed_accounts.py`
- Create: `deployment/hetzner/.env.example`
- Create: `deployment/hetzner/lib/common.sh`

**Interfaces:**
- Consumes: the four images from Tasks 1 and 2, rebuilt here by compose from the same Dockerfiles.
- Produces: `common.sh` exposing `gen_secret`, `write_env_file <path> <domain> <acme_email>`, `load_env <path>`, `require_cmd <name>`, `log`, `die`. Compose project name `web-ai-demo`; service names `caddy`, `web`, `auth`, `payments`, `pre_inference`, `postgres`, `redis`, `rabbitmq`.

- [ ] **Step 1: Write `deployment/hetzner/init-databases.sql`**

```sql
-- Executed by the postgres image's docker-entrypoint-initdb.d hook, which runs only when the
-- data directory is empty (i.e. on the very first start of a fresh volume).
CREATE DATABASE auth_prj;
CREATE DATABASE payments_prj;
```

- [ ] **Step 2: Write `deployment/hetzner/lib/common.sh`**

```sh
#!/bin/sh
# Shared helpers for the Hetzner deployment scripts. POSIX sh, sourced not executed.

HETZNER_DIR="$(cd "$(dirname "$0")" && pwd)"
SECRETS_DIR="$HETZNER_DIR/.secrets"
ENV_FILE="$HETZNER_DIR/.env"
SERVER_JSON="$SECRETS_DIR/server.json"
SSH_KEY="$SECRETS_DIR/id_ed25519"
SERVER_NAME="web-ai-demo"
FIREWALL_NAME="web-ai-demo-fw"
SSH_KEY_NAME="web-ai-demo"
SERVER_TYPE="cx23"
SERVER_LOCATION="nbg1"
SERVER_IMAGE="ubuntu-24.04"
REMOTE_DIR="/opt/web_ai"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Git Bash on Windows ships a 2021 CA bundle that cannot validate api.hetzner.cloud.
# provision.sh downloads a current one into .secrets/; use it when present.
if [ -f "$SECRETS_DIR/cacert.pem" ]; then
  CURL_CA_BUNDLE="$SECRETS_DIR/cacert.pem"
  export CURL_CA_BUNDLE
fi

# python is needed to parse JSON responses; jq is not present on the workstation.
PY="$(command -v python3 || command -v python || true)"

json_get() {
  # usage: echo "$response" | json_get 'server.public_net.ipv4.ip'
  [ -n "$PY" ] || die "python is required to parse API responses"
  "$PY" -c '
import json,sys
path=sys.argv[1].split(".")
d=json.load(sys.stdin)
for p in path:
    if d is None: break
    d = d[int(p)] if p.isdigit() else d.get(p)
print("" if d is None else d)
' "$1"
}

gen_secret() {
  # 32 bytes of entropy, base64, stripped of characters that are awkward in .env / URLs
  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-50
}

load_env() {
  [ -f "$1" ] || die "env file not found: $1 (run ./provision.sh first)"
  # shellcheck disable=SC2046
  set -a
  . "$1"
  set +a
}

ssh_args() {
  printf '%s' "-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$SECRETS_DIR/known_hosts"
}

server_ip() {
  [ -f "$SERVER_JSON" ] || die "no server.json - run ./provision.sh first"
  json_get 'ip' < "$SERVER_JSON"
}
```

- [ ] **Step 3: Write `deployment/hetzner/.env.example`**

```sh
# Copy of the variables provision.sh generates into .env. Never commit the real .env.

# --- public identity -------------------------------------------------------
DOMAIN=jinifai.com
ACME_EMAIL=you@example.com
# Empty in production so Caddy uses Let's Encrypt. Set to "tls internal" for a local
# smoke test with a self-signed certificate.
CADDY_TLS=
# Host port mapping. 80/443 in production; override locally if those ports are taken.
HTTP_PORT=80
HTTPS_PORT=443

# --- database --------------------------------------------------------------
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<generated>

# --- shared JWT signing key ------------------------------------------------
# MUST be identical across auth (as DJANGO_SECRET_KEY), payments (JWT_SECRET) and
# pre_inference (JWT_SECRET): simplejwt signs with Django's SECRET_KEY and the other two verify.
JWT_SIGNING_KEY=<generated>
# payments' own Django secret, deliberately different from the signing key above.
PAYMENTS_DJANGO_SECRET_KEY=<generated>

# --- accounts (seeded by deploy.sh, never shipped to the browser) ----------
DJANGO_SUPERUSER_EMAIL=admin@jinifai.com
DJANGO_SUPERUSER_PASSWORD=<generated>
DEMO_USER_EMAIL=demo@jinifai.com
DEMO_USER_PASSWORD=<generated>

# --- RunPod ----------------------------------------------------------------
# RUNPOD_API_KEY is used server-side by pre_inference AND passed to the SPA build as
# REACT_APP_RUNPOD_API_KEY, where it is inlined into public JavaScript. This exposure was
# accepted by the project owner; rotate the key and set a RunPod spend limit after launch.
RUNPOD_API_KEY=<RUNPOD_API_KEY>
RUNPOD_RUN_URL=https://api.runpod.ai/v1/v9zir5v2o6ezbl/run
RUNPOD_STATUS_URL=https://api.runpod.ai/v1/v9zir5v2o6ezbl/status/
```

- [ ] **Step 4: Write `deployment/hetzner/Caddyfile`**

```caddyfile
{
	email {$ACME_EMAIL}
}

{$DOMAIN} {
	# Empty in production (Let's Encrypt); "tls internal" for local smoke tests.
	{$CADDY_TLS}

	encode zstd gzip

	header {
		-Server
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "strict-origin-when-cross-origin"
	}

	# Every backend path is /api/<service>/..., so one origin serves all three and the SPA.
	# Single origin means no CORS preflights and one certificate.
	handle /api/auth/* {
		reverse_proxy auth:8000
	}

	handle /api/payments/* {
		reverse_proxy payments:8001
	}

	handle /api/preinference/* {
		reverse_proxy pre_inference:8002 {
			# pre_inference's limiter_key() parses the RFC 7239 Forwarded header as
			# split(';')[0].split('=')[1]. Without this header it logs an error and falls back
			# to the Host header, which is identical for every visitor - collapsing all users
			# into a single rate-limit bucket.
			header_up Forwarded "for={http.request.remote.host};proto={http.request.scheme}"
		}
	}

	# Django admin is deliberately NOT routed. Reach it with:
	#   ./ssh.sh -L 8000:127.0.0.1:8000   then open http://localhost:8000/admin/
	handle {
		reverse_proxy web:80
	}
}

www.{$DOMAIN} {
	{$CADDY_TLS}
	redir https://{$DOMAIN}{uri} permanent
}
```

- [ ] **Step 5: Write `deployment/hetzner/docker-compose.yml`**

```yaml
name: web-ai-demo

services:

  caddy:
    image: caddy:2.8-alpine
    restart: unless-stopped
    ports:
      - "${HTTP_PORT:-80}:80"
      - "${HTTPS_PORT:-443}:443"
      - "${HTTPS_PORT:-443}:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    environment:
      DOMAIN: ${DOMAIN}
      ACME_EMAIL: ${ACME_EMAIL}
      CADDY_TLS: ${CADDY_TLS:-}
    depends_on:
      - web
      - auth
      - payments
      - pre_inference

  web:
    build:
      context: ../../web_client/web_client_src
      dockerfile: hetzner_container/Dockerfile
      args:
        REACT_APP_AUTH_API_SERVICE: https://${DOMAIN}/
        REACT_APP_PAYMENTS_API_SERVICE: https://${DOMAIN}/
        REACT_APP_TEXT_TO_IMG_API_SERVICE: https://${DOMAIN}/api/preinference/
        REACT_APP_RUNPOD_API_KEY: ${RUNPOD_API_KEY}
        # Empty: the login form must render blank.
        REACT_APP_DEMO_LOGIN: ""
        REACT_APP_DEMO_PASSWORD: ""
    restart: unless-stopped

  auth:
    build:
      context: ../../auth/auth_src
      dockerfile: hetzner_container/Dockerfile
    restart: unless-stopped
    # Loopback only: lets `ssh -L 8000:127.0.0.1:8000` reach /admin/ without exposing it.
    ports:
      - "127.0.0.1:8000:8000"
    environment:
      AUTH_PRJ_MODE: prod
      DEBUG: "FALSE"
      DJANGO_SECRET_KEY: ${JWT_SIGNING_KEY}
      POSTGRES_HOST: postgres
      POSTGRES_PSW: ${POSTGRES_PASSWORD}
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_PORT: "5672"
      # RABBITMQ_BROKER_ID intentionally unset: setting it switches consumer.py to AmazonMQ TLS.
      DJANGO_SUPERUSER_EMAIL: ${DJANGO_SUPERUSER_EMAIL}
      DJANGO_SUPERUSER_PASSWORD: ${DJANGO_SUPERUSER_PASSWORD}
      DEMO_USER_EMAIL: ${DEMO_USER_EMAIL}
      DEMO_USER_PASSWORD: ${DEMO_USER_PASSWORD}
    depends_on:
      postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy

  payments:
    build:
      context: ../../payments/payments_src
      dockerfile: hetzner_container/Dockerfile
    restart: unless-stopped
    environment:
      AUTH_PRJ_MODE: prod
      DEBUG: "FALSE"
      DJANGO_SECRET_KEY: ${PAYMENTS_DJANGO_SECRET_KEY}
      JWT_SECRET: ${JWT_SIGNING_KEY}
      POSTGRES_HOST: postgres
      POSTGRES_PSW: ${POSTGRES_PASSWORD}
      RABBITMQ_HOST: rabbitmq
      RABBITMQ_PORT: "5672"
    depends_on:
      postgres:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy

  pre_inference:
    build:
      context: ../../pre_inference/pre_inference_src
      dockerfile: hetzner_container/Dockerfile
    restart: unless-stopped
    environment:
      JWT_SECRET: ${JWT_SIGNING_KEY}
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_DB: "0"
      RUNPOD_API_KEY: ${RUNPOD_API_KEY}
      RUNPOD_RUN_URL: ${RUNPOD_RUN_URL}
      RUNPOD_STATUS_URL: ${RUNPOD_STATUS_URL}
    depends_on:
      redis:
        condition: service_started

  postgres:
    image: postgres:14.6-bullseye
    restart: unless-stopped
    # No ports: reachable only over the compose network.
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./init-databases.sql:/docker-entrypoint-initdb.d/init-databases.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d postgres"]
      interval: 3s
      timeout: 5s
      retries: 20
      start_period: 5s

  redis:
    image: redis:7.0-bullseye
    restart: unless-stopped

  rabbitmq:
    image: rabbitmq:3.11.9-management
    restart: unless-stopped
    # Management UI on 15672 is deliberately not published.
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 10s
      retries: 12
      start_period: 20s

volumes:
  pgdata:
  caddy_data:
  caddy_config:
```

- [ ] **Step 6: Write `deployment/hetzner/seed_accounts.py`**

Piped into `manage.py shell`, so it runs inside the auth service with Django configured.

```python
"""Create the superuser and the demo user. Idempotent: never rewrites an existing password.

Run with:  docker compose exec -T auth python manage.py shell < seed_accounts.py
"""
import os

from django.contrib.auth import get_user_model
from allauth.account.models import EmailAddress

User = get_user_model()


def ensure_user(email, password, is_superuser):
    # AUTH_USER_MODEL extends AbstractUser, so USERNAME_FIELD is 'username'. allauth's
    # ACCOUNT_AUTHENTICATION_METHOD = "username_email" lets people log in with either, so the
    # username is set to the email for consistency.
    existing = User.objects.filter(email__iexact=email).first()
    if existing is None:
        factory = User.objects.create_superuser if is_superuser else User.objects.create_user
        user = factory(username=email, email=email, password=password)
        action = "created"
    else:
        user = existing
        action = "already exists"

    # Without a verified EmailAddress row, allauth's email-based login path can fail even
    # though ACCOUNT_EMAIL_VERIFICATION is "none".
    EmailAddress.objects.update_or_create(
        user=user,
        email=email,
        defaults={"verified": True, "primary": True},
    )

    label = "superuser" if is_superuser else "demo user"
    print(f"{label}: {email} - {action} (id={user.pk}, tier={user.tier})")


ensure_user(os.environ["DJANGO_SUPERUSER_EMAIL"], os.environ["DJANGO_SUPERUSER_PASSWORD"], True)
ensure_user(os.environ["DEMO_USER_EMAIL"], os.environ["DEMO_USER_PASSWORD"], False)
```

- [ ] **Step 7: Generate a local env file and confirm the stack is NOT running**

```bash
cd /d/Projects/web_ai/deployment/hetzner
. lib/common.sh
{
  echo "DOMAIN=jinifai.com"
  echo "ACME_EMAIL=you@example.com"
  echo 'CADDY_TLS=tls internal'
  echo "HTTP_PORT=8080"
  echo "HTTPS_PORT=8443"
  echo "POSTGRES_USER=postgres"
  echo "POSTGRES_PASSWORD=$(gen_secret)"
  echo "JWT_SIGNING_KEY=$(gen_secret)"
  echo "PAYMENTS_DJANGO_SECRET_KEY=$(gen_secret)"
  echo "DJANGO_SUPERUSER_EMAIL=admin@jinifai.com"
  echo "DJANGO_SUPERUSER_PASSWORD=$(gen_secret)"
  echo "DEMO_USER_EMAIL=demo@jinifai.com"
  echo "DEMO_USER_PASSWORD=$(gen_secret)"
  echo "RUNPOD_API_KEY=<RUNPOD_API_KEY>"
  echo "RUNPOD_RUN_URL=https://api.runpod.ai/v1/v9zir5v2o6ezbl/run"
  echo "RUNPOD_STATUS_URL=https://api.runpod.ai/v1/v9zir5v2o6ezbl/status/"
} > .env.local
curl -sk -o /dev/null -w "%{http_code}\n" --resolve jinifai.com:8443:127.0.0.1 https://jinifai.com:8443/ || echo "not serving yet (expected)"
```

Expected: `not serving yet (expected)` or `000`. `.env.local` is covered by the repo's `*.env` gitignore rule — confirm with `git status --porcelain`, which must not list it.

- [ ] **Step 8: Bring the stack up locally**

The web image layer cache from Task 2 is reused because the build args are identical.

```bash
cd /d/Projects/web_ai/deployment/hetzner
docker compose --env-file .env.local up -d --build
docker compose --env-file .env.local ps
```

Expected: eight services created; `postgres` and `rabbitmq` reach `healthy`.

- [ ] **Step 9: Seed accounts and run the local smoke test**

```bash
cd /d/Projects/web_ai/deployment/hetzner
docker compose --env-file .env.local exec -T auth python manage.py shell < seed_accounts.py

DEMO_EMAIL=$(grep '^DEMO_USER_EMAIL=' .env.local | cut -d= -f2)
DEMO_PASS=$(grep '^DEMO_USER_PASSWORD=' .env.local | cut -d= -f2)
C="curl -sk --resolve jinifai.com:8443:127.0.0.1"
BASE="https://jinifai.com:8443"

echo "spa:         $($C -o /dev/null -w '%{http_code}' $BASE/)"
echo "healthcheck: $($C -o /dev/null -w '%{http_code}' $BASE/api/auth/healthcheck/)"
TOKEN=$($C -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$DEMO_EMAIL\",\"password\":\"$DEMO_PASS\"}" \
  $BASE/api/auth/login/ | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')
echo "login token: ${TOKEN:0:24}..."
echo "payments:    $($C -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" $BASE/api/payments/)"
echo "preinf root: $($C -o /dev/null -w '%{http_code}' $BASE/api/preinference/)"
```

Expected: `spa: 200`, `healthcheck: 200`, a non-empty token, `payments: 200`, `preinf root: 200`. A 502 means Caddy cannot reach that upstream — check `docker compose logs <service>`.

- [ ] **Step 10: Verify the port policy locally**

```bash
cd /d/Projects/web_ai/deployment/hetzner
docker compose --env-file .env.local ps --format '{{.Service}}\t{{.Ports}}'
```

Expected: `postgres`, `redis`, `rabbitmq` and `web` show **no** `0.0.0.0:`/`:::` host bindings; `auth` shows only `127.0.0.1:8000->8000`; `caddy` shows 8080 and 8443.

- [ ] **Step 11: Tear the local stack down**

```bash
cd /d/Projects/web_ai/deployment/hetzner
docker compose --env-file .env.local down -v
```

Expected: containers and volumes removed. `-v` matters — the next local run must start from an empty database so the init SQL runs again.

- [ ] **Step 12: Commit**

```bash
cd /d/Projects/web_ai/deployment
git status --porcelain            # must NOT list hetzner/.env, hetzner/.env.local or hetzner/.secrets/
git add hetzner/docker-compose.yml hetzner/Caddyfile hetzner/init-databases.sql \
        hetzner/seed_accounts.py hetzner/.env.example hetzner/lib/common.sh
git commit -m "Add compose stack, Caddy routing and account seeding.

Single-origin path routing, no published ports for postgres/redis/rabbitmq,
auth on loopback only for admin over SSH. Verified locally end to end."
```

---

### Task 4: Provisioning and teardown

Teardown ships in the same task as provisioning so that nothing can be created without a tested way to remove it.

**Files:**
- Create: `deployment/hetzner/cloud-init.yaml`
- Create: `deployment/hetzner/provision.sh`
- Create: `deployment/hetzner/destroy.sh`
- Create: `deployment/hetzner/ssh.sh`

**Interfaces:**
- Consumes: `lib/common.sh` (`log`, `die`, `gen_secret`, `json_get`, `require_cmd`, `ssh_args`, `server_ip`, and the `SERVER_*`/`*_NAME` constants).
- Produces: `.secrets/id_ed25519{,.pub}`, `.secrets/server.json` containing `{"id":…,"ip":…,"name":…}`, and a generated `.env`. `./ssh.sh [args…]` opens a shell on the server.

- [ ] **Step 1: Bootstrap a working CA bundle for curl** — ALREADY DONE

Windows-only. **Avast Antivirus intercepts TLS on this workstation**: it re-signs every server
certificate with `CN = Avast Web/Mail Shield Root`. Windows trusts that root (so PowerShell's
`Invoke-WebRequest` works), but Git Bash's curl uses its own bundle, which does not contain it —
hence `curl: (60) unable to get local issuer certificate`. Whitelisting a URL in Avast does not
help; curl needs the Avast root as a trust anchor. The fix keeps verification fully enabled rather
than resorting to `-k`, which would be reckless with a live API token in the header.

Already executed; the artifacts are in `.secrets/` (gitignored). To reproduce:

```bash
powershell -NoProfile -Command "\$dir='D:\Projects\web_ai\deployment\hetzner\.secrets'; \
  \$roots = Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root | Where-Object { \$_.Subject -like '*Avast*' }; \
  \$pem = foreach (\$c in \$roots) { '-----BEGIN CERTIFICATE-----'; [Convert]::ToBase64String(\$c.RawData,'InsertLineBreaks'); '-----END CERTIFICATE-----' }; \
  \$pem | Out-File \"\$dir\avast-root.pem\" -Encoding ascii; \
  Invoke-WebRequest -Uri https://curl.se/ca/cacert.pem -OutFile \"\$dir\mozilla-cacert.pem\" -UseBasicParsing; \
  Get-Content \"\$dir\mozilla-cacert.pem\", \"\$dir\avast-root.pem\" | Set-Content \"\$dir\cacert.pem\" -Encoding ascii"

CURL_CA_BUNDLE=/d/Projects/web_ai/deployment/hetzner/.secrets/cacert.pem \
  curl -s -o /dev/null -w "hetzner api tls: %{http_code}\n" https://api.hetzner.cloud/v1/
```

Verified output: `hetzner api tls: 404` — 404 is the API root's normal answer; the point is that
TLS verified without `-k`. `lib/common.sh` picks `.secrets/cacert.pem` up automatically.

Consequence for `verify.sh`: Avast also intercepts `https://jinifai.com`, so the certificate curl
and `openssl s_client` see from this workstation is the **Avast** one, not Let's Encrypt. The two
certificate checks in Task 6 must therefore be run from the server (`./ssh.sh`) rather than locally,
or they will fail misleadingly. Adjust them during Task 6 and note it in the README.

- [ ] **Step 2: Write `deployment/hetzner/cloud-init.yaml`**

```yaml
#cloud-config
package_update: true
package_upgrade: true

packages:
  - ca-certificates
  - curl
  - gnupg
  - git

write_files:
  # The CRA production build is the only memory-hungry step on this 4GB box.
  - path: /etc/sysctl.d/99-swappiness.conf
    content: |
      vm.swappiness=10

runcmd:
  - [ sh, -c, "install -m 0755 -d /etc/apt/keyrings" ]
  - [ sh, -c, "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc" ]
  - [ sh, -c, "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list" ]
  - [ sh, -c, "apt-get update -y" ]
  - [ sh, -c, "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" ]
  - [ sh, -c, "systemctl enable --now docker" ]
  - [ sh, -c, "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile" ]
  - [ sh, -c, "echo '/swapfile none swap sw 0 0' >> /etc/fstab" ]
  - [ sh, -c, "sysctl -p /etc/sysctl.d/99-swappiness.conf" ]
  - [ sh, -c, "mkdir -p /opt/web_ai" ]
  - [ sh, -c, "sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && systemctl restart ssh" ]
  - [ sh, -c, "touch /var/lib/cloud-init-finished" ]
```

- [ ] **Step 3: Write `deployment/hetzner/provision.sh`**

```sh
#!/bin/sh
# Creates the Hetzner SSH key, firewall and server, and generates .env.
# Idempotent: existing resources are reused, an existing .env is never overwritten.
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd curl
require_cmd openssl
require_cmd ssh-keygen

[ -f "$SECRETS_DIR/hcloud_token" ] || die "missing $SECRETS_DIR/hcloud_token"
TOKEN="$(tr -d '\r\n' < "$SECRETS_DIR/hcloud_token")"
API="https://api.hetzner.cloud/v1"

api() { # api METHOD PATH [BODY]
  if [ -n "$3" ]; then
    curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$3" "$API$2"
  else
    curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" "$API$2"
  fi
}

# --- SSH key ---------------------------------------------------------------
if [ ! -f "$SSH_KEY" ]; then
  log "generating deployment SSH key (the personal ~/.ssh/id_rsa is deliberately not reused)"
  ssh-keygen -t ed25519 -N "" -C "$SSH_KEY_NAME" -f "$SSH_KEY"
fi

EXISTING_KEY_ID="$(api GET "/ssh_keys?name=$SSH_KEY_NAME" | json_get 'ssh_keys.0.id')"
if [ -z "$EXISTING_KEY_ID" ]; then
  log "uploading SSH key as '$SSH_KEY_NAME'"
  PUBKEY="$(tr -d '\r\n' < "$SSH_KEY.pub")"
  EXISTING_KEY_ID="$(api POST "/ssh_keys" "{\"name\":\"$SSH_KEY_NAME\",\"public_key\":\"$PUBKEY\"}" | json_get 'ssh_key.id')"
  [ -n "$EXISTING_KEY_ID" ] || die "failed to upload SSH key"
fi
log "ssh key id: $EXISTING_KEY_ID"

# --- firewall --------------------------------------------------------------
FW_ID="$(api GET "/firewalls?name=$FIREWALL_NAME" | json_get 'firewalls.0.id')"
if [ -z "$FW_ID" ]; then
  log "creating firewall '$FIREWALL_NAME' (inbound 22/80/443 only)"
  FW_BODY='{"name":"'"$FIREWALL_NAME"'","rules":[
    {"direction":"in","protocol":"tcp","port":"22","source_ips":["0.0.0.0/0","::/0"]},
    {"direction":"in","protocol":"tcp","port":"80","source_ips":["0.0.0.0/0","::/0"]},
    {"direction":"in","protocol":"tcp","port":"443","source_ips":["0.0.0.0/0","::/0"]}
  ]}'
  FW_ID="$(api POST "/firewalls" "$FW_BODY" | json_get 'firewall.id')"
  [ -n "$FW_ID" ] || die "failed to create firewall"
fi
log "firewall id: $FW_ID"

# --- server ----------------------------------------------------------------
SRV_ID="$(api GET "/servers?name=$SERVER_NAME" | json_get 'servers.0.id')"
if [ -z "$SRV_ID" ]; then
  log "creating server '$SERVER_NAME' ($SERVER_TYPE, $SERVER_LOCATION, $SERVER_IMAGE)"
  USER_DATA="$("$PY" -c 'import json,sys; print(json.dumps(open(sys.argv[1], encoding="utf-8").read()))' "$HETZNER_DIR/cloud-init.yaml")"
  BODY="{\"name\":\"$SERVER_NAME\",\"server_type\":\"$SERVER_TYPE\",\"location\":\"$SERVER_LOCATION\",\"image\":\"$SERVER_IMAGE\",\"ssh_keys\":[$EXISTING_KEY_ID],\"firewalls\":[{\"firewall\":$FW_ID}],\"user_data\":$USER_DATA,\"labels\":{\"project\":\"web_ai\",\"env\":\"demo\"}}"
  RESP="$(api POST "/servers" "$BODY")"
  SRV_ID="$(printf '%s' "$RESP" | json_get 'server.id')"
  [ -n "$SRV_ID" ] || die "failed to create server: $RESP"
fi

SRV="$(api GET "/servers/$SRV_ID")"
SRV_IP="$(printf '%s' "$SRV" | json_get 'server.public_net.ipv4.ip')"
printf '{"id":%s,"ip":"%s","name":"%s"}\n' "$SRV_ID" "$SRV_IP" "$SERVER_NAME" > "$SERVER_JSON"
log "server id: $SRV_ID  ip: $SRV_IP"

# --- .env ------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  log ".env already exists, leaving it untouched"
else
  log "generating .env with fresh secrets"
  cat > "$ENV_FILE" <<EOF
DOMAIN=jinifai.com
ACME_EMAIL=you@example.com
CADDY_TLS=
HTTP_PORT=80
HTTPS_PORT=443
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$(gen_secret)
JWT_SIGNING_KEY=$(gen_secret)
PAYMENTS_DJANGO_SECRET_KEY=$(gen_secret)
DJANGO_SUPERUSER_EMAIL=admin@jinifai.com
DJANGO_SUPERUSER_PASSWORD=$(gen_secret)
DEMO_USER_EMAIL=demo@jinifai.com
DEMO_USER_PASSWORD=$(gen_secret)
RUNPOD_API_KEY=<RUNPOD_API_KEY>
RUNPOD_RUN_URL=https://api.runpod.ai/v1/v9zir5v2o6ezbl/run
RUNPOD_STATUS_URL=https://api.runpod.ai/v1/v9zir5v2o6ezbl/status/
EOF
  chmod 600 "$ENV_FILE"
fi

cat <<EOF

  Server ready at $SRV_IP

  Create these DNS records at Namecheap, then run ./deploy.sh:

    A   @     $SRV_IP
    A   www   $SRV_IP

  (jinifai.com currently points at Namecheap parking; both records must be replaced.)

EOF
```

- [ ] **Step 4: Write `deployment/hetzner/ssh.sh`**

```sh
#!/bin/sh
# Opens an SSH session (or runs a command) on the demo server.
#   ./ssh.sh                              interactive shell
#   ./ssh.sh docker compose ps            run a command
#   ./ssh.sh -L 8000:127.0.0.1:8000       tunnel for the Django admin
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# shellcheck disable=SC2046
exec ssh $(ssh_args) "root@$(server_ip)" "$@"
```

- [ ] **Step 5: Write `deployment/hetzner/destroy.sh`**

```sh
#!/bin/sh
# Deletes the server, firewall and uploaded SSH key so the demo cannot keep costing money.
#   ./destroy.sh --dry-run    show what would be deleted
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd curl
[ -f "$SECRETS_DIR/hcloud_token" ] || die "missing $SECRETS_DIR/hcloud_token"
TOKEN="$(tr -d '\r\n' < "$SECRETS_DIR/hcloud_token")"
API="https://api.hetzner.cloud/v1"

api() {
  curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" "$API$2"
}

SRV_ID="$(api GET "/servers?name=$SERVER_NAME" | json_get 'servers.0.id')"
FW_ID="$(api GET "/firewalls?name=$FIREWALL_NAME" | json_get 'firewalls.0.id')"
KEY_ID="$(api GET "/ssh_keys?name=$SSH_KEY_NAME" | json_get 'ssh_keys.0.id')"

log "server:   ${SRV_ID:-<none>}"
log "firewall: ${FW_ID:-<none>}"
log "ssh key:  ${KEY_ID:-<none>}"

if [ "$1" = "--dry-run" ]; then
  log "dry run - nothing deleted"
  exit 0
fi

printf 'This DESTROYS the server and its Postgres volume. Type the server name to confirm: '
read -r CONFIRM
[ "$CONFIRM" = "$SERVER_NAME" ] || die "confirmation did not match, aborting"

[ -n "$SRV_ID" ] && { log "deleting server $SRV_ID"; api DELETE "/servers/$SRV_ID" >/dev/null; }
[ -n "$FW_ID" ]  && { log "deleting firewall $FW_ID"; api DELETE "/firewalls/$FW_ID" >/dev/null; }
[ -n "$KEY_ID" ] && { log "deleting ssh key $KEY_ID"; api DELETE "/ssh_keys/$KEY_ID" >/dev/null; }
rm -f "$SERVER_JSON"
log "done. .env and the local keypair were kept - delete .secrets/ by hand if you want a clean slate."
```

- [ ] **Step 6: Confirm no server exists yet**

```bash
cd /d/Projects/web_ai/deployment/hetzner
chmod +x provision.sh destroy.sh ssh.sh
./destroy.sh --dry-run
```

Expected: all three lines report `<none>`. This also proves the token, TLS and JSON parsing work before anything is created.

- [ ] **Step 7: Provision**

```bash
cd /d/Projects/web_ai/deployment/hetzner
./provision.sh
```

Expected: ids printed for key, firewall and server; an IPv4 address; the DNS instructions. Costs start now (~€0.009/hour).

- [ ] **Step 8: Verify the server matches the spec**

Cloud-init takes 2–4 minutes; retry SSH until it answers.

```bash
cd /d/Projects/web_ai/deployment/hetzner
./destroy.sh --dry-run                       # ids should now be populated
./ssh.sh 'cloud-init status --wait; docker --version; docker compose version; free -h | grep -i swap; test -d /opt/web_ai && echo "/opt/web_ai ok"; grep -E "^PasswordAuthentication" /etc/ssh/sshd_config'
```

Expected: `status: done`, Docker and compose versions printed, a ~2 GB swap line, `/opt/web_ai ok`, `PasswordAuthentication no`.

- [ ] **Step 9: Verify the firewall from outside**

```bash
cd /d/Projects/web_ai/deployment/hetzner
IP=$(. lib/common.sh && server_ip)
for p in 22 80 443 5432 6379 5672 15672; do
  timeout 5 bash -c "</dev/tcp/$IP/$p" 2>/dev/null && echo "port $p OPEN" || echo "port $p closed"
done
```

Expected: 22 `OPEN`; 80/443 closed for now (nothing is listening yet); 5432/6379/5672/15672 `closed`.

- [ ] **Step 10: Commit**

```bash
cd /d/Projects/web_ai/deployment
git status --porcelain            # must NOT list hetzner/.env or hetzner/.secrets/
git add hetzner/provision.sh hetzner/destroy.sh hetzner/ssh.sh hetzner/cloud-init.yaml
git commit -m "Add Hetzner provisioning, teardown and SSH helper.

Creates a cx23 in nbg1 with a 22/80/443 firewall, a dedicated ed25519 key
and cloud-init installing Docker plus 2GB swap. destroy.sh removes it all."
```

---

### Task 5: Deployment script

**Files:**
- Create: `deployment/hetzner/deploy.sh`

**Interfaces:**
- Consumes: `lib/common.sh`, `.secrets/server.json`, `.env`, and everything from Tasks 1–4.
- Produces: a running stack at `/opt/web_ai/deployment/hetzner` on the server.

- [ ] **Step 1: Write `deployment/hetzner/deploy.sh`**

```sh
#!/bin/sh
# Ships source to the server, builds the images there and starts the stack.
# Idempotent and re-runnable; a deploy is a short outage, not zero-downtime.
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd ssh
require_cmd tar
load_env "$ENV_FILE"

IP="$(server_ip)"
SSH="ssh $(ssh_args) root@$IP"
PROJECT_ROOT="$(cd "$HETZNER_DIR/../.." && pwd)"

# --- preflight: DNS --------------------------------------------------------
# Let's Encrypt allows only 5 duplicate certificates per week, so never let Caddy attempt
# issuance before the A record actually points here.
log "checking that $DOMAIN resolves to $IP"
RESOLVED="$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)"
if [ "$RESOLVED" != "$IP" ]; then
  die "$DOMAIN resolves to '${RESOLVED:-nothing}', expected $IP.
Create the A records shown by provision.sh and wait for propagation, then re-run."
fi

# --- ship source -----------------------------------------------------------
log "shipping source to $IP:$REMOTE_DIR"
tar czf - -C "$PROJECT_ROOT" \
  --exclude=node_modules \
  --exclude=.git \
  --exclude=build \
  --exclude=__pycache__ \
  --exclude='*.pyc' \
  --exclude=py3107 \
  --exclude=py31010 \
  --exclude=.idea \
  --exclude=.secrets \
  --exclude='.env.local' \
  auth/auth_src \
  payments/payments_src \
  pre_inference/pre_inference_src \
  web_client/web_client_src \
  deployment/hetzner \
  | $SSH "mkdir -p $REMOTE_DIR && tar xzf - -C $REMOTE_DIR"

log "installing .env on the server"
$SSH "cat > $REMOTE_DIR/deployment/hetzner/.env && chmod 600 $REMOTE_DIR/deployment/hetzner/.env" < "$ENV_FILE"

# --- build and start -------------------------------------------------------
log "building images on the server (the CRA build takes ~10-15 min on 2 vCPU)"
$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose build"

log "starting the stack"
$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose up -d"

log "waiting for postgres to become healthy"
$SSH "cd $REMOTE_DIR/deployment/hetzner && for i in \$(seq 1 40); do
  if docker compose ps postgres | grep -q healthy; then echo 'postgres healthy'; exit 0; fi
  sleep 3
done; echo 'postgres did not become healthy'; docker compose logs --tail=40 postgres; exit 1"

log "seeding accounts"
$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose exec -T auth python manage.py shell" < "$HETZNER_DIR/seed_accounts.py"

# --- report ----------------------------------------------------------------
log "checking what ended up in the public JS bundle"
$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose exec -T web sh -c '
  cd /usr/share/nginx/html
  echo \"  runpod key occurrences : \$(grep -ro \"$RUNPOD_API_KEY\" static/js | wc -l)  (accepted risk)\"
  echo \"  demo password          : \$(grep -ro \"password\" static/js >/dev/null; echo n/a)\"
'" || warn "bundle check failed (non-fatal)"

$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose ps"
log "deploy complete - now run ./verify.sh"
```

- [ ] **Step 2: Confirm the site is not yet served**

```bash
cd /d/Projects/web_ai/deployment/hetzner
curl -s -o /dev/null -w "before deploy: %{http_code}\n" --max-time 10 https://jinifai.com/ || echo "before deploy: unreachable (expected)"
```

Expected: `unreachable`, `000`, or the Namecheap parking page — anything but the app.

- [ ] **Step 3: Run the deploy**

Requires the DNS A records to be live first; the script refuses otherwise.

```bash
cd /d/Projects/web_ai/deployment/hetzner
chmod +x deploy.sh
./deploy.sh
```

Expected: DNS check passes, source ships, images build, stack starts, both accounts seeded, `docker compose ps` shows every service `running` (postgres and rabbitmq `healthy`).

- [ ] **Step 4: Commit**

```bash
cd /d/Projects/web_ai/deployment
git status --porcelain
git add hetzner/deploy.sh
git commit -m "Add deploy script.

Refuses to run until DNS points at the server so Let's Encrypt attempts
are not wasted, ships source over tar+ssh, builds on the server, seeds
accounts and reports what landed in the public bundle."
```

---

### Task 6: The acceptance gate

**Files:**
- Create: `deployment/hetzner/verify.sh`
- Create: `deployment/hetzner/README.md`

**Interfaces:**
- Consumes: `lib/common.sh`, `.env` (for `DEMO_USER_EMAIL`/`DEMO_USER_PASSWORD`), a deployed stack.
- Produces: exit code 0 only when every check passes.

- [ ] **Step 1: Write `deployment/hetzner/verify.sh`**

```sh
#!/bin/sh
# End-to-end acceptance gate. Exits non-zero if any check fails.
#   ./verify.sh              full run, including a reboot-resilience check
#   ./verify.sh --no-reboot  skip the reboot check
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

load_env "$ENV_FILE"
IP="$(server_ip)"
BASE="https://$DOMAIN"
FAILURES=0
PASSES=0

check() { # check "name" "actual" "expected"
  if [ "$2" = "$3" ]; then
    printf '  \033[0;32mPASS\033[0m %-46s %s\n' "$1" "$2"
    PASSES=$((PASSES + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %-46s got=%s want=%s\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

check_not() { # check_not "name" "actual" "unwanted"
  if [ "$2" != "$3" ]; then
    printf '  \033[0;32mPASS\033[0m %-46s %s\n' "$1" "$2"
    PASSES=$((PASSES + 1))
  else
    printf '  \033[0;31mFAIL\033[0m %-46s unexpectedly %s\n' "$1" "$2"
    FAILURES=$((FAILURES + 1))
  fi
}

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@"; }

log "1-3  TLS and the SPA"
check "http redirects to https" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://$DOMAIN/")" "308"
check "spa returns 200" "$(code "$BASE/")" "200"
check "spa contains react root" "$(curl -s --max-time 30 "$BASE/" | grep -c 'id="root"')" "1"
BUNDLE="$(curl -s --max-time 30 "$BASE/" | grep -o '/static/js/[^"]*\.js' | head -1)"
check_not "found a js bundle reference" "${BUNDLE:-none}" "none"
check "js bundle loads" "$(code "$BASE$BUNDLE")" "200"
check "cert issued by Let's Encrypt" \
  "$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer | grep -c "Let's Encrypt")" "1"
check "cert covers the domain" \
  "$(echo | openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -text | grep -c "DNS:$DOMAIN")" "1"

log "4-6  auth service"
check "healthcheck" "$(code "$BASE/api/auth/healthcheck/")" "200"

RANDOM_EMAIL="probe-$(date +%s)@example.com"
REG_BODY="{\"username\":\"$RANDOM_EMAIL\",\"email\":\"$RANDOM_EMAIL\",\"password1\":\"Pr0be-passw0rd!x\",\"password2\":\"Pr0be-passw0rd!x\"}"
check "self-registration works" \
  "$(code -X POST -H 'Content-Type: application/json' -d "$REG_BODY" "$BASE/api/auth/registration/")" "201"

LOGIN_JSON="$(curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$DEMO_USER_EMAIL\",\"password\":\"$DEMO_USER_PASSWORD\"}" "$BASE/api/auth/login/")"
TOKEN="$(printf '%s' "$LOGIN_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
check_not "demo login returns a JWT" "$([ -n "$TOKEN" ] && echo yes || echo no)" "no"

decode_claim() { # decode_claim <jwt> <claim>
  printf '%s' "$1" | "$PY" -c '
import base64,json,sys
payload = sys.stdin.read().split(".")[1]
payload += "=" * (-len(payload) % 4)
print(json.loads(base64.urlsafe_b64decode(payload)).get(sys.argv[1], ""))
' "$2"
}

log "7-8  payments and the RabbitMQ round trip"
check "payments list" "$(code -H "Authorization: Bearer $TOKEN" "$BASE/api/payments/")" "200"

TIER_BEFORE="$(decode_claim "$TOKEN" tier)"
log "     tier before payment: $TIER_BEFORE"
check "create payment" \
  "$(code -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"amount":"9.99"}' "$BASE/api/payments/")" "201"

# payments publishes to the 'payments' fanout exchange; auth's consumer thread sets tier=Premium.
sleep 5
LOGIN2="$(curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$DEMO_USER_EMAIL\",\"password\":\"$DEMO_USER_PASSWORD\"}" "$BASE/api/auth/login/")"
TOKEN2="$(printf '%s' "$LOGIN2" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
check "rabbitmq round trip upgraded the tier" "$(decode_claim "$TOKEN2" tier)" "Premium"

log "9-11 image generation through RunPod"
# The model string must be one of src/features/textToImage/text2img_models.js; the RunPod
# handler rejects anything else with {"error":"Unsupported model: ..."} and status FAILED.
RUN_QS="prompt=a%20photo%20of%20an%20astronaut%20riding%20a%20horse&model=stabilityai%2Fstable-diffusion-2-1&seed=42&height=512&width=512&guidance_scale=7.5&num_inference_steps=20"
RUN_JSON="$(curl -s --max-time 60 -X POST -H "Authorization: Bearer $TOKEN2" "$BASE/api/preinference/initiate_run/?$RUN_QS")"
RUN_ID="$(printf '%s' "$RUN_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("run_id",""))')"
check_not "initiate_run returned a run_id" "$([ -n "$RUN_ID" ] && echo yes || echo no)" "no"
[ -n "$RUN_ID" ] || warn "initiate_run response was: $RUN_JSON"

STATUS=""
if [ -n "$RUN_ID" ]; then
  i=0
  while [ $i -lt 60 ]; do
    STATUS="$(curl -s --max-time 30 -H "Authorization: Bearer $TOKEN2" \
      "$BASE/api/preinference/get_run_status/?run_id=$RUN_ID" \
      | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get("run_status",""))')"
    case "$STATUS" in
      COMPLETED|FAILED) break ;;
    esac
    printf '     run status: %s\r' "$STATUS"
    sleep 5
    i=$((i + 1))
  done
fi
printf '\n'
check "run reached COMPLETED" "$STATUS" "COMPLETED"

if [ "$STATUS" = "COMPLETED" ]; then
  curl -s --max-time 60 -H "Authorization: Bearer $TOKEN2" \
    "$BASE/api/preinference/get_image/?run_id=$RUN_ID" -o /tmp/verify_image.png
  check "get_image returned real PNG bytes" \
    "$(head -c 4 /tmp/verify_image.png | od -An -c | tr -d ' \n' | grep -c '211PNG')" "1"
  log "     image size: $(wc -c < /tmp/verify_image.png) bytes"
fi

log "12   internal ports are not exposed"
for p in 5432 6379 5672 15672; do
  if timeout 5 sh -c "</dev/tcp/$IP/$p" 2>/dev/null; then
    check "port $p closed to the internet" "OPEN" "closed"
  else
    check "port $p closed to the internet" "closed" "closed"
  fi
done

log "13   containers"
RUNNING="$(ssh $(ssh_args) "root@$IP" "cd $REMOTE_DIR/deployment/hetzner && docker compose ps --status running --format '{{.Service}}' | wc -l")"
check "all 8 services running" "$(printf '%s' "$RUNNING" | tr -d '\r')" "8"

if [ "$1" != "--no-reboot" ]; then
  log "14   reboot resilience"
  ssh $(ssh_args) "root@$IP" "nohup sh -c 'sleep 1; reboot' >/dev/null 2>&1 &" || true
  sleep 30
  i=0
  while [ $i -lt 40 ]; do
    if [ "$(code "$BASE/api/auth/healthcheck/")" = "200" ]; then break; fi
    sleep 5
    i=$((i + 1))
  done
  check "spa serves after reboot" "$(code "$BASE/")" "200"
  check "healthcheck after reboot" "$(code "$BASE/api/auth/healthcheck/")" "200"
  LOGIN3="$(curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"$DEMO_USER_EMAIL\",\"password\":\"$DEMO_USER_PASSWORD\"}" "$BASE/api/auth/login/")"
  check_not "login works after reboot" \
    "$(printf '%s' "$LOGIN3" | "$PY" -c 'import json,sys; print("yes" if json.load(sys.stdin).get("access_token") else "no")')" "no"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  log "ALL $PASSES CHECKS PASSED - https://$DOMAIN is live"
  exit 0
fi
die "$FAILURES check(s) failed, $PASSES passed"
```

- [ ] **Step 2: Run it**

```bash
cd /d/Projects/web_ai/deployment/hetzner
chmod +x verify.sh
./verify.sh
```

Expected: every check `PASS` and `ALL n CHECKS PASSED`. Debugging pointers: a 502 on an API path means Caddy cannot reach that upstream (`./ssh.sh 'cd /opt/web_ai/deployment/hetzner && docker compose logs --tail=50 <service>'`); a tier that stays `Free` means the consumer thread is not connected (check `docker compose logs auth | grep -i rabbit`); a run stuck in `IN_QUEUE` means the RunPod worker is cold — allow the full 5 minutes.

- [ ] **Step 3: Write `deployment/hetzner/README.md`**

Runbook covering: cost (€5.49 server + €0.50 IPv4 = €5.99/mo net, €7.43 gross), one-time setup (`hcloud_token`, `cacert.pem` on Windows), the `provision → DNS → deploy → verify` sequence, redeploying, reading logs, reaching the Django admin over the SSH tunnel, where the seeded credentials live, the accepted RunPod-key exposure with its rotation advice, and `destroy.sh`. State plainly that there are no backups and that the Postgres volume dies with the server.

- [ ] **Step 4: Commit**

```bash
cd /d/Projects/web_ai/deployment
git status --porcelain
git add hetzner/verify.sh hetzner/README.md
git commit -m "Add end-to-end verification gate and runbook.

verify.sh proves TLS, the SPA, registration, login, the payments
RabbitMQ round trip, real RunPod image generation, the closed internal
ports and reboot resilience."
```

---

### Task 7: Hand-off

**Files:** none.

**Interfaces:** Consumes a passing `verify.sh`.

- [ ] **Step 1: Capture the evidence**

Re-run `./verify.sh --no-reboot` and keep the full output. Record the server IP, the live URL, the seeded superuser and demo emails (not the passwords — say they are in `deployment/hetzner/.env`), the measured monthly cost, and the RunPod key occurrence count from the bundle check.

- [ ] **Step 2: Report to the user**

State what is live, what was verified with actual command output, and the three follow-ups: rotate the RunPod key and set a spend limit; the `web_client` `package.json` change is still uncommitted and a fresh clone would not build without it; branches `hetzner-demo-deployment` (deployment) and `hetzner-container` (four service repos) are committed but unpushed.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: server choice and firewall → Task 4; Caddy single-origin routing and the `Forwarded` header → Task 3 Step 4; `hetzner_container/` images and the `.dockerignore` exception → Tasks 1–2; the three coupling constraints (shared JWT key, unset `RABBITMQ_BROKER_ID`, `AUTH_PRJ_MODE=prod`) → Global Constraints plus Task 3 Step 5; no admin route and loopback publish → Task 3 Steps 4–5; empty demo build args → Task 2 Steps 3, 8; seeded accounts → Task 3 Step 6; accepted RunPod exposure with measurement → Task 2 Step 8 and Task 5 Step 1; the 14 acceptance checks → Task 6 Step 1; teardown → Task 4 Step 5.

**Deviations from the spec, deliberate:** the spec described a `deploy.sh` DNS preflight using `dig`, which Git Bash lacks — `nslookup` is used instead. The spec did not mention `.gitattributes` or the CA-bundle bootstrap; both were added after finding `core.autocrlf=true` and a failing `curl` TLS handshake on this workstation.

**Placeholder scan.** No TBD/TODO. The only prose-specified deliverable is the README body in Task 6 Step 3, where the contents are enumerated explicitly.

**Type consistency.** `lib/common.sh` defines `log`, `warn`, `die`, `require_cmd`, `json_get`, `gen_secret`, `load_env`, `ssh_args`, `server_ip`, `PY`, and the constants `SERVER_NAME`, `FIREWALL_NAME`, `SSH_KEY_NAME`, `SERVER_TYPE`, `SERVER_LOCATION`, `SERVER_IMAGE`, `REMOTE_DIR`, `HETZNER_DIR`, `SECRETS_DIR`, `ENV_FILE`, `SERVER_JSON`, `SSH_KEY`; every later use matches those names. Service names are identical across the compose file, the Caddyfile upstreams and the verify script. Env var names in `.env.example`, `provision.sh`'s generator and `docker-compose.yml` agree, including `JWT_SIGNING_KEY` versus `PAYMENTS_DJANGO_SECRET_KEY`. `server.json` is written as `{"id","ip","name"}` and read via `json_get 'ip'`.
