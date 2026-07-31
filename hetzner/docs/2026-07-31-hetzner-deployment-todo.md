# Hetzner deployment — deferred follow-ups

Date: 2026-07-31

Items 1-4 and 8 from the 2026-07-31 three-reviewer code review (shell scripting, Docker/Caddy,
security) were fixed in commit `6a1674a` on `hetzner-demo-deployment`. The items below were
raised in that same review but deliberately deferred — not forgotten, not dismissed. Numbering
continues from the original consolidated list so it cross-references the review conversation.

## 1. web client should poll for runpod status through the web inference proxy not directly 

## 2. Move seed_accounts.py from deployment to auth

## 3. Make a nice deployment process from github push to container hub build and push to deployment with the new image 

## 4. Rate limiting is keyed by IP, not by user

**Where:** `pre_inference/pre_inference_src/main.py`, `limiter_key()` (main.py:51-64) and the
`@limiter.limit(get_limit_for_user)` decorators on `initiate_run`/`generate_img`.

**Problem:** the request's tier decides the *ceiling* (5/min-30/day for Free, 60/min-2000/day
for Premium), but the limiter bucket is keyed solely by source IP (via the `Forwarded` header
Caddy sets), not by `user_id`. One IP always gets one fresh budget regardless of which JWT — or
no JWT — is presented. Rotating source IPs (cheap via any proxy) gives unlimited independent
budgets against the same RunPod account.

**Fix:** key the limiter by `user_id` when a valid JWT is present, falling back to IP only for
genuinely anonymous requests. Requires reading the decoded JWT inside `limiter_key()` (the
decode logic already exists in `jwt_decode()`, just needs wiring into the key function).

## 5. Free self-registration + unconditional mock-payment tier upgrade

**Where:** `auth/auth_src/auth_app/consumer.py:107-117` (the RabbitMQ consumer's
`on_message_callback`) and `payments/payments_src/payments_app/views.py` (`PaymentViewSet.create`).

**Problem:** `on_message_callback` sets `user.tier = Tiers.premium` on *any* payment message,
never checking `amount`. Combined with open self-registration (no CAPTCHA,
`ACCOUNT_EMAIL_VERIFICATION = "none"`) and no throttling on `/api/auth/registration/` or
`/api/payments/`, the full exploit chain is: register → log in → `POST /api/payments/
{"amount":"0.01"}` → immediately hold a Premium JWT (2000 calls/day) for free. Also,
`initiate_run`/`generate_img` require no authentication at all — an anonymous caller still gets
the Free tier's 30 calls/day.

**Fix, in rough order of leverage:**
- Require authentication (a valid JWT) on `initiate_run`/`generate_img` — currently optional.
- Make the tier upgrade amount-aware, or cap it to one mock "purchase" per account.
- Add DRF throttling (`AnonRateThrottle`/`UserRateThrottle`) to registration and login.
- Clamp `height`/`width`/`num_inference_steps`/`guidance_scale` in `pre_inference` to a fixed
  allowlist — currently unbounded, so even a rate-limited caller can make each call arbitrarily
  more expensive.

**Mitigating context:** the account's RunPod balance is small and autopay is off, so the
financial blast radius is already capped at "burn through a small demo balance," not open-ended
spend. This lowers urgency but doesn't make the underlying logic correct.

## 6. drf-spectacular API docs are publicly routed

**Where:** `auth/auth_src/auth_prj/urls.py:42-45` (`/api/auth/schema/`, `/api/auth/docs/`,
`/api/auth/schema/redoc/`), reachable because `Caddyfile` forwards all of `/api/auth/*` to
`auth:8000`.

**Problem:** any visitor gets a complete, browsable map of the auth API's serializers and
fields — unnecessary reconnaissance assistance for a public demo, and inconsistent with the
`/admin/`-stays-private design elsewhere in this deployment.

**Fix:** either drop these three paths from the production URLconf, or give them the same
loopback + SSH-tunnel treatment as `/admin/` (would need a dedicated Caddy `handle` block that
excludes just these three paths from the public `/api/auth/*` proxy, or moving them off the
`auth` container's public bind entirely).

## 7. `provision.sh` / `destroy.sh` edge cases

**Where:** `deployment/hetzner/provision.sh`, `deployment/hetzner/destroy.sh`.

Four independent, low-probability-but-real gaps, all stemming from the scripts trusting API
responses more than they should:

- **Stale SSH key reuse** (`provision.sh:34-45`): if the local keypair is deleted or the repo
  re-cloned while Hetzner still has a key named `web-ai-demo`, a fresh keypair is generated but
  the *old* key is reused for any new server (matched by name, not by fingerprint) — so a future
  server ends up authorized for a private key that no longer exists locally. Surfaces later as an
  inscrutable `Permission denied (publickey)`. Fix: compare `ssh-keygen -lf` against the API's
  reported fingerprint; re-upload if they differ.
- **Firewall only attached at server-create time** (`provision.sh:49-71`): if the server exists
  but its firewall was separately recreated (e.g. a partial prior teardown), a re-run prints a
  healthy-looking firewall ID without confirming it's actually attached to the running server.
  Fix: always (idempotently) apply the firewall to the server, or read back the server's attached
  firewalls and warn on mismatch.
- **`known_hosts` not cleaned up by `destroy.sh`**: a rebuilt server frequently lands on a
  different IP with a different host key. Since `ssh_args()` pins
  `UserKnownHostsFile=.secrets/known_hosts` with `StrictHostKeyChecking=accept-new`, the next
  `provision.sh` + `deploy.sh` cycle can fail with `REMOTE HOST IDENTIFICATION HAS CHANGED`,
  contradicting the "rebuild from scratch in ~20 min" recovery story. Fix: `rm -f
  .secrets/known_hosts` (or `ssh-keygen -R <ip>`) in `destroy.sh`.
- **A failed IP lookup can clobber a good `server.json`** (`provision.sh:73-75`): no guard on
  `$SRV_IP` before writing `server.json`; a transient API error on a re-run would write an empty
  IP, silently losing the record of the live server's address. Fix: `[ -n "$SRV_IP" ] || die ...`
  before writing.

## 8. Missing `set -o pipefail`

**Where:** all five scripts (`#!/bin/sh`, `set -e`, no `pipefail`).

**Problem:** every `local-command | remote-command` pipeline (most notably `deploy.sh`'s
`tar czf - ... | ssh ... "tar xzf -"`) only reports the *last* command's exit status. GNU `tar`
can exit non-zero on a partial failure (e.g. a member vanishing mid-read) while still producing a
valid, partial archive — the remote extract of that partial archive can succeed, so the pipeline
reports success while a service silently deployed from stale or incomplete source. Same masking
applies to every `api ... | json_get ...` call in `provision.sh`/`destroy.sh`.

**Fix:** since these scripts already require bash in practice (Git Bash on the workstation,
Ubuntu on the server — `/dev/tcp` and other bash-isms were already avoided, but the tooling
itself is bash), switching the shebang to `#!/usr/bin/env bash` and adding
`set -euo pipefail` is the cleanest fix. Needs a full re-test of all five scripts afterward, since
`pipefail` can surface previously-masked failures in existing pipelines.

## Not on this list

Everything categorized as Minor in the original three reviews (non-root containers, network
segmentation, log rotation / image pruning, a dead `DEBUG` env var, digest-pinning base images,
`ALLOWED_HOSTS`/`CORS_ALLOW_ALL_ORIGINS` cleanup, a CSP header, `RabbitMQ` guest credentials) is
tracked only in the review conversation, not repeated here. Promote any of them to this doc if
they turn out to matter in practice.
