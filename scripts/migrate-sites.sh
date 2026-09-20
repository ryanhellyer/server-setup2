#!/usr/bin/env bash
# =============================================================================
# migrate-sites.sh — provision many sites at once by calling provision-site.sh
# for each. No manifest: sites are discovered automatically.
#
#   sudo bash scripts/migrate-sites.sh                 # all sites found in the snapshot
#   sudo bash scripts/migrate-sites.sh cvs.hellyer.kiwi spam-destroyer.com
#   sudo bash scripts/migrate-sites.sh --all --files-only
#   sudo bash scripts/migrate-sites.sh --dry-run
#
# With no site arguments it lists the file snapshot on the storage box and
# keeps the directories that look like sites (contain public/ or public_html/
# or .env or wp-config.php), skipping backup scripts / config dirs.
#
# Any of these pass straight through to provision-site.sh for every site:
#   --files-only  --db-only  --force  --dry-run
#
# Config: see provision-site.sh (HETZNER_SNAPSHOT_DIR, DB_DUMP_DIR, HETZNER_SYNC_*).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-paths.sh
[ -f .env ] && set -a && source .env && set +a
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

SNAPSHOT_DIR="${HETZNER_SNAPSHOT_DIR:-/home/pressabl/2026-08-27}"
BOX_USER="${HETZNER_SYNC_USER:-u513410}"
BOX_HOST="${HETZNER_SYNC_HOST:-u513410.your-storagebox.de}"
BOX_PORT="${HETZNER_SYNC_PORT:-23}"
BOX_KEY="${HETZNER_SYNC_KEY:-/home/ryan/.ssh/hetzner_backup}"

ALL=0; OPTS=(); SITE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --files-only|--db-only|--force|--dry-run) OPTS+=("$arg") ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) SITE_ARGS+=("$arg") ;;
  esac
done

box_ssh() { ssh -n -i "$BOX_KEY" -p "$BOX_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$BOX_USER@$BOX_HOST" "$@"; }

# ---- collect site dirs ------------------------------------------------------
SITES=()
if [ "$ALL" = 1 ] || [ "${#SITE_ARGS[@]}" -eq 0 ]; then
  say "Discovering sites in ${BOX_USER}@${BOX_HOST}:$SNAPSHOT_DIR"
  ALL_ENTRIES="$(box_ssh "ls '$SNAPSHOT_DIR/'" 2>/dev/null || true)"
  [ -n "$ALL_ENTRIES" ] || { echo "Could not list $SNAPSHOT_DIR on the box." >&2; exit 1; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # skip obvious non-site entries (backup scripts, configs, dumps, etc.)
    case "$name" in
      *.sh|*.conf|*.txt|*.save|*.log|*.swp|.*) continue ;;
      *OLD*|*BACKUP*|old-*) continue ;;
      backups|configs|html|temp|acme|netcup|web-server|from-xps13|old-shit|words-temp|s3-metrics*|jordan-*|nz-*) continue ;;
    esac
    # The Storage Box shell is restricted (no test/glob), but `ls -a` works.
    listing="$(box_ssh "ls -a '$SNAPSHOT_DIR/$name'" 2>/dev/null || true)"
    if printf '%s\n' "$listing" | grep -qxE 'public|public_html|\.env|wp-config\.php'; then
      SITES+=("$name")
    fi
  done <<< "$ALL_ENTRIES"
else
  SITES=("${SITE_ARGS[@]}")
fi

[ "${#SITES[@]}" -gt 0 ] || { warn "No sites to provision."; exit 0; }
say "Sites: ${SITES[*]}"
echo

FAILED=()
for site in "${SITES[@]}"; do
  echo "================================================================"
  say "Provisioning $site"
  if bash "$PWD/scripts/provision-site.sh" "$site" "${OPTS[@]}"; then
    :
  else
    warn "FAILED: $site"
    FAILED+=("$site")
  fi
  echo
done

echo "================================================================"
echo "Provisioned: $(( ${#SITES[@]} - ${#FAILED[@]} ))/${#SITES[@]}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "Failures: ${FAILED[*]}"
  exit 1
fi
