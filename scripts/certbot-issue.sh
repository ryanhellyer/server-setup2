#!/usr/bin/env bash
# =============================================================================
# certbot-issue.sh — issue or renew certificates using the http01 webroot
# challenge (port 80). Which domains are issued is driven by .env:
#   CERTBOT_DOMAINS_FILE=...   default certbot/domains.txt
#                              (test: certbot/domains.test.txt = only ionos)
#
# Usage:  sudo ./scripts/certbot-issue.sh [--force]
#   --force  force reissue even if a valid cert exists (rate-limit aware).
#
# nginx serves every vhost from /etc/letsencrypt/live/pressabl12.hellyer.kiwi/.
# If the cert actually issued here has a different name (e.g. ionos on the test
# server), that path is symlinked to it so nginx serves the real cert.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

WEBROOT="/var/www/acme"
LETSENCRYPT_DIR="$PWD/env/letsencrypt"
DOMAINS_FILE="${CERTBOT_DOMAINS_FILE:-certbot/domains.txt}"
EMAIL="${CERTBOT_EMAIL:-admin@hellyer.kiwi}"
NGINX_CERT_NAME="pressabl12.hellyer.kiwi"

[ -f "$DOMAINS_FILE" ] || { echo "Missing $DOMAINS_FILE"; exit 1; }
mkdir -p "$WEBROOT" "$LETSENCRYPT_DIR"

if command -v certbot >/dev/null 2>&1; then
  CERTBOT=(certbot)
else
  CERTBOT=(podman run --rm -v "$LETSENCRYPT_DIR:/etc/letsencrypt" -v "$WEBROOT:/var/www/acme" docker.io/certbot/certbot)
fi

EXTRA=()
[ "$FORCE" = "1" ] && EXTRA=(--force-renewal)

grep -v '^#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$' | while read -r line; do
  cert_name="$(echo "$line" | awk '{print $1}')"
  domains="$(echo "$line" | cut -d' ' -f2-)"
  args=()
  for d in $domains; do args+=(-d "$d"); done

  echo "==> Issuing/renewing $cert_name for: $domains"
  "${CERTBOT[@]}" certonly --webroot -w "$WEBROOT" \
      --cert-name "$cert_name" --expand "${EXTRA[@]}" \
      --email "$EMAIL" --agree-tos --no-eff-email "${args[@]}"
done

echo "==> Reloading nginx"
podman exec nginx nginx -s reload || true

# If the issued cert name differs from the path nginx references, point the
# nginx path at it (test server: ionos cert served for every vhost).
FIRST_CERT="$(grep -v '^#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$' | head -1 | awk '{print $1}' || true)"
if [ -n "$FIRST_CERT" ] && [ "$FIRST_CERT" != "$NGINX_CERT_NAME" ] && [ -d "$LETSENCRYPT_DIR/live/$FIRST_CERT" ]; then
  rm -rf "$LETSENCRYPT_DIR/live/$NGINX_CERT_NAME"
  ln -s "$FIRST_CERT" "$LETSENCRYPT_DIR/live/$NGINX_CERT_NAME"
  echo "Linked $NGINX_CERT_NAME -> $FIRST_CERT (nginx serves the real cert)."
fi

echo "Certificates up to date."