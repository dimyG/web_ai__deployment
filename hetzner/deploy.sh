#!/bin/sh
# Ships source to the server, builds the images there and starts the stack.
# Idempotent and re-runnable; a deploy is a short outage, not a zero-downtime rollout.
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
if [ "$1" != "--skip-dns-check" ]; then
  log "checking that $DOMAIN resolves to $IP"
  RESOLVED="$(nslookup "$DOMAIN" 8.8.8.8 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)"
  if [ "$RESOLVED" != "$IP" ]; then
    die "$DOMAIN resolves to '${RESOLVED:-nothing}', expected $IP.
Create the A records printed by provision.sh and wait for propagation, then re-run.
Use --skip-dns-check only if you know the record is correct and merely slow to propagate."
  fi
  log "dns ok"
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

# Postgres being healthy (compose's depends_on already guarantees that by the time `up -d`
# returns) does NOT mean auth is ready - auth's entrypoint still has to run `manage.py migrate`
# and bind gunicorn afterwards. Seeding against an auth container that's still mid-migration
# fails with "relation does not exist", so this waits for the thing that actually matters:
# auth answering its own healthcheck on the loopback port it's published on.
log "waiting for auth to become ready (migrations + gunicorn bind)"
$SSH "cd $REMOTE_DIR/deployment/hetzner && for i in \$(seq 1 60); do
  if curl -sf -o /dev/null http://127.0.0.1:8000/api/auth/healthcheck/; then echo 'auth ready'; exit 0; fi
  sleep 3
done; echo 'auth did not become ready in time'; docker compose logs --tail=60 auth; exit 1"

log "seeding accounts"
$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose exec -T auth python manage.py shell" < "$HETZNER_DIR/seed_accounts.py"

# --- report ----------------------------------------------------------------
log "auditing what ended up in the public JS bundle"
$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose exec -T web sh -c '
  cd /usr/share/nginx/html
  echo \"  runpod key occurrences : \$(grep -ro \"$RUNPOD_API_KEY\" static/js | wc -l)   <- accepted risk, rotate after launch\"
  echo \"  sourcemaps             : \$(ls static/js/*.map 2>/dev/null | wc -l)\"
'" || warn "bundle audit failed (non-fatal)"

$SSH "cd $REMOTE_DIR/deployment/hetzner && docker compose ps"
log "deploy complete - now run ./verify.sh"
