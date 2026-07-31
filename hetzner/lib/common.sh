#!/bin/sh
# Shared helpers for the Hetzner deployment scripts. POSIX sh, sourced not executed.

# Resolve this file's own location rather than the caller's. $0 is the invoking script, which
# is correct for ./provision.sh but wrong when common.sh is sourced straight from a shell
# (there $0 is the shell itself, e.g. /usr/bin/bash). $BASH_SOURCE is set whenever bash - or
# sh-as-bash - sources a file; plain POSIX shells fall back to $0.
if [ -n "${BASH_SOURCE:-}" ]; then
  HETZNER_DIR="$(cd "$(dirname "$BASH_SOURCE")/.." && pwd)"
else
  HETZNER_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
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
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Avast Antivirus intercepts TLS on the dev workstation and re-signs every certificate with
# its own root, which Git Bash's curl does not trust. provision.sh documents how .secrets/
# cacert.pem (Mozilla bundle + the Avast root) is produced; use it when present so that
# certificate verification stays ON rather than resorting to curl -k with a live API token.
if [ -f "$SECRETS_DIR/cacert.pem" ]; then
  CURL_CA_BUNDLE="$SECRETS_DIR/cacert.pem"
  export CURL_CA_BUNDLE
fi

# python is needed to parse JSON responses; jq is not present on the workstation.
# Each candidate is executed rather than merely located: on Windows, `python3` resolves to the
# Microsoft Store app-execution alias, which exists on PATH but only prints
# "Python was not found" and exits non-zero.
PY=""
for _cand in python3 python py; do
  if command -v "$_cand" >/dev/null 2>&1 && "$_cand" -c "import sys" >/dev/null 2>&1; then
    PY="$(command -v "$_cand")"
    break
  fi
done
unset _cand

json_get() {
  # usage: echo "$response" | json_get 'server.public_net.ipv4.ip'
  [ -n "$PY" ] || die "python is required to parse API responses"
  # Prints an empty string for any missing key or out-of-range index, so callers can test with
  # [ -z "$x" ] instead of trapping exceptions. "no such resource" is a normal answer here.
  "$PY" -c '
import json,sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print(""); raise SystemExit(0)
for p in sys.argv[1].split("."):
    if p.isdigit():
        i = int(p)
        d = d[i] if isinstance(d, list) and len(d) > i else None
    else:
        d = d.get(p) if isinstance(d, dict) else None
    if d is None:
        break
print("" if d is None else d)
' "$1"
}

gen_secret() {
  # 32+ bytes of entropy, stripped of characters that are awkward in .env files and URLs
  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-50
}

load_env() {
  [ -f "$1" ] || die "env file not found: $1 (run ./provision.sh first)"
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
