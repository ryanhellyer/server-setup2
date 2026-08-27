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
source scripts/lib-containers.sh
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

# ---- DNS pre-check (clear message instead of a cryptic Let's Encrypt failure) ----
# LE must reach this host on port 80 to validate. If a domain doesn't resolve,
# fail fast. An IP mismatch is only a warning (the egress IP reported by
# ifconfig.me can differ from the DNS-visible IP behind NAT) — certbot is the
# real judge, and its error (if any) is shown below.
ALL_DOMAINS="$(grep -v '^#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$' | cut -d' ' -f2-)"
PUBLIC_IP="$(curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null \
  || curl -fsSL --max-time 10 https://icanhazip.com 2>/dev/null || true)"

if [ -n "$ALL_DOMAINS" ]; then
  unresolved=0
  for d in $ALL_DOMAINS; do
    ip="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    if [ -z "$ip" ]; then
      echo "  !! $d does not resolve yet"
      unresolved=1
    elif [ -n "$PUBLIC_IP" ] && [ "$ip" != "$PUBLIC_IP" ]; then
      echo "  !! warning: $d resolves to $ip; this host reports public IP $PUBLIC_IP"
    fi
  done
  if [ "$unresolved" = "1" ]; then
    echo
    echo "DNS is not pointed at this host yet. Point the domain(s) above at your"
    echo "server's public IP, wait for propagation, then re-run:"
    echo "  sudo bash scripts/certbot-issue.sh    (or: sudo ./setup.sh)"
    exit 1
  fi
fi

# Issue each cert. certbot exits non-zero when nothing needed doing (e.g.
# "Certificate not yet due for renewal"), which must NOT abort the script —
# the nginx reload + symlink steps below have to run regardless so the real
# cert is served. Capture and report the status, then carry on.
while read -r line; do
  cert_name="$(echo "$line" | awk '{print $1}')"
  domains="$(echo "$line" | cut -d' ' -f2-)"
  args=()
  for d in $domains; do args+=(-d "$d"); done

  echo "==> Issuing/renewing $cert_name for: $domains"
  # --non-interactive: never prompt (e.g. "keep existing / renew & replace")
  # when a cert already exists, so the script is safe under cron/deploy.
  if ! "${CERTBOT[@]}" certonly --webroot -w "$WEBROOT" \
      --cert-name "$cert_name" --expand --non-interactive "${EXTRA[@]}" \
      --email "$EMAIL" --agree-tos --no-eff-email "${args[@]}"; then
    echo "  (certbot exit $? for $cert_name — continuing)"
  fi
done < <(grep -v '^#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$')

echo "==> Reloading nginx"
podman exec "$CONTAINER_NGINX" nginx -s reload || true

# If the issued cert name differs from the path nginx references, point the
# nginx path at it (test server: ionos cert served for every vhost).
FIRST_CERT="$(grep -v '^#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$' | head -1 | awk '{print $1}' || true)"
if [ -n "$FIRST_CERT" ] && [ "$FIRST_CERT" != "$NGINX_CERT_NAME" ] && [ -d "$LETSENCRYPT_DIR/live/$FIRST_CERT" ]; then
  rm -rf "$LETSENCRYPT_DIR/live/$NGINX_CERT_NAME"
  ln -s "$FIRST_CERT" "$LETSENCRYPT_DIR/live/$NGINX_CERT_NAME"
  echo "Linked $NGINX_CERT_NAME -> $FIRST_CERT (nginx serves the real cert)."
fi

echo "Certificates up to date."