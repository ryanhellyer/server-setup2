#!/usr/bin/env bash
# =============================================================================
# lib-storage.sh — generic remote-storage config + helpers (source, don't run).
#
# The remote storage (Hetzner Storage Box today, anything SFTP/rsync tomorrow)
# is described by generic STORAGE_* variables. Legacy HETZNER_* names are still
# honoured as fallbacks so older .env files keep working.
#
#   source scripts/lib-storage.sh      # after .env is loaded
#
# Provides:
#   $STORAGE_USER $STORAGE_HOST $STORAGE_PORT $STORAGE_KEY
#   $SNAPSHOT_ROOT $SNAPSHOT_DIR $SNAPSHOT_RENAMES $DB_DUMP_DIR
#   box_ssh ...      run a command on the box (no TTY, batch mode)
#   box_cat PATH     cat a file from the box
#   newest_snapshot [site]   newest dated snapshot dir (optionally containing site)
#   apply_rename NAME        map a snapshot dir to its local dir name
# =============================================================================

# ---- generic config (new names, with HETZNER_* fallback) --------------------
STORAGE_USER="${STORAGE_USER:-${HETZNER_SYNC_USER:-}}"
STORAGE_HOST="${STORAGE_HOST:-${HETZNER_SYNC_HOST:-}}"
STORAGE_PORT="${STORAGE_PORT:-${HETZNER_SYNC_PORT:-23}}"
SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/home/pressabl}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-${HETZNER_SNAPSHOT_DIR:-}}"
SNAPSHOT_RENAMES="${SNAPSHOT_RENAMES:-}"
DB_DUMP_DIR="${DB_DUMP_DIR:-/home/ryan/databases}"

# The SSH key lives in the admin user's home (scripts run as root, so $HOME
# would be /root). Prefer STORAGE_KEY, then the legacy key, then the standard
# id_ed25519.
if [ -z "${STORAGE_KEY:-}" ]; then
  _storage_admin="${STORAGE_ADMIN_USER:-${SUDO_USER:-ryan}}"
  [ "$_storage_admin" = "root" ] && _storage_admin="ryan"
  _storage_home="$(getent passwd "$_storage_admin" 2>/dev/null | cut -d: -f6)"
  [ -n "$_storage_home" ] || _storage_home="/home/${_storage_admin:-ryan}"
  STORAGE_KEY="${HETZNER_SYNC_KEY:-$_storage_home/.ssh/id_ed25519}"
fi
unset _storage_admin _storage_home 2>/dev/null || true

# ---- box helpers ------------------------------------------------------------
box_ssh() {
  ssh -n -i "$STORAGE_KEY" -p "$STORAGE_PORT" -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "$STORAGE_USER@$STORAGE_HOST" "$@"
}
box_cat() {
  ssh -n -i "$STORAGE_KEY" -p "$STORAGE_PORT" -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "$STORAGE_USER@$STORAGE_HOST" "cat '$1'" 2>/dev/null
}

# Newest dated snapshot dir under $SNAPSHOT_ROOT. If a site name is given, only
# dirs that contain it count. $SNAPSHOT_DIR (explicit pin) wins.
newest_snapshot() {
  local site="${1:-}" d out=""
  if [ -n "$SNAPSHOT_DIR" ]; then printf '%s' "$SNAPSHOT_DIR"; return 0; fi
  while IFS= read -r d; do
    case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
    if [ -z "$site" ] || box_ssh "ls '$SNAPSHOT_ROOT/$d/$site'" >/dev/null 2>&1; then
      out="$SNAPSHOT_ROOT/$d"
    fi
  done <<< "$(box_ssh "ls '$SNAPSHOT_ROOT/'" 2>/dev/null | sort)"
  printf '%s' "$out"
}

# Map a snapshot directory to its local directory (SNAPSHOT_RENAMES holds
# space-separated "src=dst" pairs, e.g. "spam-destroyer.com=spam-destroyer.hellyer.kiwi").
apply_rename() {
  local name="$1" pair src dst
  for pair in $SNAPSHOT_RENAMES; do
    src="${pair%%=*}"; dst="${pair#*=}"
    if [ "$name" = "$src" ]; then printf '%s' "$dst"; return 0; fi
  done
  printf '%s' "$name"
}
