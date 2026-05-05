# Installing TenderFlow

This guide is for **operators self-hosting TenderFlow** with the published
Docker images. If you're contributing to the codebase, start with
`./manage.sh setup` instead — see `README.md` and `CLAUDE.md`.

---

## Requirements

- Linux server with Docker 24+ and Docker Compose v2
- A domain you control, pointed to the server's public IP (for HTTPS)
- Ports 80 and 443 reachable from the internet (Let's Encrypt validation)
- 2 GB RAM, 1 CPU, 20 GB disk minimum (4 GB / 2 CPU recommended)

If you're testing locally without a public domain, run with `DOMAIN=:80`
and browse on port `8080` — see "Local install" below.

---

## Easiest path — one-line installer

On a fresh Ubuntu/Debian/RHEL/Fedora VM with `curl` and internet access:

```bash
curl -fsSL https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/install.sh -o tenderflow-install.sh
bash tenderflow-install.sh
```

The script will:
- Check Docker (offer to install if missing)
- Ask whether you have a public domain (Let's Encrypt) or want local HTTP mode
- Generate random `POSTGRES_PASSWORD` + `JWT_SECRET`
- Pull the configured release images from GHCR
- Start the stack and wait for it to be healthy
- Print the bootstrap admin password (capture it before first login!)
- Print the `/setup` wizard URL

That's it — skip to **step 5** below to run the setup wizard.

The manual path is below if you'd rather drive every step yourself.

---

## Manual install (with HTTPS)

### 1. Download the compose file and env template

```bash
mkdir -p ~/tenderflow && cd ~/tenderflow

curl -O https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/docker-compose.dist.yml
curl -O https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/.env.dist.example
mv .env.dist.example .env
```

### 2. Fill in required values

Edit `.env` and set:

| Variable | What to use |
|---|---|
| `DOMAIN` | Your hostname, e.g. `tenderflow.acme.com` |
| `DOMAIN_URL` | Same with scheme, e.g. `https://tenderflow.acme.com` |
| `ACME_EMAIL` | Email for Let's Encrypt (cert expiry warnings come here) |
| `POSTGRES_PASSWORD` | Run `openssl rand -base64 32` and paste |
| `JWT_SECRET` | Run `openssl rand -base64 48` and paste |
| `HTTP_PORT` | **For a real domain, set to `80`** (defaults to `8080` for safe local boot). Required for Let's Encrypt HTTP-01 challenge. |
| `HTTPS_PORT` | **For a real domain, set to `443`** (defaults to `8443`). |

### 3. Start the stack

```bash
docker compose -f docker-compose.dist.yml up -d
```

The first start takes a couple of minutes. Caddy will obtain a TLS
certificate, Postgres will initialise its data volume, and the backend
will run migrations before listening.

### 4. Capture the platform admin password

The first time the backend boots it generates a random `super_admin`
password, writes it to a file inside the data volume, and prints it to
the container logs. Capture it now — the file self-deletes after first
login, and there's no second chance to read the plaintext.

```bash
# Either way works:
docker compose -f docker-compose.dist.yml exec backend cat /data/INITIAL_ADMIN_PASSWORD.txt
# ...or scroll through the boot banner:
docker compose -f docker-compose.dist.yml logs backend | grep -A 6 "INITIAL SUPER_ADMIN"
```

The credentials are:
- **email:** `admin@tenderflow.com`
- **password:** the random value from above

Save it in a password manager. If you lose it before first login, you
can regenerate with:

```bash
docker compose -f docker-compose.dist.yml exec backend node scripts/reset-admin-password.js
```

### 5. Run the setup wizard

Open `https://YOUR-DOMAIN/setup` in a browser. You'll be guided through:

1. **Welcome** — overview (or click *Load demo data and skip wizard* for trial)
2. **License** — paste a key, or click *Use community edition* to skip
3. **Database** — confirms the bundled Postgres is reachable
4. **Master administrator** — creates your first business owner (this is YOUR account; the platform admin from step 4 is separate)
5. **Email (optional)** — wire up SMTP now or later
6. **Done** — finalises the install

After the wizard completes, you have two accounts:
- The business owner you just created (your main account; full org admin)
- The platform `super_admin` from the file (used rarely, mostly never)

---

## Local install (no HTTPS, for testing)

The default ports (`HTTP_PORT=8080`, `HTTPS_PORT=8443`) keep this safe to run
on a workstation that already has another web server. No root needed.

```bash
mkdir -p ~/tenderflow-local && cd ~/tenderflow-local
curl -O https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/docker-compose.dist.yml
cat > .env <<EOF
DOMAIN=:80
POSTGRES_PASSWORD=$(openssl rand -base64 24)
JWT_SECRET=$(openssl rand -base64 48)
EOF
docker compose -f docker-compose.dist.yml up -d
```

Browse to `http://localhost:8080/setup`.

---

## Changing the domain after install

Domain is set at install time and persisted in `.env` next to your
`docker-compose.dist.yml`. The setup wizard does NOT currently ask for
the domain — that's planned for a post-beta release. Until then, change
it manually:

```bash
cd ~/tenderflow                        # or wherever you ran install.sh

# 1. Edit .env — update the three domain-related values
#    DOMAIN=tenderflow.example.com           (was :80 for IP-only mode)
#    DOMAIN_URL=https://tenderflow.example.com
#    HTTP_PORT=80                            (was 8080 — needed for ACME)
#    HTTPS_PORT=443                          (was 8443)
nano .env

# 2. Make sure DNS for the new domain points at this server's public IP
#    and ports 80 + 443 are open inbound on the firewall.

# 3. Pick up the new config — only Caddy needs a restart for domain
#    changes; backend re-reads CORS_ORIGIN on next start too.
docker compose -f docker-compose.dist.yml up -d

# 4. Watch the cert fetch (Caddy talks to Let's Encrypt automatically).
docker compose -f docker-compose.dist.yml logs -f caddy
#    Look for: "certificate obtained successfully" — usually under 30s.
#    If it hangs, check that port 80 is reachable from the public
#    internet and that DNS has actually propagated.
```

**Common pitfalls:**

- `HTTP_PORT=8080` is the default to avoid clashes on a fresh host.
  Real domains require port 80 for the ACME HTTP-01 challenge — change
  to `80` AND open the firewall before restarting Caddy.
- Let's Encrypt rate-limits to 5 certs per registered domain per week.
  If you hammer the wrong domain repeatedly, you'll get blocked for a
  week — fix DNS first, then retry.
- Going from a real domain back to IP-only: set `DOMAIN=:80` and Caddy
  skips ACME automatically.

---

## Updating to a newer version

The exact same commands work for every upgrade. Your data lives in
Docker volumes (`tenderflow_pgdata`, `tenderflow_data`, `tenderflow_caddy_data`)
which are NOT touched when images are pulled.

```bash
cd ~/tenderflow
# Edit .env and bump APP_VERSION to the new release (e.g. 1.1.0)
docker compose -f docker-compose.dist.yml pull
docker compose -f docker-compose.dist.yml up -d
```

What happens on update:

1. New images are pulled from `ghcr.io/<your-org>/tenderflow-{backend,frontend}`
2. Containers are recreated with the new images, **same volumes**
3. Backend boots, runs `migrate.mjs` against the existing database
4. Postgres schema evolves; user data is preserved
5. App resumes serving — typically less than 30 seconds of downtime

**Safeguards built in:**

- Boot-time downgrade guard refuses to start if the image is older than
  the version recorded in your installation. You can't accidentally
  corrupt your DB by pulling a wrong tag.
- Optional `MIGRATE_BACKUP=true` in `.env` runs `pg_dump` before each
  migrate. The dump lands in `/tmp` inside the backend container — copy
  it to a host path with `docker cp` or pipe through.
- Migrations are advisory-locked; rolling deploys can't double-migrate.

---

## Rolling back a bad release

The downgrade guard means you can NOT just bump `APP_VERSION` backwards
once a migration has run. Plan rollbacks deliberately.

### Case A — bad release that did NOT run a migration

If the new release shipped only application code (no schema changes —
check the release notes), rollback is safe:

```bash
# Pin to the previous version
sed -i 's/^APP_VERSION=.*/APP_VERSION=1.0.0/' .env

docker compose -f docker-compose.dist.yml pull
docker compose -f docker-compose.dist.yml up -d
```

The boot guard checks against `installations.app_version` — if the
previous release left it at `1.0.0`, this works. If the new release
already wrote `1.1.0` to that column, you'll need Case B.

### Case B — bad release that DID run a migration

You must restore from the pre-migrate backup. This is why
`MIGRATE_BACKUP=true` matters in production.

```bash
# 1. Stop the stack
docker compose -f docker-compose.dist.yml down

# 2. Restore the dump that was taken before the bad migrate ran
gunzip -c tenderflow-pre-migrate-2026-05-01T12-00-00.sql.gz \
  | docker compose -f docker-compose.dist.yml run --rm postgres \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

# 3. Pin to the previous version and restart
sed -i 's/^APP_VERSION=.*/APP_VERSION=1.0.0/' .env
docker compose -f docker-compose.dist.yml up -d
```

### Always test rollbacks in staging first

Before running a `docker compose pull` against production, do it on a
staging install with a copy of your data. If staging breaks, you find
out before customers do.

---

## Backups

The recommended approach is **volume-level backup** of the `tenderflow_pgdata`
volume.

### Manual SQL dump

```bash
docker compose -f docker-compose.dist.yml exec -T postgres \
  pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
  | gzip > "tenderflow-$(date +%F).sql.gz"
```

Run this on a cron schedule and ship the dump off-host (S3, B2, Azure Blob).

### Restore

```bash
gunzip -c tenderflow-2026-05-01.sql.gz \
  | docker compose -f docker-compose.dist.yml exec -T postgres \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

### Sample backup cron

Drop this on the host running the compose stack:

```cron
# /etc/cron.d/tenderflow-backup
# Daily SQL dump at 03:15 local time. Keeps 30 days. Pushes to S3.
15 3 * * *  root  /opt/tenderflow/backup.sh >> /var/log/tenderflow-backup.log 2>&1
```

```bash
# /opt/tenderflow/backup.sh
#!/usr/bin/env bash
set -euo pipefail
cd /home/tenderflow
DATE=$(date +%F)
DUMP="tenderflow-${DATE}.sql.gz"

# 1. Take the dump
docker compose -f docker-compose.dist.yml exec -T postgres \
  pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" \
  | gzip > "/var/backups/tenderflow/${DUMP}"

# 2. Ship off-host (uses your already-installed AWS CLI / rclone)
aws s3 cp "/var/backups/tenderflow/${DUMP}" "s3://your-bucket/tenderflow/" \
  --storage-class STANDARD_IA

# 3. Keep last 30 local copies
find /var/backups/tenderflow/ -name 'tenderflow-*.sql.gz' -mtime +30 -delete
```

### Verify your backups quarterly

A backup that has never been tested is not a backup. Every 90 days,
restore the latest dump to a scratch DB and run a smoke test with the
verification script:

```bash
./tender-engine/scripts/verify-backup.sh /var/backups/tenderflow/tenderflow-LATEST.sql.gz
```

The script starts a throwaway `postgres:16-alpine` container, restores the
dump, verifies non-zero row counts for `users`, `tenders`, and `bid_rounds`,
then removes the container. It exits non-zero on corrupt dumps, restore
errors, port collisions, or missing tables.

Sample weekly verification of the most recent local dump:

```cron
# /etc/cron.d/tenderflow-backup-verify
30 4 * * 0  root  cd /home/tenderflow && ./tender-engine/scripts/verify-backup.sh "$(ls -1t /var/backups/tenderflow/tenderflow-*.sql.gz | head -n 1)" >> /var/log/tenderflow-backup-verify.log 2>&1
```

If the restore fails, fix your backup pipeline before you need it for real.

---

## Operations

### Health probes

| Endpoint | Purpose |
|---|---|
| `https://DOMAIN/api/livez` | Process is alive (no I/O) — for k8s/PM2 restart decisions |
| `https://DOMAIN/api/readyz` | Process is ready to receive traffic — hits DB |
| `https://DOMAIN/api/health` | Combined health snapshot |

### Logs

```bash
docker compose -f docker-compose.dist.yml logs -f --tail=100        # all
docker compose -f docker-compose.dist.yml logs -f --tail=100 backend
docker compose -f docker-compose.dist.yml logs -f --tail=100 caddy
```

Backend logs are structured JSON via pino. Auth tokens and cookies are
redacted automatically.

### Stopping cleanly

```bash
docker compose -f docker-compose.dist.yml down            # stop, keep volumes
docker compose -f docker-compose.dist.yml down -v         # stop, DELETE volumes (data loss!)
```

---

## Troubleshooting

**Wizard never appears, browser shows the login page.** Setup completed
on a previous run; the install is configured. To re-run setup, drop the
`installations` row in Postgres (advanced — only do this if you understand
the consequences).

**Backend logs `Refusing to start: image vX.Y.Z is older than recorded install vA.B.C`.**
You pulled an older image. Either bump `APP_VERSION` to a newer tag, or
restore from a backup taken before the upgrade.

**Caddy logs `unable to obtain certificate`.** Most common causes: DNS
not pointing at the server yet, port 80 blocked, or the domain has a
CAA record forbidding Let's Encrypt. Check `dig DOMAIN` and the firewall.

**Backend logs `SETUP_REQUIRED` for every API call.** Expected during
setup mode — finish the wizard at `/setup`. If you see this AFTER
completing the wizard, check that `installations.state = 'completed'`
in the DB.

---

## Architecture (what's running)

```
┌──────────────────────────────────────────────────┐
│ Customer browser                                 │
└────────────────────┬─────────────────────────────┘
                     │ HTTPS :443
                     ▼
            ┌────────────────┐
            │  caddy:2-alpine │  (auto Let's Encrypt)
            └────────┬────────┘
              ┌──────┴──────┐
              ▼             ▼
       ┌──────────┐  ┌────────────┐
       │ frontend │  │  backend   │  (Node, runs migrate.mjs on boot)
       │ (nginx)  │  │  Express 5 │
       └──────────┘  └─────┬──────┘
                           ▼
                  ┌──────────────────┐
                  │ postgres:16-alpine │
                  └──────────────────┘
```

Volumes (persistent across image updates):

- `tenderflow_pgdata` — Postgres data
- `tenderflow_data` — secrets, license, future uploads
- `tenderflow_caddy_data` — TLS certificates
- `tenderflow_caddy_config` — Caddy runtime state
