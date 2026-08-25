#!/usr/bin/env bash
# =============================================================================
# render-config.sh — render nginx/nginx.conf from nginx/nginx.conf.template
# using values from .env (currently just the fastcgi cache zone size).
#
#   FASTCGI_CACHE_SIZE=64m   (test)   /   500m   (production)
#
# Called automatically by deploy.sh before nginx -t / compose up.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && set -a && source .env && set +a

CACHE="${FASTCGI_CACHE_SIZE:-64m}"
case "$CACHE" in
  *k|*K|*m|*M|*g|*G) : ;;
  *) CACHE="${CACHE}m" ;;
esac

sed "s/__FASTCGI_CACHE_SIZE__/$CACHE/g" nginx/nginx.conf.template > nginx/nginx.conf

echo "Rendered nginx/nginx.conf (fastcgi cache keys_zone: $CACHE)."