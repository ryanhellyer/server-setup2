#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore databases + site files from the most recent backups in
# /var/databases (as written by backup.sh).
#
#   sudo ./scripts/restore.sh
#
# If no backups exist yet (fresh test server) it just reports and exits — the
# stack comes up empty, ready for new-site.sh / manual seeding.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh
[ -f .env ] && set -a && source .env && set +a

BACKUP_DIR="${BACKUP_DIR:-/var/databases}"
DB_DUMP="$(ls -1t "$BACKUP_DIR"/mysql-all-*.sql.gz 2>/dev/null | head -1 || true)"
WWW_ARCHIVE="$(ls -1t "$BACKUP_DIR"/www-*.tar.gz 2>/dev/null | head -1 || true)"

[ -n "$DB_DUMP" ] || [ -n "$WWW_ARCHIVE" ] || {
  echo "No backups found in $BACKUP_DIR — nothing to restore (fresh stack)."
  exit 0
}

podman ps --format '{{.Names}}' | grep -q "^$CONTAINER_MARIADB$" || { echo "$CONTAINER_MARIADB container not running — start the stack first."; exit 1; }

if [ -n "$DB_DUMP" ]; then
  echo "==> Restoring databases from: $DB_DUMP"
  gunzip -c "$DB_DUMP" | podman exec -i "$CONTAINER_MARIADB" sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
fi

if [ -n "$WWW_ARCHIVE" ]; then
  echo "==> Restoring /var/www from: $WWW_ARCHIVE"
  tar xzf "$WWW_ARCHIVE" -C /
fi

echo
echo "Restore complete."
echo "Next: sudo ./scripts/deploy.sh (to rebuild + reload nginx against the data)."