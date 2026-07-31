# Hetzner demo deployment — design

Date: 2026-07-30
Status: approved (pending spec review)

## Goal

Run the web_ai stack as a permanently-available public demo at **https://jinifai.com**, on the
cheapest Hetzner Cloud instance that can actually serve it, using Docker Compose. The deployment
must be reproducible from scratch with a small number of scripts, and verified end-to-end —
including real image generation through RunPod — before it is considered done.

## Non-goals

Explicitly out of scope, to keep the demo cheap and the surface small:

- CI/CD. Deploys are a manual `./deploy.sh`.
- Monitoring, alerting, log aggregation.
- Database backups. Demo data is disposable; `deploy.sh` reseeds the accounts it needs.
- Staging environment, blue/green, zero-downtime deploys. A deploy is a short outage.
- Horizontal scaling, Kubernetes, external managed services (RDS/ElastiCache/AmazonMQ).
- Changes to application behaviour. The only app-repo additions are container build files.

## The application being deployed

Four first-party services plus three infrastructure containers:

| service | stack | port | role |
|---|---|---|---|
| `web_client` | React 16 / CRA (Devias material-kit-pro) | 3000 dev → 80 prod | SPA |
| `auth` | Django 4.1 + dj-rest-auth + simplejwt | 8000 | registration, login, JWT issuance, user tiers |
| `payments` | Django 4.1 + DRF | 8001 | mock tier purchases, publishes to RabbitMQ |
| `pre_inference` | FastAPI + slowapi | 8002 | JWT-aware per-user rate limiting, proxies runs to RunPod |
| `postgres` | postgres:14.6 | 5432 | two databases: `auth_prj`, `payments_prj` |
| `redis` | redis:7.0 | 6379 | slowapi rate-limit storage |
| `rabbitmq` | rabbitmq:3.11.9 | 5672 | payments → auth tier-change fanout |

Actual GPU inference runs on an external **RunPod serverless endpoint** (`v9zir5v2o6ezbl`), which
was confirmed live during design (valid key, 1 ready worker, 80 completed jobs).

Three coupling constraints discovered in the source that the deployment must respect:

1. **Shared JWT signing key.** `simplejwt` signs with Django's `SECRET_KEY`, and both `payments`
   and `pre_inference` verify with their own `JWT_SECRET`. Therefore
   `auth.DJANGO_SECRET_KEY == payments.JWT_SECRET == pre_inference.JWT_SECRET`. `payments` keeps a
   *separate* `DJANGO_SECRET_KEY` for its own session/CSRF machinery.
2. **RabbitMQ connection mode is selected by the presence of `RABBITMQ_BROKER_ID`.**
   `auth_app/consumer.py` and `payments_app/publisher.py` branch: if that variable is set they build
   an `amqps://…mq.eu-central-1.amazonaws.com:5671` URL for AmazonMQ; otherwise they use plain
   `pika.ConnectionParameters(host, port)`. It must stay **unset** so both talk to the local
   container. Credentials default to `guest/guest`, which the official image permits over the
   container network.
3. **Settings module is selected by `AUTH_PRJ_MODE`** in *both* Django projects (`payments` reuses
   the same variable name). `prod` gives `DEBUG=False` and the existing `prod.py`.

## Decisions

### Server: `cx23`, Nuremberg, Ubuntu 24.04

Queried live from the Hetzner API at design time (Falkenstein/Nuremberg/Helsinki, net of the 24% VAT
on the account):

| type | arch | vCPU | RAM | disk | €/mo net |
|---|---|---|---|---|---|
| **cx23** | x86 | 2 | **4 GB** | 40 GB | **5.49** |
| cpx11 | x86 | 2 | 2 GB | 40 GB | 5.49 |
| cax11 | arm | 2 | 4 GB | 40 GB | 5.99 |

`cx23` is the cheapest type offered and strictly dominates `cpx11` (identical price, double the RAM).
Arm is no longer cheaper, so x86 wins on price *and* removes any arm64 build risk from the 2020-era
npm dependency tree. `cx23` is EU-only; US/Singapore would force a more expensive type.

Total: **€5.49 + €0.50 (primary IPv4) = €5.99/mo net (€7.43 gross)**, 20 TB traffic included.

Sizing rationale: total runtime footprint is roughly 700 MB (rabbitmq ~120, two Django + gunicorn
~270, uvicorn ~120, postgres ~60, redis/nginx/caddy ~40), so 4 GB is comfortable. The only
memory-hungry step is the one-time CRA production build, covered by a 2 GB swapfile.

### Networking: single origin behind Caddy

Caddy terminates TLS (Let's Encrypt, auto-renewing) and routes by path:

| path | upstream |
|---|---|
| `/api/auth/*` | `auth:8000` |
| `/api/payments/*` | `payments:8001` |
| `/api/preinference/*` | `pre_inference:8002` |
| everything else | `web:80` (nginx serving the built SPA) |

This works because `urls.js` composes every backend URL as `<base>/api/<service>/…`, so a single
origin covers all three services. Consequences: no CORS preflights at all, one certificate, and the
SPA can be built with `REACT_APP_*_API_SERVICE=https://jinifai.com/`.

`www.jinifai.com` is served as a 301 redirect to the apex. This requires a `www` A record; if it is
absent Caddy will log certificate-retry errors for `www` but the apex site is unaffected.

Caddy forwards `Forwarded: for={client-ip};proto={scheme}` on the `pre_inference` route. This is the
exact format `main.py:limiter_key()` parses (`split(';')[0].split('=')[1]`). Without it the code
logs `forwarded header not found` and falls back to the `Host` header, which is identical for every
visitor — collapsing all users into one shared rate-limit bucket. With it, per-IP limiting works.

Postgres, Redis and RabbitMQ publish **no host ports** (the dev compose publishes all of them) and
the RabbitMQ management UI is not exposed. The single exception is `auth`, published on
`127.0.0.1:8000` for admin-over-SSH as described below. Combined with the Hetzner Cloud Firewall
(inbound 22/80/443 only), the only internet-reachable surface is Caddy and SSH.

### Django admin is not proxied

Caddy has no `/admin/` route. To make it reachable without exposing it, `auth` publishes its port on
the server's **loopback only** (`127.0.0.1:8000:8000`), which the Hetzner firewall and the missing
public bind both keep off the internet. Admin access is then
`ssh -L 8000:127.0.0.1:8000 …` followed by `http://localhost:8000/admin/` on the workstation.
This removes a public login form from the attack surface, and sidesteps the fact that `DEBUG=False`
with no whitenoise means Django will not serve the admin's static files over the public origin.

### Container build files live in `hetzner_container/` inside each service repo

Matching the existing `dev_container/` and `aws_ecs_container/` convention. Only cross-service
orchestration lives in `deployment/hetzner`.

Production images differ from the dev images in four ways: no bind mounts (source is baked in), no
`--reload`, `AUTH_PRJ_MODE=prod`, and `web_client` becomes a **multi-stage** build — node:18.12.1
compiles the bundle, which is copied into `nginx:alpine`. The final web image is ~50 MB and contains
no `node_modules`, no toolchain and no source, versus the dev image which ships all three and runs
the CRA dev server.

One unavoidable exception to the `hetzner_container/` rule: Docker requires `.dockerignore` at the
**build-context root**, so each service repo gets a root-level `.dockerignore`. These exclude
`node_modules`, `.git`, `build/`, `__pycache__`, local virtualenvs and — importantly — `.env`, so
development secrets never get baked into a production image. This does not affect dev builds, which
bind-mount the source over `WORKDIR` and read env via compose's `env_file` from the host.

### Configuration: one generated `.env`, secrets never committed

`deployment/hetzner/.env` (gitignored; `.env.example` documents every key) is the single source of
configuration, generated once by `provision.sh` and consumed by `docker compose`. Passwords and
Django secret keys are generated with `openssl rand`. The dev defaults (`postgres/<dev-password>`,
`admin/admin`) are not reused.

Env precedence was verified to be safe: `django-environ`'s `read_env()` uses `setdefault`,
`python-dotenv`'s `load_dotenv()` defaults to `override=False`, and CRA gives shell variables
priority over `.env` files. In all three, container environment wins over any file that might be
present.

### Accounts: no credentials in the frontend

The login form must render **empty**. `REACT_APP_DEMO_LOGIN` and `REACT_APP_DEMO_PASSWORD` are built
as empty strings, so `constants.js` exports `""` and Formik's `initialValues` stay controlled and
blank. Visitors self-register — registration is open and `ACCOUNT_EMAIL_VERIFICATION = "none"` in
`prod.py`, so it works without an email backend.

Two accounts are seeded on deploy:

- a **superuser** with a generated password (never `admin/admin` on a public box), reachable only
  via SSH;
- a **non-staff demo user** whose password exists only in the server-side `.env`. It is not shipped
  to any client; its sole purpose is to let `verify.sh` exercise the real login → JWT → generate
  flow automatically.

### Accepted risk: the RunPod key ships in the JS bundle

`REACT_APP_RUNPOD_API_KEY` is inlined into `build/static/js/main.<hash>.js` by webpack's
DefinePlugin and is therefore readable by every visitor. `src/utils/runpod.js` needs it because the
browser polls `api.runpod.ai/v1/<endpoint>/status/<id>` directly; only run *initiation* goes through
`pre_inference`.

This was raised during design along with a server-side-proxy alternative (the `get_run_status/` and
`get_image/` endpoints already exist in `main.py` and would make the key unnecessary). **The owner
chose to accept the exposure** rather than change application code. RunPod API keys are
account-scoped, so the mitigation is operational, not architectural: rotate the key after launch and
set a RunPod spend limit. `deploy.sh` greps the built bundle and prints whether the key is present,
so the exposure is visible rather than assumed.

Because the key is public, run initiation can be bypassed entirely by calling RunPod directly, so a
proxy-level rate limit would not bound the cost. None is added; `pre_inference`'s existing per-user
limiter is retained for legitimate traffic.

## Repository layout

```
deployment/hetzner/                  # orchestration only
├── docs/2026-07-30-…-design.md      # this document
├── README.md                        # runbook: provision → DNS → deploy → verify → destroy
├── .gitignore                       # .secrets/, .env
├── .env.example
├── .secrets/                        # gitignored: hcloud_token, id_ed25519[.pub]
├── provision.sh                     # SSH key + firewall + server + .env generation
├── cloud-init.yaml                  # docker, swap, /opt/web_ai
├── deploy.sh                        # sync → build → up → migrate → seed
├── verify.sh                        # end-to-end acceptance gate
├── destroy.sh                       # delete server + firewall + SSH key
├── ssh.sh                           # convenience wrapper using the generated key
├── docker-compose.yml
├── Caddyfile
├── init-databases.sql               # CREATE DATABASE auth_prj, payments_prj
└── seed_accounts.py                 # superuser + demo user, idempotent

<repo>/hetzner_container/            # per service repo
├── Dockerfile
└── entrypoint.sh                    # auth, payments only
<repo>/.dockerignore                 # build-context root, required by Docker
```

Server layout mirrors the local tree so compose's relative build contexts
(`../../auth/auth_src`) resolve identically in both places:

```
/opt/web_ai/{deployment/hetzner, auth/auth_src, payments/payments_src,
             pre_inference/pre_inference_src, web_client/web_client_src}
```

## Provisioning

`provision.sh` is idempotent and talks to the Hetzner API with `curl`, reading the token from
`.secrets/hcloud_token`. It:

1. generates a dedicated passwordless **ed25519** keypair into `.secrets/` if absent (the personal
   `~/.ssh/id_rsa` is deliberately not reused);
2. uploads the public key as `web-ai-demo`;
3. creates firewall `web-ai-demo-fw` — inbound TCP 22, 80, 443 from anywhere, all outbound allowed;
4. creates server `web-ai-demo`: `cx23`, `nbg1`, `ubuntu-24.04`, the SSH key, the firewall, and
   `cloud-init.yaml` as user data;
5. generates `.env` with fresh secrets if it does not already exist;
6. writes `.secrets/server.json` and prints the IPv4 with the DNS records to create.

`cloud-init.yaml` installs Docker CE + the compose plugin from the official repository, creates a
2 GB swapfile with `vm.swappiness=10`, creates `/opt/web_ai`, and enforces
`PasswordAuthentication no`. Unattended security upgrades stay at the Ubuntu default (on).

## Deploy

`deploy.sh` is idempotent and re-runnable:

1. preflight — `.env` present, `server.json` present, `dig +short jinifai.com` matches the server IP
   (fail fast rather than burn a Let's Encrypt attempt);
2. ship source: `tar` the four service trees plus `deployment/hetzner`, excluding `node_modules`,
   `.git`, `build/`, `__pycache__` and virtualenvs, streamed over SSH into `/opt/web_ai`
   (≈5 MB, no rsync dependency — rsync is absent from Git Bash on the workstation);
3. `docker compose build` on the server (the CRA build is the slow step, ~10–15 min on 2 vCPU);
4. `docker compose up -d`, with `restart: unless-stopped` on every service;
5. wait for the postgres healthcheck; migrations run inside the auth/payments entrypoints, then
   accounts are seeded with
   `docker compose exec -T auth python manage.py shell < seed_accounts.py`, reading the superuser
   and demo-user credentials from the container environment. The script is idempotent — it creates
   each account only if the email is absent, and never rewrites an existing password;
6. grep the built bundle for the RunPod key and report the result.

## Verification — the completion gate

`verify.sh` runs against the public URL from the workstation, reading the demo-user credentials from
the local `.env`. It touches nothing on the server except over HTTPS and one SSH call for check 13.
Every check must pass:

1. `http://jinifai.com` → 301/308 to HTTPS.
2. `https://jinifai.com/` → 200, HTML containing the SPA root element; referenced JS bundle → 200.
3. TLS certificate valid, issued by Let's Encrypt, CN/SAN covers `jinifai.com`, not expired.
4. `GET /api/auth/healthcheck/` → 200.
5. `POST /api/auth/registration/` with a random address → 201 and a JWT (proves the DB is writable
   and self-registration works).
6. `POST /api/auth/login/` with the seeded demo user → 200 with `access` token.
7. `GET /api/payments/` with that token → 200 (proves the second DB and cross-service JWT sharing;
   `payments_prj` mounts its router at `api/` and registers the `payments` basename, so the public
   path is exactly `/api/payments/`).
8. RabbitMQ round trip: create a payment, then confirm the user's tier changed via the auth API —
   proves `payments` publisher → `auth` consumer thread works.
9. `POST /api/preinference/initiate_run/` with the token → `run_id`.
10. Poll `GET /api/preinference/get_run_status/` until `COMPLETED` (300 s timeout).
11. `GET /api/preinference/get_image/` → response body begins with the PNG magic bytes
    `\x89PNG` — real generated image, not a stub.
12. From outside, TCP 5432, 6379, 5672 and 15672 are not reachable.
13. `docker compose ps` shows every service `running`.
14. Reboot the server, wait for it to come back, and re-run checks 2, 4 and 6 — proves the demo
    survives an unattended restart.

The task is complete only when `verify.sh` exits 0 with check 11 satisfied.

## Teardown

`destroy.sh` deletes the server, firewall and uploaded SSH key, so the demo cannot quietly accrue
cost. It requires typing the server name to confirm, and warns that the Postgres volume dies with
the machine.

## Risks

| risk | handling |
|---|---|
| CRA build OOM/slow on 2 vCPU / 4 GB | 2 GB swap; `NODE_OPTIONS=--max-old-space-size=3072`; ~10–15 min is accepted |
| Let's Encrypt rate limits (5 duplicate certs/week) | DNS preflight in `deploy.sh` before Caddy ever starts |
| DNS not yet repointed from Namecheap parking | provision prints the exact records; deploy refuses to run until `@` resolves to the server IP |
| RunPod endpoint goes cold or the key is rotated | check 10 has a 300 s timeout and reports the RunPod status verbatim |
| RunPod key public in the bundle | accepted by the owner; rotate + spend limit recommended post-launch |
| Single host, no backups | accepted; `provision.sh` + `deploy.sh` rebuild from scratch in ~20 min |
