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
#   4. Renders nginx.conf from the template (.env-driven values).
#   5. Bootstraps a self-signed cert so nginx boots before certbot runs.
#   6. Creates log dirs the config references.
#   7. TEST MODE ONLY (DEPLOY_ENV=test): seeds placeholder sites and generates
#      a temporary self-signed cert covering every domain — skipped entirely
#      in production, so nothing needs removing for prod.
#   8. Builds the nginx image and runs nginx -t against the repo config.
#   9. podman compose up -d --build.
#   10. Installs systemd units so the stack starts at boot.
#
# After first deploy: sudo ./scripts/test-site.sh, sudo ./scripts/certbot-issue.sh,
# then point DNS at this host.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./deploy.sh)."; exit 1; }

# ---- 1. host packages (podman etc.) ----
if ! command -v podman >/dev/null 2>&1 || ! command -v podman-compose >/dev/null 2>&1 \
   || ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  echo "==> podman/podman-compose/curl/tar not all present — installing host packages first"
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
# shellcheck disable=SC1091
set -a && . ./.env && set +a
DEPLOY_ENV="${DEPLOY_ENV:-test}"
echo "==> Deployment mode: $DEPLOY_ENV"

# ---- 3. refresh files ----
# Tarball install (.tarball marker) -> re-download. Git clone -> git pull.
# Plain copied checkout -> deploy as-is.
echo "==> refresh files (tarball re-download, or git pull for git installs)"
if [ -f .tarball ]; then
  TARBALL_URL="$(cat .tarball)"
  echo "  (tarball install — downloading the latest files from GitHub)"
  # Resolve the live branch SHA first: SHA tarballs are immutable, so a
  # CDN-cached stale branch tarball is never used.
  if [[ "$TARBALL_URL" =~ ^https://github.com/([^/]+)/([^/]+)/archive/refs/heads/([^/]+)\.tar\.gz$ ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; branch="${BASH_REMATCH[3]}"
    sha="$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" 2>/dev/null \
      | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)"
    if [ -n "$sha" ]; then
      echo "  (resolved $branch @ ${sha:0:7})"
      TARBALL_URL="https://github.com/$owner/$repo/archive/$sha.tar.gz"
    fi
  fi
  curl -fsSL "$TARBALL_URL" -o /tmp/server-setup.tar.gz
  tar -xzf /tmp/server-setup.tar.gz --strip-components=1 -C "$PWD"
  rm -f /tmp/server-setup.tar.gz
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git remote 2>/dev/null)" ]; then
  git pull --ff-only
else
  echo "  (local checkout — deploying what's here)"
fi

# Prefer `podman compose`, fall back to `podman-compose`.
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
else
  COMPOSE=(podman-compose)
fi

# ---- 4. render nginx.conf from the template (.env-driven values) ----
"$PWD/scripts/render-config.sh"

# ---- 5. bootstrap TLS cert (nginx -t needs ssl files to exist) ----
CERT_DIR="env/letsencrypt/live/pressabl12.hellyer.kiwi"
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  echo "==> no TLS cert yet — generating bootstrap self-signed cert"
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=pressabl12.hellyer.kiwi"
fi

# ---- 6. create log dirs referenced by the nginx config ----
# nginx -t fails if a static access_log/error_log path's parent dir is missing,
# so create every log directory the config references (works on a fresh box
# before the sites have been migrated in).
echo "==> creating log directories referenced by the nginx config"
LOG_DIRS="$( { grep -rhoE '^\s*(access_log|error_log) [^;]+;' nginx/nginx.conf nginx/conf.d nginx/snippets 2>/dev/null; } \
  | sed -E 's/^\s*(access_log|error_log) +([^ ]+).*/\2/' \
  | grep '^/' | xargs -r -n1 dirname | sort -u )"
if [ -n "$LOG_DIRS" ]; then
  # shellcheck disable=SC2086
  mkdir -p $LOG_DIRS
fi

# ---- 7. TEST MODE: fake sites + temporary certs ----
# Nothing here runs in production — set DEPLOY_ENV=production in .env and
# these steps are skipped automatically (no manual code removal needed).
if [ "$DEPLOY_ENV" = "test" ]; then
  # Temporary placeholder pages in every empty web root, so any configured
  # domain resolves instead of 404ing. Never overwrites existing content.
  "$PWD/scripts/seed-test-sites.sh"

  # Temporary self-signed cert whose SANs cover every vhost domain, so each
  # test site has a matching certificate. certbot replaces this in production.
  "$PWD/scripts/gen-test-certs.sh"
fi

# ---- 8. build + test nginx config ----
echo "==> build nginx image (used for config validation)"
IMAGE_ID="$(podman build -q ./nginx)"

echo "==> nginx -t against the repo config"
podman run --rm \
  -v "$PWD/nginx:/etc/nginx:ro" \
  -v "$PWD/env/letsencrypt:/etc/letsencrypt:ro" \
  -v /var/www:/var/www \
  "$IMAGE_ID" nginx -t

# ---- 9. compose up ----
echo "==> bring the stack up (build + start)"
"${COMPOSE[@]}" up -d --build

# ---- 10. systemd units ----
echo "==> install systemd units so the stack starts at boot"
"$PWD/scripts/install-systemd.sh"

echo
echo "Deploy complete."
echo "Next: sudo ./scripts/test-site.sh   (scaffold the ionos test page)"
echo "      sudo ./scripts/certbot-issue.sh (real TLS for ionos.hellyer.kiwi)"