#!/usr/bin/env bash
# =============================================================================
# install.sh — one-shot installer for the hellyer.kiwi server stack.
#
# Single-line usage on a bare Ubuntu host (no docs, no keys, no git):
#
#   curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install.sh \
#     -o /tmp/install.sh && sudo bash /tmp/install.sh
#
# What it does:
#   1. Installs the host packages (podman, podman-compose, curl, openssl, nano...).
#   2. Downloads this whole repo as a tarball from GitHub (public repo — no SSH
#      keys needed) into /opt/server-setup and writes a .tarball marker so
#      deploy.sh can refresh the files the same way later.
#   3. Hands off to ./deploy.sh, which refreshes the files, creates .env (opens
#      it in nano for you), builds the images and starts the whole stack.
#
# Safe to re-run — every step is idempotent, and your .env / TLS certs are
# never touched (they aren't in the tarball).
# =============================================================================
set -euo pipefail

REPO_DIR="${SERVER_SETUP_DIR:-/opt/server-setup}"
TARBALL_URL="${SERVER_SETUP_TARBALL:-https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz}"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }

# ---- 0. root ----
if [ "$(id -u)" -ne 0 ]; then
  say "Not running as root — re-running with sudo."
  exec sudo bash "$0"
fi

echo
echo "hellyer.kiwi server installer"
echo "============================="
echo

# ---- 1. host packages ----
if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer needs an Ubuntu/Debian host (apt-get). Aborting."
  exit 1
fi

say "Installing host packages (podman, podman-compose, curl, openssl, nano ...)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y \
  podman \
  podman-compose \
  curl \
  tar \
  rsync \
  openssl \
  openssh-client \
  nano \
  sshfs \
  ufw \
  unattended-upgrades

mkdir -p /var/www /var/databases /var/cache/nginx /var/log/nginx
ok "Host packages installed."

# ---- 2. download the files (no git, no keys) ----
say "Downloading the server-setup files from GitHub"
mkdir -p "$REPO_DIR"
curl -fsSL "$TARBALL_URL" -o /tmp/server-setup.tar.gz
tar -xzf /tmp/server-setup.tar.gz --strip-components=1 -C "$REPO_DIR"
rm -f /tmp/server-setup.tar.gz

# Remember how we were installed so deploy.sh can refresh the same way.
printf '%s\n' "$TARBALL_URL" > "$REPO_DIR/.tarball"
chmod 600 "$REPO_DIR/.tarball"

[ -f "$REPO_DIR/deploy.sh" ] || { echo "Download failed — no deploy.sh found in the tarball."; exit 1; }
ok "Files installed at $REPO_DIR"

# ---- 3. hand off to deploy.sh ----
say "Handing off to deploy.sh — it will open .env in nano for the secrets."
cd "$REPO_DIR"
exec bash ./deploy.sh