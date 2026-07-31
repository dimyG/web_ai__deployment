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

# Avast Antivirus intercepts TLS on this workstation and re-signs every certificate with its own
# root (confirmed during provisioning - see provision.sh header). Checking the certificate from
# here would see Avast's certificate, not Let's Encrypt's, so these two checks run ON THE SERVER
# via SSH instead of locally.
CERT_ISSUER="$(ssh $(ssh_args) "root@$IP" "echo | openssl s_client -connect localhost:443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -issuer" 2>/dev/null)"
check_not "cert issued by Let's Encrypt (checked on server)" "$(printf '%s' "$CERT_ISSUER" | grep -c "Let's Encrypt")" "0"
CERT_SAN="$(ssh $(ssh_args) "root@$IP" "echo | openssl s_client -connect localhost:443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -text" 2>/dev/null)"
check "cert covers the domain (checked on server)" "$(printf '%s' "$CERT_SAN" | grep -c "DNS:$DOMAIN")" "1"

log "4-6  auth service"
check "healthcheck" "$(code "$BASE/api/auth/healthcheck/")" "200"

decode_claim() { # decode_claim <jwt> <claim>
  printf '%s' "$1" | "$PY" -c '
import base64,json,sys
try:
    payload = sys.stdin.read().split(".")[1]
    payload += "=" * (-len(payload) % 4)
    print(json.loads(base64.urlsafe_b64decode(payload)).get(sys.argv[1], ""))
except Exception:
    print("")
' "$2"
}

login() { # login <email> <password> -> access token, or empty on failure
  RESP="$(curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$2\"}" "$BASE/api/auth/login/")"
  printf '%s' "$RESP" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: print("")'
}

# The seeded demo user is a persistent account that stays Premium forever after its first
# successful payment round trip below, so re-running this script against it would let the
# RabbitMQ check pass every time afterwards without RabbitMQ doing anything - a fresh user is
# registered instead, so the round trip below is exercised for real on every single run.
RANDOM_EMAIL="probe-$(date +%s 2>/dev/null || echo $$)-$$@example.com"
REG_BODY="{\"username\":\"$RANDOM_EMAIL\",\"email\":\"$RANDOM_EMAIL\",\"password1\":\"Pr0be-passw0rd!x\",\"password2\":\"Pr0be-passw0rd!x\"}"
check "self-registration works" \
  "$(code -X POST -H 'Content-Type: application/json' -d "$REG_BODY" "$BASE/api/auth/registration/")" "201"

TOKEN="$(login "$RANDOM_EMAIL" "Pr0be-passw0rd!x")"
check_not "newly registered user can log in" "$([ -n "$TOKEN" ] && echo yes || echo no)" "no"
check "new user starts on the Free tier" "$(decode_claim "$TOKEN" tier)" "Free"

# The seeded demo account is checked separately, on its own, so a broken seed_accounts.py run
# is still caught even though the round trip above no longer depends on this account.
DEMO_TOKEN="$(login "$DEMO_USER_EMAIL" "$DEMO_USER_PASSWORD")"
check_not "seeded demo account can log in" "$([ -n "$DEMO_TOKEN" ] && echo yes || echo no)" "no"

log "7-8  payments and the RabbitMQ round trip"
check "payments list" "$(code -H "Authorization: Bearer $TOKEN" "$BASE/api/payments/")" "200"

check "create payment" \
  "$(code -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"amount":"9.99"}' "$BASE/api/payments/")" "201"

# payments publishes to the 'payments' fanout exchange; auth's consumer thread sets tier=Premium.
# Polled rather than a fixed sleep, since the consumer's processing time can vary under load.
TIER_AFTER=""
i=0
while [ $i -lt 6 ]; do
  sleep 3
  TOKEN2="$(login "$RANDOM_EMAIL" "Pr0be-passw0rd!x")"
  TIER_AFTER="$(decode_claim "$TOKEN2" tier)"
  [ "$TIER_AFTER" = "Premium" ] && break
  i=$((i + 1))
done
check "rabbitmq round trip upgraded the tier" "$TIER_AFTER" "Premium"

log "9-11 image generation through RunPod"
# The model string must be one of src/features/textToImage/text2img_models.js; the RunPod
# handler rejects anything else with {"error":"Unsupported model: ..."} and status FAILED.
RUN_QS="prompt=a%20photo%20of%20an%20astronaut%20riding%20a%20horse&model=stabilityai%2Fstable-diffusion-2-1&seed=42&height=512&width=512&guidance_scale=7.5&num_inference_steps=20"
RUN_JSON="$(curl -s --max-time 60 -X POST -H "Authorization: Bearer $TOKEN2" "$BASE/api/preinference/initiate_run/?$RUN_QS")"
RUN_ID="$(printf '%s' "$RUN_JSON" | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("run_id",""))
except Exception: print("")')"
check_not "initiate_run returned a run_id" "$([ -n "$RUN_ID" ] && echo yes || echo no)" "no"
[ -n "$RUN_ID" ] || warn "initiate_run response was: $RUN_JSON"

STATUS=""
if [ -n "$RUN_ID" ]; then
  i=0
  while [ $i -lt 60 ]; do
    STATUS="$(curl -s --max-time 30 -H "Authorization: Bearer $TOKEN2" \
      "$BASE/api/preinference/get_run_status/?run_id=$RUN_ID" \
      | "$PY" -c 'import json,sys
try: print(json.load(sys.stdin).get("run_status",""))
except Exception: print("")')"
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
    "$(head -c 4 /tmp/verify_image.png | od -An -tx1 | tr -d ' \n')" "89504e47"
  log "     image size: $(wc -c < /tmp/verify_image.png) bytes"
elif [ "$STATUS" = "FAILED" ]; then
  warn "run failed - check RunPod status directly: $BASE/api/preinference/get_run_status/?run_id=$RUN_ID"
fi

log "12   internal ports are not exposed"
# /dev/tcp is a bash-ism and not guaranteed under /bin/sh, so use python (already required
# above) for a portable TCP connect-or-timeout check.
port_state() { # port_state <ip> <port> -> "open" or "closed"
  "$PY" -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
try:
    s.connect((sys.argv[1], int(sys.argv[2])))
    print("open")
except Exception:
    print("closed")
finally:
    s.close()
' "$1" "$2"
}
for p in 5432 6379 5672 15672; do
  check "port $p closed to the internet" "$(port_state "$IP" "$p")" "closed"
done

log "13   containers"
RUNNING="$(ssh $(ssh_args) "root@$IP" "cd $REMOTE_DIR/deployment/hetzner && docker compose ps --status running --format '{{.Service}}' | wc -l" 2>/dev/null | tr -d '\r')"
check "all 8 services running" "$RUNNING" "8"

if [ "$1" != "--no-reboot" ]; then
  log "14   reboot resilience"

  # A fixed sleep before polling health can't tell "the box already came back up in 30s" apart
  # from "the box never actually went down" - stopping 8 containers can take longer than 30s,
  # so the very first health probe could hit the still-running pre-reboot instance and pass
  # every check below without a reboot having happened at all. The kernel's boot_id changes
  # on every boot, so comparing it before and after is what actually proves a reboot occurred.
  BOOT_BEFORE="$(ssh -o ConnectTimeout=5 $(ssh_args) "root@$IP" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
  [ -n "$BOOT_BEFORE" ] || warn "could not read boot_id before rebooting - the reboot-detection check below will fail closed"

  ssh $(ssh_args) "root@$IP" "nohup sh -c 'sleep 1; reboot' >/dev/null 2>&1 &" || true
  log "     waiting for the server to actually reboot (this can take a couple of minutes)"
  BOOT_AFTER=""
  i=0
  while [ $i -lt 60 ]; do
    sleep 5
    BOOT_AFTER="$(ssh -o ConnectTimeout=5 $(ssh_args) "root@$IP" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    [ -n "$BOOT_AFTER" ] && [ "$BOOT_AFTER" != "$BOOT_BEFORE" ] && break
    i=$((i + 1))
  done
  REBOOTED=no
  [ -n "$BOOT_BEFORE" ] && [ -n "$BOOT_AFTER" ] && [ "$BOOT_AFTER" != "$BOOT_BEFORE" ] && REBOOTED=yes
  check "server actually rebooted (boot id changed)" "$REBOOTED" "yes"

  log "     waiting for the app to come back up"
  i=0
  while [ $i -lt 40 ]; do
    if [ "$(code "$BASE/api/auth/healthcheck/")" = "200" ]; then break; fi
    sleep 5
    i=$((i + 1))
  done
  check "spa serves after reboot" "$(code "$BASE/")" "200"
  check "healthcheck after reboot" "$(code "$BASE/api/auth/healthcheck/")" "200"
  POST_REBOOT_TOKEN="$(login "$DEMO_USER_EMAIL" "$DEMO_USER_PASSWORD")"
  check_not "login works after reboot" "$([ -n "$POST_REBOOT_TOKEN" ] && echo yes || echo no)" "no"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  log "ALL $PASSES CHECKS PASSED - https://$DOMAIN is live"
  exit 0
fi
die "$FAILURES check(s) failed, $PASSES passed"
