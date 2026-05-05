# TenderFlow installer

Bootstrap files for self-hosting **TenderFlow** — a multi-tenant blind reverse
auction procurement SaaS — on your own server via Docker.

> This repo is a **read-only public mirror** of the `installer/` directory
> in the private TenderFlow source repository. The product itself lives at
> the GHCR container registry; this repo only contains the files needed to
> bootstrap a fresh install.

---

## Quick start (fresh Linux VM, ~2 minutes)

```bash
curl -fsSL https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/install.sh \
  -o tenderflow-install.sh
bash tenderflow-install.sh
```

The installer will:

1. Verify Docker and Compose v2 are installed (offer to install Docker if missing)
2. Ask whether you want a public hostname with automatic HTTPS, or local HTTP-only mode
3. Generate random Postgres and JWT secrets, write a `.env` file (chmod 600)
4. Pull the latest images from `ghcr.io/nutridelightudr/tenderflow-{backend,frontend}`
5. Start the stack and print the **first-run wizard URL** plus the auto-generated
   platform-admin password

Once the stack is running, browse to the printed URL and complete the
six-step setup wizard (license → database → master account → SMTP → done).

---

## Manual start (alternative)

If you'd rather not run a script, the same flow by hand:

```bash
mkdir tenderflow && cd tenderflow

curl -O https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/docker-compose.dist.yml
curl -O https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/.env.dist.example

cp .env.dist.example .env
# edit .env: set DOMAIN, POSTGRES_PASSWORD (32+ chars), JWT_SECRET (32+ chars), ACME_EMAIL

docker compose -f docker-compose.dist.yml up -d
docker compose -f docker-compose.dist.yml exec backend cat /data/INITIAL_ADMIN_PASSWORD.txt
```

The bootstrap admin password file deletes itself after first successful login —
**capture it before logging in**.

See [INSTALL.md](INSTALL.md) for the full operator runbook (backups,
migrations, troubleshooting, rollback).

---

## Files in this repo

| File | Purpose |
|---|---|
| `install.sh` | One-command installer (interactive prompts) |
| `docker-compose.dist.yml` | Compose stack: Postgres + backend + frontend + Caddy reverse proxy |
| `.env.dist.example` | Template for environment configuration |
| `INSTALL.md` | Full operator runbook |

## Updates

```bash
cd ~/tenderflow
docker compose -f docker-compose.dist.yml pull
docker compose -f docker-compose.dist.yml up -d
```

Migrations run automatically on backend boot. Pin a specific version by
setting `APP_VERSION=1.0.0` in `.env`.

---

## Support

Issues and questions: file at the
[private TenderFlow repository](https://github.com/nutridelightudr/TenderFlow/issues)
(if you have access) or contact your TenderFlow administrator.
