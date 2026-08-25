#!/usr/bin/env bash
# =============================================================================
# host-setup.sh — install the (small) host package set and create the
# bind-mount directories. Run once as root.
#
# Called by:
#   - bootstrap.sh (one-time host setup)
#   - deploy.sh    (automatically, when podman/podman-compose are missing)
# =============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + upgrade"
apt-get update
apt-get upgrade -y

echo "==> installing host packages"
apt-get install -y \
  podman \
  podman-compose \
  curl \
  tar \
  rsync \
  openssl \
  openssh-client \
  sshfs \
  ufw \
  unattended-upgrades \
  nano

echo "==> creating bind-mount directories"
mkdir -p /var/www /var/databases /var/cache/nginx /var/log/nginx

echo "Host packages installed."