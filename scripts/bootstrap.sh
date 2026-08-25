#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-time host setup for a fresh Ubuntu 24.04/26.04 server.
# Installs the (small) host package set, creates the bind-mount directories,
# then prints the next steps. Run once as root.
#
#   sudo ./scripts/bootstrap.sh
# =============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./scripts/bootstrap.sh)."; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + upgrade"
apt-get update
apt-get upgrade -y

echo "==> installing host packages"
apt-get install -y \
  podman \
  podman-compose \
  git \
  openssl \
  openssh-client \
  sshfs \
  ufw \
  unattended-upgrades

echo "==> creating bind-mount directories"
mkdir -p /var/www /var/databases /var/cache/nginx /var/log/nginx

echo
echo "Host bootstrap complete."
echo
echo "Next steps:"
echo "  1. Make an SSH key SPECIFIC to this server (don't reuse a personal key):"
echo "       ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N '' -C 'server-setup-deploy'"
echo "       cat /root/.ssh/id_ed25519.pub"
echo "  2. Add that public key in the GitHub console — either:"
echo "       - this repo only: github.com/<you>/server-setup2 -> Settings -> Deploy keys ->"
echo "         Add deploy key (paste key, tick 'Allow write access' only if needed)."
echo "       - account-wide:  github.com/settings/keys -> New SSH key."
echo "  3. Verify the host can reach GitHub:"
echo "       ssh -T git@github.com   # should greet you"
echo "  4. Clone the repo yourself (no script does this):"
echo "       git clone git@github.com:ryanhellyer/server-setup2.git /opt/server-setup"
echo "  5. cd /opt/server-setup && cp .env.example .env && edit .env (test settings)."
echo "  6. sudo ./scripts/deploy.sh          # builds + starts the whole stack"
echo "  7. sudo ./scripts/test-site.sh       # scaffold the ionos test page"
echo "  8. sudo ./scripts/certbot-issue.sh   # real TLS for ionos.hellyer.kiwi"
echo "  9. Point DNS ionos.hellyer.kiwi at this host and visit https://ionos.hellyer.kiwi"