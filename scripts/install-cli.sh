#!/usr/bin/env bash
# =============================================================================
# install-cli.sh — install host-side command wrappers that run inside the
# right container (via bin/pod-exec). Creates symlinks in ~/.local/bin
# (or the directory given as the first argument).
#
#   ./scripts/install-cli.sh
#   export PATH="$HOME/.local/bin:$PATH"     # add to ~/.bashrc
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-$HOME/.local/bin}"

mkdir -p "$DEST_DIR"

COMMANDS=(
  # PHP container
  php composer wp artisan ffmpeg ffprobe php-reload
  # MariaDB container
  mariadb mysql mysqldump mariadb-dump
  # Redis container
  redis-cli
  # Node container
  node npm npx yarn
  # Nginx container
  nginx nginx-test nginx-reload nginx-restart
)

for c in "${COMMANDS[@]}"; do
  ln -sf "$REPO_DIR/bin/pod-exec" "$DEST_DIR/$c"
done

echo "Installed wrappers to: $DEST_DIR"
echo "Add this to ~/.bashrc (before /usr/bin):"
echo "  export PATH=\"$DEST_DIR:\$PATH\""