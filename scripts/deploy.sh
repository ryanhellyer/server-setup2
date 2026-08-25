#!/usr/bin/env bash
# =============================================================================
# Compatibility wrapper — the MAIN entry point is ./deploy.sh at the repo
# root (easy to find). This exists so the old path keeps working:
#   sudo ./scripts/deploy.sh   ==   sudo ./deploy.sh
# =============================================================================
set -euo pipefail
exec "$(dirname "$0")/../deploy.sh" "$@"