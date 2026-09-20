#!/usr/bin/env bash
# =============================================================================
# provision-openwebui.sh — restore the Open WebUI data directory from the
# Hetzner snapshot and (re)start the `open-webui` container.
#
# Open WebUI is the odd one out: it is its own container (not a PHP site). Its
# host data dir is the container's /app/backend/data, holding the SQLite DB
# (webui.db), uploads/ and the ChromaDB vector store.
#
#   sudo bash scripts/provision-openwebui.sh
#
# What it does:
#   1. Finds the newest dated snapshot under OPENWEBUI_SNAPSHOT_ROOT that
#      contains chat.hellyer.kiwi (or use --snapshot DIR).
#   2. Reads OPENROUTER_API_KEY out of that snapshot's install.sh and stores it
#      in .env if not already set (never printed).
#   3. rsyncs the data into ~/www/chat.hellyer.kiwi, excluding the transient
#      SQLite WAL/shm files, cache/, and the old tooling (install.sh etc.).
#   4. Brings up the open-webui service and waits for /api/version.
#   5. Reloads nginx.
#
# Options:
#   --snapshot DIR     snapshot dir on the box (default: auto-detect newest)
#   --no-files         skip the data sync
#   --drop-vector-db   delete vector_db/ so ChromaDB rebuilds (paths may differ)
#   --dry-run          print actions, change nothing
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

SITE_DIR="chat.hellyer.kiwi"
SNAP_ROOT="${OPENWEBUI_SNAPSHOT_ROOT:-/home/pressabl}"
BOX_USER="${HETZNER_SYNC_USER:-u513410}"
BOX_HOST="${HETZNER_SYNC_HOST:-u513410.your-storagebox.de}"
BOX_PORT="${HETZNER_SYNC_PORT:-23}"
BOX_KEY="${HETZNER_SYNC_KEY:-/home/ryan/.ssh/hetzner_backup}"

SNAPSHOT=""; DO_FILES=1; DROP_VECTOR=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) SNAPSHOT="${2:?}"; shift 2 ;;
    --no-files) DO_FILES=0; shift ;;
    --drop-vector-db) DROP_VECTOR=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

LOCAL_DIR="$WWW_ROOT/$SITE_DIR"
run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

box_ssh() { ssh -n -i "$BOX_KEY" -p "$BOX_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$BOX_USER@$BOX_HOST" "$@"; }
box_cat() { ssh -n -i "$BOX_KEY" -p "$BOX_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$BOX_USER@$BOX_HOST" "cat '$1'" 2>/dev/null; }

set_env() { # file key value
  local f="$1" k="$2" v="$3"
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

# ---- 1. find the snapshot ----------------------------------------------------
if [ -z "$SNAPSHOT" ]; then
  say "Finding the newest snapshot with $SITE_DIR under $SNAP_ROOT"
  dates="$(box_ssh "ls '$SNAP_ROOT/'" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort || true)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if box_ssh "ls '$SNAP_ROOT/$d/$SITE_DIR'" >/dev/null 2>&1; then SNAPSHOT="$SNAP_ROOT/$d"; fi
  done <<< "$dates"
  [ -n "$SNAPSHOT" ] || die "No dated snapshot containing $SITE_DIR under $SNAP_ROOT."
fi
say "Using snapshot: $SNAPSHOT/$SITE_DIR"

# ---- 2. OpenRouter API key (from the old install.sh) -------------------------
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  ok "OPENROUTER_API_KEY already set in .env."
else
  say "Reading OPENROUTER_API_KEY from the snapshot's install.sh"
  key="$(box_cat "$SNAPSHOT/$SITE_DIR/install.sh" \
        | grep -oE 'OPENROUTER_API_KEY=[^"'"'"' ]+' | head -1 | cut -d= -f2- || true)"
  if [ -n "$key" ]; then
    if [ "$DRY" = 1 ]; then
      echo "    DRY: set OPENROUTER_API_KEY=<redacted> in .env"
    else
      set_env ".env" OPENROUTER_API_KEY "$key"
      ok "Stored OPENROUTER_API_KEY in .env."
    fi
  else
    warn "Could not find OPENROUTER_API_KEY in $SNAPSHOT/$SITE_DIR/install.sh."
    warn "Set OPENROUTER_API_KEY in .env manually before using OpenRouter models."
  fi
fi

# ---- 3. data sync ------------------------------------------------------------
if [ "$DO_FILES" = 1 ]; then
  say "Syncing data -> $LOCAL_DIR"
  run mkdir -p "$LOCAL_DIR"
  run rsync -az --delete \
    --exclude='webui.db-shm' --exclude='webui.db-wal' \
    --exclude='cache' \
    --exclude='install.sh' --exclude='rebuild.sh' --exclude='upgrade.sh' \
    --exclude='TEMP_INSTALL_INSTRUCTIONS.md' \
    -e "ssh -i $BOX_KEY -p $BOX_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
    "$BOX_USER@$BOX_HOST:$SNAPSHOT/$SITE_DIR/" "$LOCAL_DIR/"
  if [ "$DROP_VECTOR" = 1 ]; then
    say "Dropping vector_db/ so ChromaDB rebuilds"
    run rm -rf "$LOCAL_DIR/vector_db"
  fi
  # Data is written by the container (root) and read by nobody else; keep it
  # owned by ryan so backups/rsync behave, but do not force group www-data.
  [ "$DRY" != 1 ] && chown -R ryan:ryan "$LOCAL_DIR" 2>/dev/null || true
fi

# ---- 4. bring up the container ----------------------------------------------
say "Bringing up the open-webui service"
if [ "$DRY" = 1 ]; then
  echo "    DRY: podman-compose up -d open-webui"
else
  if podman compose version >/dev/null 2>&1; then
    podman compose up -d open-webui
  else
    podman-compose up -d open-webui
  fi
fi

# ---- 5. wait for health ------------------------------------------------------
if [ "$DRY" != 1 ]; then
  say "Waiting for Open WebUI to answer on http://127.0.0.1:3000/api/version"
  up=0
  for _ in $(seq 1 60); do
    if curl -sf --max-time 5 http://127.0.0.1:3000/api/version >/tmp/owui-version.json 2>/dev/null; then
      ok "Open WebUI is up: $(cat /tmp/owui-version.json)"
      up=1; break
    fi
    sleep 5
  done
  [ "$up" = 1 ] || warn "Open WebUI did not answer within 5 minutes — check: podman logs open-webui"
fi

# ---- 6. reload nginx ---------------------------------------------------------
if [ "$DRY" != 1 ]; then
  podman exec "$CONTAINER_NGINX" nginx -t >/dev/null 2>&1 \
    && podman exec "$CONTAINER_NGINX" nginx -s reload >/dev/null 2>&1 || true
fi
ok "Done: $SITE_DIR (Open WebUI)"
