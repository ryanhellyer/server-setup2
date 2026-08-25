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
echo "  1. Put this repo on the host at /opt/server-setup"
echo "     (git clone <remote> /opt/server-setup  OR  rsync a copy there)."
echo "  2. cd /opt/server-setup && cp .env.example .env && edit .env (test settings)."
echo "  3. sudo ./scripts/deploy.sh          # builds + starts the whole stack"
echo "  4. sudo ./scripts/test-site.sh       # scaffold the ionos test page"
echo "  5. sudo ./scripts/certbot-issue.sh   # real TLS for ionos.hellyer.kiwi"
echo "  6. Point DNS ionos.hellyer.kiwi at this host and visit https://ionos.hellyer.kiwi"