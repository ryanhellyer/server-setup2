#!/usr/bin/env bash
# =============================================================================
# deploy.sh — rebuild/redeploy the whole stack from this repo.
#
# On a fresh host:  git clone <repo> && cp .env.example .env
#                   sudo ./scripts/deploy.sh
#                   sudo ./scripts/certbot-issue.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "Missing .env — copy .env.example to .env and fill in secrets."
  exit 1
fi

# Prefer `podman compose`, fall back to `podman-compose`.
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
else
  COMPOSE=(podman-compose)
fi

echo "==> 1/6 git pull (skipped if this isn't a git clone with a remote)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git remote 2>/dev/null)" ]; then
  git pull --ff-only
else
  echo "  (not a git clone with a remote — deploying the local checkout)"
fi

# nginx -t validates ssl_certificate files exist, so bootstrap a self-signed
# cert BEFORE the first certbot run (certbot-issue.sh replaces it with a real
# Let's Encrypt cert).
CERT_DIR="env/letsencrypt/live/pressabl12.hellyer.kiwi"
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  echo "==> 2/6 no TLS cert yet — generating bootstrap self-signed cert"
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=pressabl12.hellyer.kiwi"
fi

echo "==> 3/6 build nginx image (used for config validation)"
IMAGE_ID="$(podman build -q ./nginx)"

echo "==> 4/6 nginx -t against the repo config"
podman run --rm -v "$PWD/nginx:/etc/nginx:ro" -v "$PWD/env/letsencrypt:/etc/letsencrypt:ro" "$IMAGE_ID" nginx -t

echo "==> 5/6 bring the stack up (build + start)"
"${COMPOSE[@]}" up -d --build

echo "==> 6/6 install systemd units so the stack starts at boot"
"$PWD/scripts/install-systemd.sh"

echo
echo "Deploy complete."