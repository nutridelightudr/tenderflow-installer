#!/usr/bin/env bash
#
# TenderFlow lazy installer for fresh VMs.
#
# Run on a clean Ubuntu/Debian/RHEL/Fedora server with internet access:
#
#   curl -fsSL https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/install.sh -o tenderflow-install.sh
#   bash tenderflow-install.sh
#
# This script and docker-compose.dist.yml live in the public mirror
# `nutridelightudr/tenderflow-installer`. The mirror is a read-only copy
# of the `installer/` directory in the private TenderFlow repo — edits
# should be made there.
#
# What it does:
#   1. Verifies Docker + Compose v2 are installed (offers to install Docker)
#   2. Creates ~/tenderflow/ working directory
#   3. Downloads docker-compose.dist.yml from the selected release ref
#   4. Asks for a domain (or skips for HTTP-only local mode on port 8080)
#   5. Generates random POSTGRES_PASSWORD + JWT_SECRET
#   6. Writes .env (chmod 600)
#   7. Pulls the multi-arch images from GHCR
#   8. Starts the stack
#   9. Captures the auto-generated bootstrap super_admin password from
#      the container's data volume and prints it
#  10. Prints the wizard URL
#
# Re-running on the same machine reuses the existing volumes (data is
# preserved). To start truly fresh, delete the install dir AND the
# Docker volumes (down -v) before re-running.

set -euo pipefail

# When run via `curl ... | bash`, bash reads the script itself from
# stdin (the curl pipe). Two things must work:
#   1. Interactive `read` prompts must come from the terminal, not the
#      pipe (which is empty / closed by the time we hit the prompt).
#   2. Bash must keep reading the rest of the script from the pipe —
#      replacing fd 0 with `exec </dev/tty` breaks this on scripts
#      larger than bash's internal read buffer (~4KB).
#
# Solution: keep fd 0 alone. Open /dev/tty as a separate fd (3), then
# redirect each `read` from fd 3 individually (see ASK helper below).
# This works for `curl | bash`, `bash <(curl …)`, `bash file.sh`,
# and CI / no-tty contexts (where the helper falls back to fd 0).
TF_TTY_FD=""
if [ ! -t 0 ] && (exec 3</dev/tty) >/dev/null 2>&1; then
  exec 3</dev/tty
  TF_TTY_FD=3
fi

# ASK <var> <prompt> [default]
# Reads a single line into <var>, prompting on stderr (so the prompt is
# always visible even if stdout is captured). Uses fd 3 (terminal) when
# available, otherwise stdin.
ASK() {
  local __var="$1" __prompt="$2" __default="${3:-}" __input=""
  if [ -n "$TF_TTY_FD" ]; then
    IFS= read -r -p "$__prompt" __input <&3
  else
    IFS= read -r -p "$__prompt" __input
  fi
  printf -v "$__var" '%s' "${__input:-$__default}"
}

# ── Display helpers ──────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

info()    { echo "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo "${GREEN}[OK]${NC}    $*"; }
warn()    { echo "${YELLOW}[WARN]${NC}  $*"; }
fatal()   { echo "${RED}[FATAL]${NC} $*" >&2; exit 1; }
section() { echo; echo "${BOLD}── $* ──${NC}"; }

# ── OS detection ─────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s 2>/dev/null)" in
    Darwin)
      echo >&2
      echo "${RED}[FATAL]${NC} macOS detected." >&2
      echo >&2
      echo "  TenderFlow runs as Docker containers on a Linux server." >&2
      echo "  On macOS, install Docker Desktop, then run the stack manually:" >&2
      echo "    curl -fsSL ${RAW_BASE:-https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main}/docker-compose.dist.yml -o docker-compose.dist.yml" >&2
      echo "    docker compose -f docker-compose.dist.yml up -d" >&2
      echo >&2
      echo "  For production, deploy to a Linux VPS (Ubuntu 22.04+ recommended)." >&2
      exit 1
      ;;
    Linux)
      ;;
    *)
      warn "Unrecognised OS: $(uname -s 2>/dev/null). Proceeding — Docker may or may not work."
      ;;
  esac
}

# ── Privilege escalation ──────────────────────────────────────────────────
SUDO=""
detect_sudo() {
  if [ "$(id -u)" = "0" ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  elif command -v doas >/dev/null 2>&1; then
    SUDO="doas"
  else
    fatal "Root privileges are required. Install sudo or doas, or re-run as root."
  fi
}

# ── Fetch helper (curl → wget fallback) ───────────────────────────────────
# FETCH is used for pipe operations: $FETCH URL | sh
# download() is used for saving to a file: download URL dest
FETCH=""
detect_fetch() {
  if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
  elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -q -O-"
  else
    fatal "curl or wget is required. Install one via your package manager and re-run."
  fi
}

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -q -O "$dest" "$url"
  fi
}

fetch_ip() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true
  else
    wget -q --timeout=3 -O- https://api.ipify.org 2>/dev/null || true
  fi
}

# ── Connectivity check ────────────────────────────────────────────────────
check_connectivity() {
  info "Checking internet connectivity (GitHub + GHCR)..."
  local test_url="https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/main/README.md"
  local out rc=0
  out=$($FETCH "$test_url" 2>&1) || rc=$?
  if [ "$rc" != "0" ]; then
    echo
    echo "  Test URL : $test_url" >&2
    echo "  Output   : $out"      >&2
    fatal "Cannot reach GitHub/GHCR. Ensure this server has outbound internet access on port 443, then re-run."
  fi
  ok "Internet reachable"
}

# ── Configuration (env-overridable) ──────────────────────────────────────
# Use main by default so the one-line installer always receives the latest
# distribution compose fixes. Pin with TF_VERSION=v1.0.0 when installing a
# frozen release.
TF_VERSION="${TF_VERSION:-main}"
APP_VERSION="${APP_VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/tenderflow}"
COMPOSE_FILE="docker-compose.dist.yml"
RAW_BASE="https://raw.githubusercontent.com/nutridelightudr/tenderflow-installer/${TF_VERSION}"
COMPOSE_URL="${RAW_BASE}/${COMPOSE_FILE}"

DC() { docker compose -f "$COMPOSE_FILE" "$@"; }

# ── Pre-flight ───────────────────────────────────────────────────────────
ensure_tools() {
  command -v openssl >/dev/null 2>&1 || fatal "openssl is required (install via your package manager)"

  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is not installed."
    ASK yn "Install Docker via the official get.docker.com script? [Y/n] " "Y"
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      $FETCH https://get.docker.com | sh
      if id -nG "$USER" 2>/dev/null | grep -qvw docker; then
        $SUDO usermod -aG docker "$USER" || true
        warn "Added $USER to the docker group. You must log out and back in, then re-run this script."
        exit 0
      fi
    else
      fatal "Docker is required."
    fi
  fi

  if ! docker compose version >/dev/null 2>&1; then
    warn "Docker is installed but Docker Compose v2 is missing (old Docker version)."
    ASK yn "Upgrade Docker via the official get.docker.com script? [Y/n] " "Y"
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      $FETCH https://get.docker.com | sh
      if ! docker compose version >/dev/null 2>&1; then
        fatal "Docker Compose v2 still not available after upgrade. Try: apt-get install docker-compose-plugin"
      fi
    else
      fatal "Docker Compose v2 is required. Run: curl -fsSL https://get.docker.com | sh"
    fi
  fi

  # Verify the daemon is actually reachable (version check doesn't need it)
  if ! docker info >/dev/null 2>&1; then
    warn "Docker daemon is not running."
    info "Starting Docker service..."
    $SUDO systemctl start docker 2>/dev/null || $SUDO service docker start 2>/dev/null || true
    $SUDO systemctl enable docker 2>/dev/null || true
    if ! docker info >/dev/null 2>&1; then
      fatal "Docker daemon could not be started. Run: sudo systemctl start docker"
    fi
  fi

  ok "Docker $(docker --version | awk '{print $3}' | tr -d ',') and Compose $(docker compose version --short) ready"
}

# ── Working directory ────────────────────────────────────────────────────
prepare_dir() {
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  ok "Working in $INSTALL_DIR"
}

fetch_compose() {
  info "Fetching $COMPOSE_FILE from $TF_VERSION..."
  download "$COMPOSE_URL" "$COMPOSE_FILE"
  ok "Downloaded $COMPOSE_FILE"
}

# ── Env generation ───────────────────────────────────────────────────────
gen_password() {
  openssl rand -base64 32 | tr -d '\n/+=' | cut -c1-32
}

write_env() {
  if [[ -f .env ]]; then
    info "Existing .env found — keeping secrets, domain, and ports unchanged"
    # Force APP_VERSION back to the requested version (default: latest) so
    # re-running install.sh actually updates the customer's stack. Without
    # this, an .env pinned to an older version would silently stay pinned
    # and `docker compose pull` would never fetch a newer image.
    if grep -q '^APP_VERSION=' .env; then
      local current_ver
      current_ver=$(grep '^APP_VERSION=' .env | cut -d= -f2-)
      if [[ "$current_ver" != "$APP_VERSION" ]]; then
        info "Updating APP_VERSION: $current_ver → $APP_VERSION (re-run = update to latest)"
        sed -i.bak "s|^APP_VERSION=.*|APP_VERSION=${APP_VERSION}|" .env && rm -f .env.bak
      fi
    else
      echo "APP_VERSION=${APP_VERSION}" >> .env
    fi
    return
  fi

  # Fresh .env means we're generating new POSTGRES_PASSWORD/JWT_SECRET. Any
  # leftover postgres volume from a previous failed install holds the OLD
  # password baked into its data directory — postgres only sets the password
  # on first init, so the new password in .env will fail auth. Wipe stale
  # volumes so the data dir re-initializes cleanly.
  local stale_vols
  stale_vols=$(docker volume ls -q --filter name='^tenderflow_' 2>/dev/null || true)
  if [[ -n "$stale_vols" ]]; then
    warn "Found leftover volumes from a previous install — removing for a clean start:"
    echo "$stale_vols" | sed 's/^/  /'
    docker volume rm $stale_vols >/dev/null 2>&1 || true
  fi

  # Always install with local defaults first. Domain is configured optionally
  # at the end of the install, after we know the stack is healthy on IP.
  local domain=":80"
  local acme_email="admin@example.com"
  local http_port=80
  local https_port=443
  local domain_http_fallback=":9090"
  local domain_url ip
  ip=$(fetch_ip)
  if [[ -n "$ip" ]]; then
    domain_url="http://${ip}"
  else
    domain_url="http://localhost"
  fi

  local pg_pw jwt_secret
  pg_pw="$(gen_password)"
  jwt_secret="$(openssl rand -base64 48 | tr -d '\n')"

  cat > .env <<EOF
# Generated by TenderFlow install.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Keep this file private — it contains secrets.

DOMAIN=${domain}
DOMAIN_URL=${domain_url}
DOMAIN_HTTP_FALLBACK=${domain_http_fallback}
ACME_EMAIL=${acme_email}
HTTP_PORT=${http_port}
HTTPS_PORT=${https_port}

POSTGRES_USER=tenderflow_user
POSTGRES_PASSWORD=${pg_pw}
POSTGRES_DB=tenderflow

JWT_SECRET=${jwt_secret}

APP_VERSION=${APP_VERSION}
IMAGE_OWNER=nutridelightudr

MIGRATE_BACKUP=false
SENTRY_DSN=
SENTRY_ENVIRONMENT=production
EOF
  chmod 600 .env
  ok "Wrote .env (chmod 600)"
}

# ── Stack lifecycle ──────────────────────────────────────────────────────
pull_images() {
  info "Pulling multi-arch images from GHCR (~200MB total, may take 1-5 min on first run)..."
  info "Images: postgres:16-alpine, caddy:2-alpine, tenderflow-backend:latest, tenderflow-frontend:latest"
  # --progress=plain forces one-line-per-update output, which works
  # reliably in curl|bash flow where TTY auto-detection can buffer.
  # Note: --progress is a GLOBAL flag on `docker compose`, not on `pull`.
  docker compose -f "$COMPOSE_FILE" --progress=plain pull
  ok "Images pulled"
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    sudo -n ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && return 0
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$port\$" && return 0
  fi
  return 1
}

start_stack() {
  local http_port https_port behind_proxy="false"
  http_port=$(grep '^HTTP_PORT=' .env | cut -d= -f2-)
  https_port=$(grep '^HTTPS_PORT=' .env | cut -d= -f2-)
  http_port="${http_port:-80}"
  https_port="${https_port:-443}"

  # If port 80/443 is already taken, fall back to high ports automatically
  # so the install doesn't fail. The user can wire their existing reverse
  # proxy (nginx/apache/etc) to forward to those ports.
  if port_in_use "$http_port" || port_in_use "$https_port"; then
    warn "Port $http_port or $https_port is already in use on this host."
    echo "  Falling back to high ports so TenderFlow can run alongside" >&2
    echo "  your existing web server. Wire your reverse proxy to forward" >&2
    echo "  HTTP traffic to port 8080 on this host." >&2
    http_port=8080
    https_port=8443
    behind_proxy="true"
    # Persist BEHIND_PROXY=true so future installer runs (and offer_domain_setup)
    # know not to enable Caddy's auto-HTTPS — the existing reverse proxy handles SSL.
    sed -i.bak \
      -e "s|^HTTP_PORT=.*|HTTP_PORT=${http_port}|" \
      -e "s|^HTTPS_PORT=.*|HTTPS_PORT=${https_port}|" \
      -e "s|^DOMAIN_URL=http://[^:/]*\$|DOMAIN_URL=http://localhost:${http_port}|" \
      .env
    grep -q '^BEHIND_PROXY=' .env || echo "BEHIND_PROXY=true" >> .env
    rm -f .env.bak
  fi

  info "Starting containers..."
  # --remove-orphans cleans up containers from a prior compose config that
  # are no longer in this one. Critical for re-runs after compose-file changes.
  DC up -d --remove-orphans
  ok "Containers started — running migrations and bootstrap inside backend now"
  echo
  DC ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || DC ps
  echo

  if [[ "$behind_proxy" == "true" ]]; then
    echo "${YELLOW}TenderFlow is running on http://localhost:${http_port}${NC}"
    echo "To expose it via your existing reverse proxy, add a server block like:"
    echo
    echo "  ${BOLD}# nginx example:${NC}"
    echo "  server {"
    echo "    listen 80;"
    echo "    server_name your-domain.example.com;"
    echo "    location / {"
    echo "      proxy_pass http://127.0.0.1:${http_port};"
    echo "      proxy_set_header Host \$host;"
    echo "      proxy_set_header X-Real-IP \$remote_addr;"
    echo "      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    echo "      proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "    }"
    echo "  }"
    echo
  fi
}

recover_from_pg_auth_mismatch() {
  warn "Detected: postgres data volume holds a password that doesn't match .env"
  echo "  This happens when an earlier install initialized the volume with one" >&2
  echo "  password, then .env was regenerated with a different one." >&2
  echo "  Recovering by wiping ONLY the postgres data volume (everything else" >&2
  echo "  stays). Other Docker projects on this host are untouched." >&2
  echo
  DC stop postgres backend >/dev/null 2>&1 || true
  DC rm -f postgres backend >/dev/null 2>&1 || true
  docker volume rm tenderflow_pgdata >/dev/null 2>&1 || true
  info "Restarting stack with fresh postgres data..."
  DC up -d
}

wait_for_backend() {
  info "Waiting for backend to pass health probe (this includes db migration + admin bootstrap; up to 2 min)..."
  local started ready_at attempt recovered="false"
  started=$(date +%s)
  for attempt in $(seq 1 60); do
    if DC exec -T backend wget --quiet --tries=1 --spider http://127.0.0.1:4000/api/livez 2>/dev/null; then
      ready_at=$(date +%s)
      ok "Backend healthy (took $((ready_at - started))s)"
      return
    fi
    # Detect postgres auth mismatch early and auto-recover (only once)
    if [[ "$recovered" == "false" ]] && (( attempt >= 3 )); then
      if DC logs --tail=30 backend 2>&1 | grep -q "password authentication failed"; then
        recover_from_pg_auth_mismatch
        recovered="true"
        started=$(date +%s)  # reset timer after recovery
      fi
    fi
    if (( attempt % 5 == 0 )); then
      local elapsed=$(( $(date +%s) - started ))
      info "  ... still waiting (${elapsed}s elapsed) — last container status:"
      DC ps --format "    {{.Service}}: {{.Status}}" 2>/dev/null | head -4
    fi
    sleep 2
  done
  warn "Backend didn't become healthy in 2 minutes — dumping logs:"
  echo
  echo "── postgres logs (last 20) ──"
  DC logs --tail=20 postgres 2>&1 | sed 's/^/  /'
  echo
  echo "── backend logs (last 60) ──"
  DC logs --tail=60 backend 2>&1 | sed 's/^/  /'
  echo
  fatal "Backend health probe failed. Run 'docker compose -f $COMPOSE_FILE logs backend' to investigate."
}

# Verifies the FULL stack — Caddy serves the SPA AND proxies /api correctly.
# This catches frontend container failures the backend probe alone misses
# (e.g. broken nginx image leaving Caddy with no upstream → 502 for SPA).
wait_for_frontend() {
  local http_port
  http_port=$(grep '^HTTP_PORT=' .env | cut -d= -f2-)
  http_port="${http_port:-80}"

  info "Waiting for frontend (Caddy → SPA) on http://localhost:${http_port}..."
  local attempt
  for attempt in $(seq 1 30); do
    local code
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${http_port}/" 2>/dev/null || echo "000")
    if [[ "$code" == "200" ]]; then
      ok "Frontend healthy (HTTP $code)"
      return
    fi
    if (( attempt % 5 == 0 )); then
      info "  ... still waiting (got HTTP $code on attempt $attempt/30)"
    fi
    sleep 2
  done

  warn "Frontend (SPA) didn't respond with HTTP 200 in 60s — dumping diagnostics:"
  echo
  echo "── container status ──"
  DC ps --format "table {{.Service}}\t{{.Status}}\t{{.Ports}}" 2>&1 | sed 's/^/  /'
  echo
  echo "── frontend logs (last 40) ──"
  DC logs --tail=40 frontend 2>&1 | sed 's/^/  /'
  echo
  echo "── caddy logs (last 30) ──"
  DC logs --tail=30 caddy 2>&1 | sed 's/^/  /'
  echo
  echo "── direct probe of frontend container (bypassing Caddy) ──"
  DC exec -T frontend wget -qO- --timeout=3 http://127.0.0.1/ 2>&1 | head -5 | sed 's/^/  /' \
    || echo "  (frontend container not responding on :80 — image is the issue)"
  echo
  fatal "Frontend probe failed. Backend is healthy but the SPA isn't being served. \
Likely a broken frontend image. Try: docker compose -f $COMPOSE_FILE pull frontend && \
docker compose -f $COMPOSE_FILE up -d --force-recreate frontend"
}

# ── Optional domain setup (post-install, after stack is healthy) ─────────
offer_domain_setup() {
  local behind_proxy
  behind_proxy=$(grep '^BEHIND_PROXY=' .env 2>/dev/null | cut -d= -f2-)
  local http_port
  http_port=$(grep '^HTTP_PORT=' .env | cut -d= -f2-)

  # When TenderFlow is behind an existing reverse proxy (nginx/apache/etc),
  # we must NOT enable Caddy's auto-HTTPS — Caddy would force a 308 redirect
  # to https://domain even though the host proxy is doing SSL termination,
  # creating an infinite loop. The host proxy + certbot handle the domain.
  if [[ "$behind_proxy" == "true" ]]; then
    section "Domain setup with your existing reverse proxy"
    echo "TenderFlow is running behind your host's web server on http://localhost:${http_port}."
    echo
    echo "To expose it on a domain with HTTPS, do this on the host (NOT here):"
    echo
    echo "  ${BOLD}1) Add an nginx server block:${NC}"
    echo "     ${BOLD}/etc/nginx/sites-available/tenderflow${NC}"
    echo
    cat <<NGX
     server {
         listen 80;
         server_name your-domain.example.com;
         location / {
             proxy_pass http://127.0.0.1:${http_port};
             proxy_http_version 1.1;
             proxy_set_header Host \$host;
             proxy_set_header X-Real-IP \$remote_addr;
             proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
             proxy_set_header X-Forwarded-Proto \$scheme;
             proxy_set_header Upgrade \$http_upgrade;
             proxy_set_header Connection "upgrade";
             proxy_buffering off;
             proxy_read_timeout 3600s;
         }
     }
NGX
    echo
    echo "  ${BOLD}2) Enable + reload:${NC}"
    echo "     sudo ln -sf /etc/nginx/sites-available/tenderflow /etc/nginx/sites-enabled/"
    echo "     sudo nginx -t && sudo systemctl reload nginx"
    echo
    echo "  ${BOLD}3) Get a Let's Encrypt cert (HTTP-01 challenge needs DNS pointed here):${NC}"
    echo "     sudo certbot --nginx -d your-domain.example.com"
    echo
    echo "  ${BOLD}4) If using Cloudflare:${NC} set SSL/TLS mode to ${BOLD}Full (Strict)${NC},"
    echo "     not Flexible — Flexible causes a redirect loop."
    echo
    echo "${YELLOW}Don't add the domain to TenderFlow's .env${NC} — Caddy must stay in plain"
    echo "HTTP mode (DOMAIN=:80) so it doesn't fight your host proxy for SSL."
    return
  fi

  # Standalone install — Caddy IS the entry point, so configure its DOMAIN.
  section "Optional: Add a domain"
  echo "TenderFlow is running on this server's IP. You can use it as-is."
  echo
  echo "If you have a domain pointed at this server, add it now to enable"
  echo "automatic HTTPS via Let's Encrypt. The IP access will keep working."
  echo "Skip this step if you don't have a domain yet — you can run the"
  echo "installer again later to add one."
  echo

  local domain acme_email
  ASK domain "Domain (e.g. tenderflow.example.com) or press Enter to skip: " ""
  if [[ -z "$domain" ]]; then
    return
  fi

  ASK acme_email "Email for Let's Encrypt expiry warnings [admin@$domain]: " "admin@$domain"

  sed -i.bak \
    -e "s|^DOMAIN=.*|DOMAIN=${domain}|" \
    -e "s|^DOMAIN_URL=.*|DOMAIN_URL=https://${domain}|" \
    -e "s|^DOMAIN_HTTP_FALLBACK=.*|DOMAIN_HTTP_FALLBACK=:80|" \
    -e "s|^ACME_EMAIL=.*|ACME_EMAIL=${acme_email}|" \
    .env
  rm -f .env.bak

  info "Restarting Caddy with new domain config..."
  DC up -d --force-recreate caddy >/dev/null 2>&1
  ok "Domain configured: https://${domain}"
  echo "  IP access (http://server-ip) keeps working as a fallback."
  echo "  HTTPS will activate once DNS for ${domain} resolves to this server."
}

# ── Capture & print bootstrap admin credential ───────────────────────────
print_summary() {
  info "Capturing bootstrap admin credential..."
  # Wait briefly for the credential file to exist (bootstrap runs after migrations)
  for i in $(seq 1 15); do
    if DC exec -T backend test -f /data/INITIAL_ADMIN_PASSWORD.txt 2>/dev/null; then
      break
    fi
    sleep 1
  done

  local domain_url
  domain_url=$(grep '^DOMAIN_URL=' .env | cut -d= -f2-)

  echo
  echo "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
  echo "${GREEN}${BOLD}  TenderFlow is running.${NC}"
  echo "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${NC}"
  echo
  echo "  ${BOLD}First-run wizard:${NC} ${domain_url}/setup"
  echo "  ${BOLD}After wizard:${NC}    ${domain_url}/login"
  echo
  echo "${YELLOW}${BOLD}── Initial platform admin (capture NOW) ──${NC}"
  echo
  if DC exec -T backend cat /data/INITIAL_ADMIN_PASSWORD.txt 2>/dev/null | sed 's/^/  /'; then
    echo
    echo "${YELLOW}  This file deletes itself after the first successful login.${NC}"
    echo "${YELLOW}  Save the password in your password manager NOW.${NC}"
  else
    warn "Could not read /data/INITIAL_ADMIN_PASSWORD.txt — try:"
    echo "    docker compose -f $INSTALL_DIR/$COMPOSE_FILE logs backend | grep -A 6 'INITIAL SUPER_ADMIN'"
  fi
  echo

  echo "${BOLD}Useful commands:${NC}"
  echo "  cd $INSTALL_DIR"
  echo "  docker compose -f $COMPOSE_FILE logs -f backend     # tail logs"
  echo "  docker compose -f $COMPOSE_FILE ps                  # container status"
  echo "  docker compose -f $COMPOSE_FILE pull && up -d       # update to latest"
  echo "  docker compose -f $COMPOSE_FILE down                # stop (keep data)"
  echo "  docker compose -f $COMPOSE_FILE down -v             # stop + WIPE all data"
  echo
}

# ── Main ─────────────────────────────────────────────────────────────────
main() {
  section "TenderFlow installer (${TF_VERSION})"
  detect_os
  detect_sudo
  detect_fetch
  check_connectivity
  ensure_tools
  prepare_dir
  fetch_compose
  write_env
  pull_images
  start_stack
  wait_for_backend
  wait_for_frontend
  offer_domain_setup
  print_summary
}

main "$@"
