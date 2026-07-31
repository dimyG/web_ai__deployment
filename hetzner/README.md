# Hetzner demo deployment

Runs the whole web_ai stack as a public demo at **https://jinifai.com** on a single Hetzner
Cloud VPS via Docker Compose, behind Caddy for automatic TLS. Design rationale lives in
`docs/2026-07-30-hetzner-demo-deployment-design.md`; the task-by-task build log is in
`docs/2026-07-30-hetzner-demo-deployment-plan.md`.

## Cost

€5.49/mo (server, `cx23`) + €0.50/mo (primary IPv4) = **€5.99/mo net**, €7.43/mo gross with the
account's 24% VAT. 20 TB of traffic is included. Billed hourly at ~€0.009/hour while the server
exists — `./destroy.sh` stops the meter.

## One-time setup

1. Create a Hetzner Cloud project and an API token (Read & Write), save it as plain text to
   `.secrets/hcloud_token` (gitignored).
2. **Windows only:** Avast Antivirus intercepts outbound TLS and re-signs every certificate with
   its own root, which Git Bash's `curl` does not trust by default. Build a merged CA bundle once:

   ```powershell
   $dir = '<repo>\deployment\hetzner\.secrets'
   $roots = Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root | Where-Object { $_.Subject -like '*Avast*' }
   $pem = foreach ($c in $roots) { '-----BEGIN CERTIFICATE-----'; [Convert]::ToBase64String($c.RawData,'InsertLineBreaks'); '-----END CERTIFICATE-----' }
   $pem | Out-File "$dir\avast-root.pem" -Encoding ascii
   Invoke-WebRequest https://curl.se/ca/cacert.pem -OutFile "$dir\mozilla-cacert.pem" -UseBasicParsing
   Get-Content "$dir\mozilla-cacert.pem", "$dir\avast-root.pem" | Set-Content "$dir\cacert.pem" -Encoding ascii
   ```

   `lib/common.sh` picks this up automatically as `CURL_CA_BUNDLE` when present. If you are not
   running Avast (or on Linux/macOS), skip this — verification will fall back to the system
   bundle and just work.
3. `./provision.sh` — creates a dedicated SSH keypair, a firewall (22/80/443 only), the server,
   and generates `.env` with fresh secrets. Prints the server's IPv4 and the DNS records to create.
4. At your DNS provider, replace any existing records with:

   | type | host | value |
   |---|---|---|
   | A | `@` | *(the IP `provision.sh` printed)* |
   | A | `www` | *(same IP)* |

   Wait for propagation (`nslookup jinifai.com 8.8.8.8`) before deploying — Let's Encrypt allows
   only 5 duplicate certificates per registered domain per week, and `deploy.sh` refuses to run
   until DNS is correct specifically to avoid burning through that quota.

## Deploying

```sh
./deploy.sh
```

Ships the four service source trees plus this directory to `/opt/web_ai` on the server (excludes
`node_modules`, `.git`, `build/`, `__pycache__`, venvs), builds all images there, starts the stack,
waits for Postgres, seeds the superuser and demo accounts, and prints how many times the RunPod
key shows up in the built JS bundle (see "Accepted risk" below). The image build takes roughly
10-15 minutes on the server's 2 vCPUs, dominated by the React production build.

Re-running `deploy.sh` is safe: it never overwrites `.env`, and account seeding is idempotent
(it skips any email that already exists rather than resetting its password).

If DNS is correct but propagation is slow to resolve from your resolver, pass
`./deploy.sh --skip-dns-check` to bypass the preflight — only do this once you've independently
confirmed the A record is right, since a wrong skip wastes a Let's Encrypt attempt.

## Verifying

```sh
./verify.sh              # full run, ends with a reboot to prove the stack survives a restart
./verify.sh --no-reboot  # skip the reboot (default choice during iteration)
```

Checks, in order: HTTPS redirect and a real Let's Encrypt certificate (checked *on the server*
via SSH, since Avast's local interception would otherwise make a valid cert look wrong from this
workstation); the SPA and its JS bundle load; self-registration and demo login both return a JWT;
the payments → RabbitMQ → auth tier-upgrade round trip (Free → Premium); a full RunPod
image-generation run (`initiate_run` → poll to `COMPLETED` → fetch real PNG bytes); Postgres,
Redis, RabbitMQ and the RabbitMQ management UI are unreachable from the internet; all 8 containers
are running; and, unless `--no-reboot` is passed, that the demo comes back up cleanly after an
unattended reboot.

## Redeploying after a code change

Pull/commit your change in the relevant service repo (`auth`, `payments`, `pre_inference`, or
`web_client`, each on the `hetzner-container` branch), then re-run `./deploy.sh` from this
machine — it re-ships the current working tree, not a pushed branch.

## Logs and debugging

```sh
./ssh.sh 'cd /opt/web_ai/deployment/hetzner && docker compose logs --tail=100 <service>'
./ssh.sh 'cd /opt/web_ai/deployment/hetzner && docker compose ps'
```

A 502 from Caddy on an API path means Caddy can't reach that upstream — check that service's logs.
A tier that never leaves `Free` after a payment means the RabbitMQ consumer isn't connected —
check `docker compose logs auth | grep -i rabbit`. A RunPod run stuck in `IN_QUEUE` usually just
means the serverless worker is cold; `verify.sh` waits up to 5 minutes before giving up.

## Reaching the Django admin

Not exposed publicly by design — `/admin/` is a public login form, and Django's `DEBUG=False`
means the admin's CSS wouldn't load correctly over the public origin without extra static-file
setup anyway. The `auth` container publishes on `127.0.0.1:8000` on the server, so:

```sh
./ssh.sh -L 8000:127.0.0.1:8000
# then, in a browser on your machine:
open http://localhost:8000/admin/
```

Login with `DJANGO_SUPERUSER_EMAIL` / `DJANGO_SUPERUSER_PASSWORD` from `.env`.

## Where the secrets are

Everything generated by `provision.sh` lives in `.env` on this machine and on the server at
`/opt/web_ai/deployment/hetzner/.env` (both gitignored, mode 600). It holds the Postgres password,
the shared JWT signing key, the superuser and demo-user credentials, and the RunPod API key.
Nothing in `.env` is ever printed by these scripts except the RunPod-key occurrence count in the
public bundle, which is a count, not the key itself.

## Accepted risk: the RunPod key is public

`REACT_APP_RUNPOD_API_KEY` is inlined into the SPA's JavaScript bundle by webpack at build time
(measured: 8 occurrences in `main.*.chunk.js`) because the browser polls RunPod's status endpoint
directly. This was raised during design — `pre_inference` already has `get_run_status/` and
`get_image/` endpoints that would make the key unnecessary — and the project owner chose to accept
the exposure rather than change `web_client`. Since RunPod keys are account-scoped, **rotate the
key and set a RunPod spend limit** after the first public launch, and update `RUNPOD_API_KEY` in
`.env` followed by `./deploy.sh` when you do.

## No backups

Postgres data lives in a named Docker volume on the server only. There is no backup job by
design — this is a disposable demo, and `deploy.sh`'s account seeding recreates what's needed from
scratch. If the server is destroyed, all registered demo users and payment history go with it.

## Tearing down

```sh
./destroy.sh --dry-run   # see what would be deleted, delete nothing
./destroy.sh             # deletes the server, firewall and SSH key after typing "web-ai-demo" to confirm
```

`.env` and the local SSH keypair are kept so a future `./provision.sh` + `./deploy.sh` can bring
the exact same demo back up. Delete `.secrets/` by hand for a fully clean slate.
