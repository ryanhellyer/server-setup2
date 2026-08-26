#!/usr/bin/env bash
# =============================================================================
# test-site.sh — scaffold the ionos.hellyer.kiwi test site on THIS server.
# Copies the versioned test page from sites/ionos.hellyer.kiwi/ into
# /var/www/ionos.hellyer.kiwi/public/ and reloads nginx.
#
#   sudo ./scripts/test-site.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh

SRC="sites/ionos.hellyer.kiwi"
DEST="/var/www/ionos.hellyer.kiwi/public"

[ -d "$SRC" ] || { echo "Missing $SRC"; exit 1; }

echo "==> Copying test site -> $DEST"
mkdir -p "$DEST"
cp -r "$SRC/." "$DEST/"

echo "==> Reloading nginx"
podman exec "$CONTAINER_NGINX" nginx -s reload || true

echo
echo "Test site ready. Point DNS ionos.hellyer.kiwi at this host, then visit:"
echo "  https://ionos.hellyer.kiwi"