#!/usr/bin/env bash
# =============================================================================
# certbot-issue.sh — issue or renew certificates using the http01 webroot
# challenge (port 80). Which domains are issued is driven by .env:
#   CERTBOT_DOMAINS_FILE=...   default certbot/domains.txt
#                              (test: certbot/domains.test.txt)
#
# Usage:  sudo ./scripts/certbot-issue.sh [--force]
#   --force  force reissue even if a valid cert exists (rate-limit aware).
#
# Each server block serves ONE hardcoded certificate from its own live/<name>/
# dir (blocks without a real cert serve live/test-all; deploy.sh seeds
# placeholders so nginx starts even before certbot runs). This script only
# issues certs into their own live/<name>/ dirs.
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

[ -f "$DOMAINS_FILE" ] || { echo "Missing $DOMAINS_FILE"; exit 1; }
mkdir -p "$WEBROOT" "$LETSENCRYPT_DIR"

if command -v certbot >/dev/null 2>&1; then
  CERTBOT=(certbot)
else
  CERTBOT=(podman run --rm -v "$LETSENCRYPT_DIR:/etc/letsencrypt" -v "$WEBROOT:/var/www/acme" docker.io/certbot/certbot)
fi

EXTRA=()
[ "$FORCE" = "1" ] && EXTRA=(--force-renewal)

# Issue each cert. certbot exits non-zero when nothing needed doing (e.g.
# "Certificate not yet due for renewal"), which must NOT abort the script —
# the nginx reload below has to run regardless. DNS is checked per cert: a
# cert whose domains don't resolve is skipped (clear message) so one pending
# domain doesn't block the others (e.g. ionos still issues while a new test
# subdomain propagates). An IP mismatch is only a warning — certbot is the
# real judge, and its error (if any) is shown below.
PUBLIC_IP="$(curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null \
  || curl -fsSL --max-time 10 https://icanhazip.com 2>/dev/null || true)"

issue_cert() {
  local line="$1" cert_name domains d ip unresolved
  cert_name="$(echo "$line" | awk '{print $1}')"
  domains="$(echo "$line" | cut -d' ' -f2-)"
  unresolved=0
  for d in $domains; do
    ip="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    if [ -z "$ip" ]; then
      echo "  !! $d does not resolve yet — skipping $cert_name (point DNS, then re-run)"
      unresolved=1
    elif [ -n "$PUBLIC_IP" ] && [ "$ip" != "$PUBLIC_IP" ]; then
      echo "  !! warning: $d resolves to $ip; this host reports public IP $PUBLIC_IP"
    fi
  done
  [ "$unresolved" = "1" ] && return 0

  echo "==> Issuing/renewing $cert_name for: $domains"
  local args=()
  for d in $domains; do args+=(-d "$d"); done
  # --non-interactive: never prompt (e.g. "keep existing / renew & replace")
  # when a cert already exists, so the script is safe under cron/deploy.
  if ! "${CERTBOT[@]}" certonly --webroot -w "$WEBROOT" \
      --cert-name "$cert_name" --expand --non-interactive "${EXTRA[@]}" \
      --email "$EMAIL" --agree-tos --no-eff-email "${args[@]}"; then
    echo "  (certbot exit $? for $cert_name — continuing)"
  fi
}

while read -r line; do
  issue_cert "$line"
done < <(grep -v '^#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$')

echo "==> Reloading nginx"
podman exec "$CONTAINER_NGINX" nginx -s reload || true

echo "Certificates up to date."