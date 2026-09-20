#!/usr/bin/env bash
# =============================================================================
# provision-site.sh — restore ONE site end-to-end, auto-deriving everything
# from the site's own files (no manifest):
#
#   1. rsync the site's directory from the old /var/www snapshot on the
#      Hetzner Storage Box into the host web root (~/www/<dir>).
#   2. Read the app's OWN config to find its database:
#        - Laravel  -> .env        (DB_CONNECTION / DB_DATABASE / DB_USERNAME / DB_PASSWORD)
#        - WordPress -> wp-config.php
#        - sqlite   -> just ensure the database file exists and is writable
#   3. Create the DB + user + grants in MariaDB, and import the newest matching
#      dump from DB_DUMP_DIR — but only if the DB is empty (--force to wipe).
#   4. Rewrite the app config to talk to the containers
#      (DB_HOST=mariadb, REDIS_HOST=valkey, REDIS_PASSWORD=).
#   5. Clear caches, fix ownership/permissions, reload nginx.
#
#   sudo bash scripts/provision-site.sh <site-dir> [options]
#
# Options:
#   --domain DOMAIN   canonical domain (sets APP_URL; used by WP search-replace)
#   --from DIR        remote snapshot subdir (default: <site-dir>)
#   --files-only      only sync files
#   --db-only         only provision the database (assumes files present)
#   --force           re-import the dump even if the DB already has tables
#   --dry-run         print what would happen, change nothing
#
# Config (all optional; defaults match this project):
#   HETZNER_SNAPSHOT_DIR  default /home/pressabl/2026-08-27
#   DB_DUMP_DIR           default /home/ryan/databases
#   HETZNER_SYNC_USER/HOST/PORT/KEY  storage box for the file snapshot
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh
source scripts/lib-paths.sh
[ -f .env ] && set -a && source .env && set +a
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

SNAPSHOT_DIR="${HETZNER_SNAPSHOT_DIR:-/home/pressabl/2026-08-27}"
DUMP_DIR="${DB_DUMP_DIR:-/home/ryan/databases}"
BOX_USER="${HETZNER_SYNC_USER:-u513410}"
BOX_HOST="${HETZNER_SYNC_HOST:-u513410.your-storagebox.de}"
BOX_PORT="${HETZNER_SYNC_PORT:-23}"
BOX_KEY="${HETZNER_SYNC_KEY:-/home/ryan/.ssh/hetzner_backup}"

DO_FILES=1; DO_DB=1; FORCE=0; DRY=0
SITE_DIR=""; DOMAIN=""; FROM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --from)   FROM="${2:?}"; shift 2 ;;
    --files-only) DO_DB=0; shift ;;
    --db-only)    DO_FILES=0; shift ;;
    --force)  FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *)  [ -z "$SITE_DIR" ] || die "Only one site-dir supported."; SITE_DIR="$1"; shift ;;
  esac
done
[ -n "$SITE_DIR" ] || die "Usage: provision-site.sh <site-dir> [options]"
case "$SITE_DIR" in *[!A-Za-z0-9._-]*) die "Invalid site-dir: $SITE_DIR" ;; esac
REMOTE_DIR="${FROM:-$SITE_DIR}"
LOCAL_DIR="$WWW_ROOT/$SITE_DIR"

run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

# ---- helpers -----------------------------------------------------------------
set_env() { # file key value
  local f="$1" k="$2" v="$3"
  [ "$DRY" = 1 ] && { echo "    DRY: set $k=$v in ${f#$WWW_ROOT/}"; return 0; }
  python3 - "$f" "$k" "$v" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
found = False
for i, ln in enumerate(lines):
    if ln.startswith(key + "="):
        lines[i] = f"{key}={val}"; found = True
if not found:
    lines.append(f"{key}={val}")
open(path, "w").write("\n".join(lines) + "\n")
PY
}

get_env() { # file key
  [ -f "$1" ] || return 1
  grep -E "^[[:space:]]*$2=" "$1" | tail -1 | cut -d= -f2- | sed -E "s/^['\"]//; s/['\"]\$//"
}

mdb()        { podman exec -i "$CONTAINER_MARIADB" sh -c "exec mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" $*"; }
mdb_import() { local db="$1" dump="$2"; zcat "$dump" | podman exec -i "$CONTAINER_MARIADB" sh -c "exec mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" '$db'"; }

mariadb_running() {
  local i s
  for i in 1 2 3 4 5; do
    s="$(podman inspect -f '{{.State.Running}}' "$CONTAINER_MARIADB" 2>/dev/null || true)"
    [ "$s" = "true" ] && return 0
    sleep 0.5
  done
  return 1
}

TMP_SUFFIX="$$"
trap 'rm -f "/tmp/ps-env.$TMP_SUFFIX" "/tmp/ps-wp.$TMP_SUFFIX" 2>/dev/null || true' EXIT

# Read a file from the snapshot (used to detect the DB without syncing first,
# e.g. under --dry-run or --db-only). Returns non-empty output on success.
box_cat() {
  ssh -n -i "$BOX_KEY" -p "$BOX_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
    "$BOX_USER@$BOX_HOST" "cat '$1'" 2>/dev/null
}

# =============================================================================
say "Provisioning site: $SITE_DIR  (host dir $LOCAL_DIR)"
[ "$DRY" = 1 ] && warn "dry-run: no changes will be made"

# ---- 1. files ---------------------------------------------------------------
if [ "$DO_FILES" = 1 ]; then
  say "Checking snapshot: ${BOX_USER}@${BOX_HOST}:$SNAPSHOT_DIR/$REMOTE_DIR"
  if ! ssh -n -i "$BOX_KEY" -p "$BOX_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        "$BOX_USER@$BOX_HOST" "ls '$SNAPSHOT_DIR/$REMOTE_DIR'" >/dev/null 2>&1; then
    warn "no snapshot directory '$SNAPSHOT_DIR/$REMOTE_DIR' on the box — skipping file sync."
  else
    say "Syncing files -> $LOCAL_DIR"
    run mkdir -p "$LOCAL_DIR"
    run rsync -az --delete --exclude='*.log' --exclude='.cache' --exclude='lost+found' \
      -e "ssh -i $BOX_KEY -p $BOX_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
      "$BOX_USER@$BOX_HOST:$SNAPSHOT_DIR/$REMOTE_DIR/" "$LOCAL_DIR/"
  fi
fi

# ---- 2. discover the database from the app's own config ---------------------
DB_DRIVER=""; DB_NAME=""; DB_USER=""; DB_PASS=""
ENV_FILE="$LOCAL_DIR/.env"; WPCONF="$LOCAL_DIR/wp-config.php"
# If the files aren't on disk yet (dry-run / db-only), read them from the box.
if [ ! -f "$ENV_FILE" ] && [ ! -f "$WPCONF" ]; then
  box_cat "$SNAPSHOT_DIR/$REMOTE_DIR/.env"         > /tmp/ps-env.$$ 2>/dev/null || true
  box_cat "$SNAPSHOT_DIR/$REMOTE_DIR/wp-config.php" > /tmp/ps-wp.$$  2>/dev/null || true
  [ -s "/tmp/ps-env.$$" ] && ENV_FILE="/tmp/ps-env.$$"
  [ -s "/tmp/ps-wp.$$" ]  && WPCONF="/tmp/ps-wp.$$"
fi

if [ -f "$ENV_FILE" ]; then
  DB_DRIVER="$(get_env "$ENV_FILE" DB_CONNECTION || true)"
  DB_NAME="$(get_env "$ENV_FILE" DB_DATABASE || true)"
  DB_USER="$(get_env "$ENV_FILE" DB_USERNAME || true)"
  DB_PASS="$(get_env "$ENV_FILE" DB_PASSWORD || true)"
  say "Detected Laravel app (DB_CONNECTION=${DB_DRIVER:-mariadb})"
elif [ -f "$WPCONF" ]; then
  DB_DRIVER="mariadb"
  DB_NAME="$(sed -nE "s/.*define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]([^'\"]+)['\"].*/\1/p" "$WPCONF" | head -1)"
  DB_USER="$(sed -nE "s/.*define\(\s*['\"]DB_USER['\"]\s*,\s*['\"]([^'\"]+)['\"].*/\1/p" "$WPCONF" | head -1)"
  DB_PASS="$(sed -nE "s/.*define\(\s*['\"]DB_PASSWORD['\"]\s*,\s*['\"]([^'\"]*)['\"].*/\1/p" "$WPCONF" | head -1)"
  say "Detected WordPress site (DB_NAME=${DB_NAME:-?})"
else
  warn "No .env or wp-config.php found — nothing to configure (static site?)."
fi

# ---- 3. database ------------------------------------------------------------
if [ "$DO_DB" = 1 ] && [ -n "$DB_DRIVER" ]; then
  if [ "$DB_DRIVER" = "sqlite" ]; then
    case "$DB_NAME" in
      "$CONTAINER_WWW"/*) sqlite_path="$(www_host_path "$DB_NAME")" ;;
      /*)                 sqlite_path="$DB_NAME" ;;
      *)                  sqlite_path="$LOCAL_DIR/$DB_NAME" ;;
    esac
    say "SQLite database: $sqlite_path"
    if [ "$DRY" != 1 ] && [ -n "$sqlite_path" ]; then
      [ -f "$sqlite_path" ] || { mkdir -p "$(dirname "$sqlite_path")"; : > "$sqlite_path"; }
      chown "$(stat -c %u "$LOCAL_DIR"):$(stat -c %g "$LOCAL_DIR")" "$sqlite_path" 2>/dev/null || true
    fi
  elif [ -n "$DB_NAME" ]; then
    case "$DB_NAME" in *[!A-Za-z0-9_]*) die "Unsafe DB name from app config: $DB_NAME" ;; esac
    DB_USER="${DB_USER:-$DB_NAME}"
    case "$DB_USER" in *[!A-Za-z0-9_]*) die "Unsafe DB user from app config: $DB_USER" ;; esac
    mariadb_running || die "$CONTAINER_MARIADB is not running — start the stack first."

    say "Ensuring database '$DB_NAME' + user '$DB_USER'"
    pass_sql="${DB_PASS//\'/\'\'}"
    {
      printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$DB_NAME"
      printf "CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\n" "$DB_USER" "$pass_sql"
      printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\n" "$DB_NAME" "$DB_USER"
      printf 'FLUSH PRIVILEGES;\n'
    } > /tmp/provision-site.sql
    if [ "$DRY" = 1 ]; then
      echo "    DRY: apply DB/user/grants for $DB_NAME"
    else
      mdb < /tmp/provision-site.sql
    fi
    rm -f /tmp/provision-site.sql

    tables="$(printf "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='%s';" "$DB_NAME" | mdb -N -B)"
    if [ "$FORCE" = 1 ] && [ "$DRY" != 1 ]; then
      say "--force: dropping and recreating $DB_NAME"
      printf 'DROP DATABASE `%s`; CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$DB_NAME" "$DB_NAME" | mdb
      tables=0
    fi

    dump="$(ls -1 "$DUMP_DIR/$DB_NAME"-*.sql.gz 2>/dev/null | sort | tail -1 || true)"
    if [ "${tables:-0}" -gt 0 ]; then
      ok "$DB_NAME already has $tables tables — keeping it (use --force to re-import)."
    elif [ -n "$dump" ]; then
      say "Importing $(basename "$dump")"
      [ "$DRY" != 1 ] && mdb_import "$DB_NAME" "$dump"
      ok "Imported $DB_NAME."
    else
      warn "No dump found in $DUMP_DIR for '$DB_NAME' — leaving the database empty."
      if [ -f "$LOCAL_DIR/artisan" ]; then
        say "Running migrations (php artisan migrate --force)"
        [ "$DRY" != 1 ] && podman exec -u www-data -w "$CONTAINER_WWW/$SITE_DIR" "$CONTAINER_PHP_FPM" \
          php artisan migrate --force || warn "migrate failed (check the app config)."
      fi
    fi
  fi
fi

# ---- 4. point the app at the container services -----------------------------
if [ -f "$LOCAL_DIR/.env" ]; then
  say "Rewriting app .env for the container network"
  set_env "$LOCAL_DIR/.env" DB_HOST mariadb
  set_env "$LOCAL_DIR/.env" DB_PORT 3306
  set_env "$LOCAL_DIR/.env" REDIS_HOST valkey
  set_env "$LOCAL_DIR/.env" REDIS_PASSWORD ""
  [ -n "$DOMAIN" ] && set_env "$LOCAL_DIR/.env" APP_URL "https://$DOMAIN"
  # Caches must be rebuilt so the new config takes effect.
  if [ "$DRY" != 1 ]; then
    rm -f "$LOCAL_DIR"/bootstrap/cache/*.php 2>/dev/null || true
    podman exec -u www-data -w "$CONTAINER_WWW/$SITE_DIR" "$CONTAINER_PHP_FPM" php artisan config:clear >/dev/null 2>&1 || true
    podman exec -u www-data -w "$CONTAINER_WWW/$SITE_DIR" "$CONTAINER_PHP_FPM" php artisan cache:clear  >/dev/null 2>&1 || true
  fi
elif [ -f "$LOCAL_DIR/wp-config.php" ]; then
  say "Pointing wp-config.php at the mariadb container"
  [ "$DRY" != 1 ] && sed -i -E "s/(define\(\s*'DB_HOST'\s*,\s*')[^']*(')/\1mariadb\2/" "$LOCAL_DIR/wp-config.php"
  if [ -n "$DOMAIN" ] && command -v podman >/dev/null 2>&1; then
    : # WP search-replace can be added later; URLs in the dump are left as-is.
  fi
fi

# ---- 5. permissions + reload ------------------------------------------------
[ "$DO_FILES" = 1 ] && run bash "$PWD/scripts/fix-perms.sh" "$LOCAL_DIR" >/dev/null || true
if [ "$DRY" != 1 ]; then
  podman exec "$CONTAINER_NGINX" nginx -s reload >/dev/null 2>&1 || true
fi
ok "Done: $SITE_DIR"
