#!/bin/sh
# Deletes the server, firewall and uploaded SSH key so the demo cannot keep costing money.
#   ./destroy.sh --dry-run    show what would be deleted, delete nothing
set -e
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_cmd curl
[ -f "$SECRETS_DIR/hcloud_token" ] || die "missing $SECRETS_DIR/hcloud_token"
TOKEN="$(tr -d '\r\n' < "$SECRETS_DIR/hcloud_token")"
API="https://api.hetzner.cloud/v1"

# Dies loudly on anything but a 2xx response, so an expired token, a rate limit, or a Hetzner
# outage is never silently read as "the resource doesn't exist" - a plain curl with no status
# check would let exactly that happen, which is how this script used to report success while
# deleting nothing and leaving the server billing.
api() { # api METHOD PATH [BODY] -> prints the response body
  RAW="$(
    if [ -n "$3" ]; then
      curl -sS -w '\nHTTPSTATUS:%{http_code}' -X "$1" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$3" "$API$2"
    else
      curl -sS -w '\nHTTPSTATUS:%{http_code}' -X "$1" -H "Authorization: Bearer $TOKEN" "$API$2"
    fi
  )"
  STATUS="$(printf '%s' "$RAW" | sed -n '$p' | sed -n 's/^HTTPSTATUS://p')"
  BODY="$(printf '%s' "$RAW" | sed '$d')"
  case "$STATUS" in
    2*) printf '%s' "$BODY" ;;
    *) die "Hetzner API $1 $2 failed (HTTP ${STATUS:-?}): $BODY" ;;
  esac
}

# Server/firewall/key deletion is asynchronous - the DELETE call only queues the action - so
# this polls to actual completion instead of guessing with a fixed sleep.
wait_for_action() { # wait_for_action <action-id>
  ACTION_ID="$1"
  [ -n "$ACTION_ID" ] || return 0
  i=0
  while [ $i -lt 30 ]; do
    ACTION_STATUS="$(api GET "/actions/$ACTION_ID" | json_get 'action.status')"
    case "$ACTION_STATUS" in
      success) return 0 ;;
      error) die "Hetzner action $ACTION_ID (on /actions/$ACTION_ID) failed" ;;
    esac
    sleep 2
    i=$((i + 1))
  done
  die "Hetzner action $ACTION_ID did not finish within 60s"
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

if [ -n "$SRV_ID" ]; then
  log "deleting server $SRV_ID"
  ACTION_ID="$(api DELETE "/servers/$SRV_ID" | json_get 'action.id')"
  wait_for_action "$ACTION_ID"
fi

# The firewall is only detachable once the server referencing it is actually gone, which
# wait_for_action just confirmed - no more guessing with a fixed sleep.
if [ -n "$FW_ID" ]; then
  log "deleting firewall $FW_ID"
  api DELETE "/firewalls/$FW_ID" >/dev/null
fi

if [ -n "$KEY_ID" ]; then
  log "deleting ssh key $KEY_ID"
  api DELETE "/ssh_keys/$KEY_ID" >/dev/null
fi

# Re-query rather than trust the DELETE calls above: this is what actually confirms the
# resources are gone, instead of printing "done" over an API call that silently no-op'd.
SRV_LEFT="$(api GET "/servers?name=$SERVER_NAME" | json_get 'servers.0.id')"
FW_LEFT="$(api GET "/firewalls?name=$FIREWALL_NAME" | json_get 'firewalls.0.id')"
KEY_LEFT="$(api GET "/ssh_keys?name=$SSH_KEY_NAME" | json_get 'ssh_keys.0.id')"
[ -z "$SRV_LEFT" ] || die "server $SRV_LEFT still exists after deletion - it is likely still billing"
[ -z "$FW_LEFT" ]  || die "firewall $FW_LEFT still exists after deletion"
[ -z "$KEY_LEFT" ] || die "ssh key $KEY_LEFT still exists after deletion"

rm -f "$SERVER_JSON"
log "confirmed: server, firewall and ssh key are all gone."
log ".env and the local keypair were kept - delete .secrets/ by hand if you want a clean slate."
