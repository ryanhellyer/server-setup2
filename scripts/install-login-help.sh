#!/usr/bin/env bash
# =============================================================================
# install-login-help.sh — install an SSH login banner that lists the host
# helper commands (pod-login, pod-logs, pod-status, ...).
#
#   sudo bash scripts/install-login-help.sh
#   sudo bash scripts/install-login-help.sh --remove
#
# Writes /etc/update-motd.d/99-server-setup, which Ubuntu's pam_motd runs on
# every interactive login (SSH and console) — so the commands are always in
# view. Idempotent: re-running just refreshes the text.
# =============================================================================
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
MOTD_FILE="${MOTD_FILE:-/etc/update-motd.d/99-server-setup}"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$SELF" "$@"
fi

if [ "${1:-}" = "--remove" ]; then
  rm -f "$MOTD_FILE"
  echo "Removed login banner: $MOTD_FILE"
  exit 0
fi

mkdir -p "$(dirname "$MOTD_FILE")"
cat > "$MOTD_FILE" <<'EOF'
#!/bin/sh
# server-setup — SSH login banner. Managed by scripts/install-login-help.sh.
# Remove with: sudo bash scripts/install-login-help.sh --remove
cat <<'BANNER'

  server-setup — host helper commands
  -----------------------------------
    pod-login [container]         shell inside a container (default: php-fpm)
    pod-logs  [container] [-f]    print / follow a container's logs
    pod-status                    stack state + health
    pod-restart <c> | --all       restart a container / the whole stack
    sites                         list sites under ~/www (type + database)
    cert-status                   TLS certificate domains + expiry
    pod-exec <container> <cmd>    run one command in any container
    php | composer | wp | artisan | mariadb | node | nginx ...   in-container tools

  Docs: README.md    Menu: sudo ./install/setup.sh    Follow logs: pod-logs -f

BANNER
EOF
chmod 755 "$MOTD_FILE"

echo "Installed login banner: $MOTD_FILE"
echo "It appears on the next interactive login (SSH or console)."
