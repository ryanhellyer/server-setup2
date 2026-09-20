#!/usr/bin/env bash
# =============================================================================
# provision-openwebui.sh — restore the Open WebUI data directory from the
# newest storage snapshot and (re)start the `open-webui` container.
#
# Open WebUI is its own container (not a PHP site). Its host data dir is the
# container's /app/backend/data (SQLite DB, uploads/, ChromaDB vector store).
#
#   sudo bash scripts/provision-openwebui.sh
#
# Always fresh: the data dir is rsynced with --delete (skipping the transient
# SQLite WAL/shm, cache/ and the old tooling).
#
# Options: --no-files, --drop-vector-db, --dry-run
#
# Config: see scripts/lib-storage.sh.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-storage.sh
source scripts/lib-env.sh
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

SITE_DIR="chat.hellyer.kiwi"
DO_FILES=1; DROP_VECTOR=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-files) DO_FILES=0; shift ;;
    --drop-vector-db) DROP_VECTOR=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

LOCAL_DIR="$WWW_ROOT/$SITE_DIR"
run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

SNAP="$(newest_snapshot "$SITE_DIR")"
[ -n "$SNAP" ] || die "No snapshot containing $SITE_DIR under $SNAPSHOT_ROOT."
say "Using snapshot: $SNAP/$SITE_DIR"

# ---- OpenRouter API key (from the old install.sh) ---------------------------
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  ok "OPENROUTER_API_KEY already set in .env."
else
  say "Reading OPENROUTER_API_KEY from the snapshot's install.sh"
  key="$(box_cat "$SNAP/$SITE_DIR/install.sh" \
        | grep -oE 'OPENROUTER_API_KEY=[^"'"'"' ]+' | head -1 | cut -d= -f2- || true)"
  if [ -n "$key" ]; then
    if [ "$DRY" = 1 ]; then
      echo "    DRY: set OPENROUTER_API_KEY=<redacted> in .env"
    else
      set_env ".env" OPENROUTER_API_KEY "$key"
      ok "Stored OPENROUTER_API_KEY in .env."
    fi
  else
    warn "Could not find OPENROUTER_API_KEY in $SNAP/$SITE_DIR/install.sh."
  fi
fi

# ---- data sync (always fresh) ----------------------------------------------
if [ "$DO_FILES" = 1 ]; then
  say "Syncing data -> $LOCAL_DIR"
  run mkdir -p "$LOCAL_DIR"
  run rsync -az --delete \
    --exclude='webui.db-shm' --exclude='webui.db-wal' \
    --exclude='cache' \
    --exclude='install.sh' --exclude='rebuild.sh' --exclude='upgrade.sh' \
    --exclude='TEMP_INSTALL_INSTRUCTIONS.md' \
    -e "ssh -i $STORAGE_KEY -p $STORAGE_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
    "$STORAGE_USER@$STORAGE_HOST:$SNAP/$SITE_DIR/" "$LOCAL_DIR/"
  if [ "$DROP_VECTOR" = 1 ]; then
    say "Dropping vector_db/ so ChromaDB rebuilds"
    run rm -rf "$LOCAL_DIR/vector_db"
  fi
  [ "$DRY" != 1 ] && chown -R ryan:ryan "$LOCAL_DIR" 2>/dev/null || true
fi

# ---- bring up the container -------------------------------------------------
say "Bringing up the open-webui service"
if [ "$DRY" = 1 ]; then
  echo "    DRY: podman-compose up -d open-webui"
else
  if podman compose version >/dev/null 2>&1; then podman compose up -d open-webui; else podman-compose up -d open-webui; fi
fi

# ---- wait for health --------------------------------------------------------
if [ "$DRY" != 1 ]; then
  say "Waiting for Open WebUI on http://127.0.0.1:3000/api/version"
  up=0
  for _ in $(seq 1 60); do
    if curl -sf --max-time 5 http://127.0.0.1:3000/api/version >/tmp/owui-version.json 2>/dev/null; then
      ok "Open WebUI is up: $(cat /tmp/owui-version.json)"; up=1; break
    fi
    sleep 5
  done
  [ "$up" = 1 ] || warn "Open WebUI did not answer in 5 min — check: podman logs open-webui"
fi

if [ "$DRY" != 1 ]; then
  podman exec "$CONTAINER_NGINX" nginx -t >/dev/null 2>&1 \
    && podman exec "$CONTAINER_NGINX" nginx -s reload >/dev/null 2>&1 || true
fi
ok "Done: $SITE_DIR (Open WebUI)"
