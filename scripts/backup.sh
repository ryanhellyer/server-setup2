#!/usr/bin/env bash
# =============================================================================
# backup.sh — nightly DB dump + site archive, pruned and offloaded to Hetzner.
#
# Add to cron:  0 3 * * * /path/to/server-setup/scripts/backup.sh
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh
[ -f .env ] && set -a && source .env && set +a

STAMP="$(date +%Y-%m-%d_%H%M)"
BACKUP_DIR="/var/databases"
mkdir -p "$BACKUP_DIR"

echo "==> Dumping all MariaDB databases"
if podman ps --format '{{.Names}}' | grep -q "^$CONTAINER_MARIADB$"; then
  podman exec "$CONTAINER_MARIADB" sh -c 'exec mysqldump --all-databases --single-transaction --quick -uroot -p"$MARIADB_ROOT_PASSWORD"' \
    > "$BACKUP_DIR/mysql-all-$STAMP.sql"
  gzip -f "$BACKUP_DIR/mysql-all-$STAMP.sql"
fi

echo "==> Archiving /var/www (site files)"
tar czf "$BACKUP_DIR/www-$STAMP.tar.gz" -C / var/www 2>/dev/null || true

echo "==> Pruning backups older than 14 days"
find "$BACKUP_DIR" -name 'mysql-all-*.sql.gz' -mtime +14 -delete
find "$BACKUP_DIR" -name 'www-*.tar.gz'       -mtime +14 -delete

if [ -n "${HETZNER_SSH:-}" ]; then
  echo "==> Offloading to Hetzner: $HETZNER_SSH"
  rsync -az --delete "$BACKUP_DIR/" "$HETZNER_SSH"
fi

echo "Backup complete: $BACKUP_DIR"