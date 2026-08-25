#!/usr/bin/env bash
# =============================================================================
# deploy.sh — MAIN entry point (kept in the repo root so it's easy to find).
#
# One command to bring the whole stack up on a fresh host:
#   sudo ./deploy.sh
#
# It does, in order:
#   1. Ensures the host has podman/podman-compose/git/etc. (installs them
#      automatically if they're missing — see scripts/host-setup.sh).
#   2. Creates .env from .env.example if missing, then opens it in nano for
#      you to fill in the secrets (save & exit to continue).
#   3. git pull (or re-download the files for a tarball install).
#   4. Bootstraps a self-signed cert so nginx boots before certbot runs.
#   5. Builds the nginx image and runs nginx -t against the repo config.
#   6. podman compose up -d --build.
#   7. Installs systemd units so the stack starts at boot.
#
# After first deploy: sudo ./scripts/test-site.sh, sudo ./scripts/certbot-issue.sh,
# then point DNS at this host.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./deploy.sh)."; exit 1; }

# ---- 1. host packages (podman etc.) ----
if ! command -v podman >/dev/null 2>&1 || ! command -v podman-compose >/dev/null 2>&1; then
  echo "==> podman/podman-compose not found — installing host packages first"
  bash scripts/host-setup.sh
else
  mkdir -p /var/www /var/databases /var/cache/nginx /var/log/nginx
fi

# ---- 2. .env (create + open for editing) ----
if [ ! -f .env ]; then
  cp .env.example .env
  echo "==> Created .env from .env.example"
  echo "==> Opening it in ${EDITOR:-nano} — fill in the secrets, then save & exit."
  "${EDITOR:-nano}" .env
fi

# ---- 3. refresh files ----
# Git clone -> git pull. install.sh tarball -> re-download the tarball.
# Plain copied checkout -> deploy as-is.
echo "==> refresh files (git pull, or tarball refresh for install.sh installs)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git remote 2>/dev/null)" ]; then
  git pull --ff-only
elif [ -f .tarball ]; then
  TARBALL_URL="$(cat .tarball)"
  echo "  (tarball install — downloading the latest files from GitHub)"
  curl -fsSL "$TARBALL_URL" -o /tmp/server-setup.tar.gz
  tar -xzf /tmp/server-setup.tar.gz --strip-components=1 -C "$PWD"
  rm -f /tmp/server-setup.tar.gz
else
  echo "  (local checkout — deploying what's here)"
fi

# Prefer `podman compose`, fall back to `podman-compose`.
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
else
  COMPOSE=(podman-compose)
fi

# ---- 4. bootstrap TLS cert (nginx -t needs ssl files to exist) ----
CERT_DIR="env/letsencrypt/live/pressabl12.hellyer.kiwi"
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  echo "==> no TLS cert yet — generating bootstrap self-signed cert"
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=pressabl12.hellyer.kiwi"
fi

# ---- 5. build + test nginx config ----
echo "==> build nginx image (used for config validation)"
IMAGE_ID="$(podman build -q ./nginx)"

echo "==> nginx -t against the repo config"
podman run --rm -v "$PWD/nginx:/etc/nginx:ro" -v "$PWD/env/letsencrypt:/etc/letsencrypt:ro" "$IMAGE_ID" nginx -t

# ---- 6. compose up ----
echo "==> bring the stack up (build + start)"
"${COMPOSE[@]}" up -d --build

# ---- 7. systemd units ----
echo "==> install systemd units so the stack starts at boot"
"$PWD/scripts/install-systemd.sh"

echo
echo "Deploy complete."
echo "Next: sudo ./scripts/test-site.sh   (scaffold the ionos test page)"
echo "      sudo ./scripts/certbot-issue.sh (real TLS for ionos.hellyer.kiwi)"