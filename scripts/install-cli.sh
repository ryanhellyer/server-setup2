#!/usr/bin/env bash
# =============================================================================
# install-cli.sh — install host-side command wrappers that run inside the
# right container (via bin/pod-exec). Creates symlinks in ~/.local/bin
# (or the directory given as the first argument). The command list comes from
# scripts/lib-containers.sh (single source of truth).
#
#   ./scripts/install-cli.sh
#   export PATH="$HOME/.local/bin:$PATH"     # add to ~/.bashrc
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-$HOME/.local/bin}"

mkdir -p "$DEST_DIR"

source "$REPO_DIR/scripts/lib-containers.sh"

for cmd in "${!CLI_CONTAINER[@]}"; do
  ln -sf "$REPO_DIR/bin/pod-exec" "$DEST_DIR/$cmd"
done

echo "Installed wrappers to: $DEST_DIR"
echo "Add this to ~/.bashrc (before /usr/bin):"
echo "  export PATH=\"$DEST_DIR:\$PATH\""