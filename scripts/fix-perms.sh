#!/usr/bin/env bash
# =============================================================================
# fix-perms.sh — apply the shared-hosting permission model to the web roots.
#
#   sudo ./scripts/fix-perms.sh [path]      (default: /var/www)
#
# Model (host and container www-data are both uid/gid 33 on Ubuntu, so group
# permissions line up across the /var/www bind mount):
#   * owner ryan, group www-data
#   * dirs  2775 (rwxrwxr-x + setgid) -> new dirs/files inherit www-data
#   * files 664  (rw-rw-r--)           -> editable by ryan AND the containers
#
# The PHP-FPM container creates files with `umask = 0002` (fpm-www.conf), so
# this state persists. Re-run after scripts/restore.sh too — restores can
# recreate root-owned files.
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./scripts/fix-perms.sh)."; exit 1; }

TARGET="${1:-/var/www}"
[ -d "$TARGET" ] || { echo "No such directory: $TARGET"; exit 1; }

OWNER="ryan"
GROUP="www-data"

echo "==> fix-perms: $TARGET (owner $OWNER:$GROUP, dirs 2775, files 664)"
chown -R "$OWNER:$GROUP" "$TARGET"
find "$TARGET" -type d -exec chmod 2775 {} +
find "$TARGET" -type f -exec chmod 664 {} +
echo "Permissions applied."