#!/usr/bin/env bash
# =============================================================================
# backup.sh — nightly DB dump + site archive, pruned and offloaded to Hetzner.
#
# ⚠️ WORK IN PROGRESS — needs upgrading to match the real backup system.
#    This is a simple "mysqldump everything + tar /var/www" script; the real
#    production backup setup is in temp-backup/ (backup.sh + backup-config.sh
#    + backups/ from the main site). Use temp-backup/ as the reference to build
#    the real new backup system. Until it's upgraded, treat this as a starting
#    point, not the final backup solution.
#
# Scheduled automatically by scripts/install-systemd.sh (server-backup.timer,
# daily 03:00). Run manually:
#   sudo bash scripts/backup.sh
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