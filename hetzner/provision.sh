#!/bin/sh
# Creates the Hetzner SSH key, firewall and server, and generates .env.
# Idempotent: existing resources are reused, an existing .env is never overwritten.
#
# TLS note for Git Bash on Windows: Avast intercepts HTTPS and re-signs certificates with its
# own root, which curl's bundle does not trust. lib/common.sh picks up .secrets/cacert.pem
# (Mozilla bundle + the Avast root) when present so verification stays enabled. Produce it with:
#   powershell -NoProfile -Command "$dir='<...>\.secrets'; \
#     $roots = Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root | ? { $_.Subject -like '*Avast*' }; \
#     $pem = foreach ($c in $roots) { '-----BEGIN CERTIFICATE-----'; [Convert]::ToBase64String($c.RawData,'InsertLineBreaks'); '-----END CERTIFICATE-----' }; \
#     $pem | Out-File \"$dir\avast-root.pem\" -Encoding ascii; \
#     Invoke-WebRequest https://curl.se/ca/cacert.pem -OutFile \"$dir\mozilla-cacert.pem\" -UseBasicParsing; \
#     Get-Content \"$dir\mozilla-cacert.pem\", \"$dir\avast-root.pem\" | Set-Content \"$dir\cacert.pem\" -Encoding ascii"
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd curl
require_cmd openssl
require_cmd ssh-keygen

[ -f "$SECRETS_DIR/hcloud_token" ] || die "missing $SECRETS_DIR/hcloud_token"
TOKEN="$(tr -d '\r\n' < "$SECRETS_DIR/hcloud_token")"
API="https://api.hetzner.cloud/v1"

# The RunPod key is read from its own secrets file rather than hardcoded here, so it never
# lands in a commit. If you don't have this file yet, create it with the key you already use
# in pre_inference/pre_inference_src/.env for local dev:
#   printf '%s' 'your-runpod-api-key' > .secrets/runpod_key
[ -f "$SECRETS_DIR/runpod_key" ] || die "missing $SECRETS_DIR/runpod_key (see comment above this line)"
RUNPOD_API_KEY="$(tr -d '\r\n' < "$SECRETS_DIR/runpod_key")"

# Let's Encrypt requires a real, working email for expiry/problem notices. Read from a secrets
# file rather than hardcoding a personal address here, so it never lands in a commit:
#   printf '%s' 'you@example.com' > .secrets/acme_email
[ -f "$SECRETS_DIR/acme_email" ] || die "missing $SECRETS_DIR/acme_email (see comment above this line)"
ACME_EMAIL="$(tr -d '\r\n' < "$SECRETS_DIR/acme_email")"

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

KEY_ID="$(api GET "/ssh_keys?name=$SSH_KEY_NAME" | json_get 'ssh_keys.0.id')"
if [ -z "$KEY_ID" ]; then
  log "uploading SSH key as '$SSH_KEY_NAME'"
  PUBKEY="$(tr -d '\r\n' < "$SSH_KEY.pub")"
  KEY_ID="$(api POST "/ssh_keys" "{\"name\":\"$SSH_KEY_NAME\",\"public_key\":\"$PUBKEY\"}" | json_get 'ssh_key.id')"
  [ -n "$KEY_ID" ] || die "failed to upload SSH key"
fi
log "ssh key id: $KEY_ID"

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
  BODY="{\"name\":\"$SERVER_NAME\",\"server_type\":\"$SERVER_TYPE\",\"location\":\"$SERVER_LOCATION\",\"image\":\"$SERVER_IMAGE\",\"ssh_keys\":[$KEY_ID],\"firewalls\":[{\"firewall\":$FW_ID}],\"user_data\":$USER_DATA,\"labels\":{\"project\":\"web_ai\",\"env\":\"demo\"}}"
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
ACME_EMAIL=$ACME_EMAIL
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
RUNPOD_API_KEY=$RUNPOD_API_KEY
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
