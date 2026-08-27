#!/usr/bin/env bash
# =============================================================================
# host-setup.sh — install the (small) host package set and create the
# bind-mount directories. Run once as root.
#
# Called by:
#   - setup.sh (fresh-host one-time setup)
#   - deploy.sh    (automatically, when podman/podman-compose are missing)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
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

echo "==> adding admin user to www-data group (shared web-write model)"
if id ryan >/dev/null 2>&1; then
  usermod -aG www-data ryan
fi

# Small boxes: ensure swap so memory pressure doesn't OOM/thrash.
bash scripts/ensure-swap.sh

echo "==> installing Starship prompt (host shell)"
if ! command -v starship >/dev/null 2>&1; then
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin
fi

# Seed the config + init for future users, then apply to the existing
# interactive users (root + the admin user). Idempotent: the bashrc append
# is guarded so re-runs (deploy.sh calls host-setup.sh) don't duplicate it.
install -D -m 644 config/starship.toml /etc/skel/.config/starship.toml
grep -qs 'starship init bash' /etc/skel/.bashrc \
  || echo 'eval "$(starship init bash)"' >> /etc/skel/.bashrc

for user in root ryan; do
  home="$(getent passwd "$user" | cut -d: -f6)" || continue
  [ -d "$home" ] || continue
  install -D -o "$user" -g "$(id -gn "$user")" -m 644 \
    config/starship.toml "$home/.config/starship.toml"
  grep -qs 'starship init bash' "$home/.bashrc" \
    || echo 'eval "$(starship init bash)"' >> "$home/.bashrc"
done

# Group-write umask so files ryan creates in the web dirs stay editable by the
# www-data containers (matches the fpm `umask = 0002`).
if id ryan >/dev/null 2>&1; then
  home="$(getent passwd ryan | cut -d: -f6)" || true
  if [ -n "$home" ] && [ -d "$home" ]; then
    grep -qs '^umask 002' "$home/.bashrc" || echo 'umask 002' >> "$home/.bashrc"
  fi
fi

# ---- SSH key for the Hetzner storage box (site imports / backups) ----
# The PUBLIC key must be added to the box once, by hand:
#   Hetzner Robot -> Storage Box -> select the box -> SSH keys -> paste it.
# (Or one-time: sftp -P 23 u<id>@u<id>.your-storagebox.de and place the .pub
# in ~/.ssh/authorized_keys.) Until then, scripts/sync-site.sh can't connect.
if id ryan >/dev/null 2>&1; then
  HETZNER_SSH_DIR="/home/ryan/.ssh"
  HETZNER_KEY_OWNER="ryan:ryan"
else
  HETZNER_SSH_DIR="/root/.ssh"
  HETZNER_KEY_OWNER="root:root"
fi
install -d -m 700 -o "$(echo "$HETZNER_KEY_OWNER" | cut -d: -f1)" -g "$(echo "$HETZNER_KEY_OWNER" | cut -d: -f2)" "$HETZNER_SSH_DIR"
if [ ! -f "$HETZNER_SSH_DIR/hetzner_backup" ]; then
  echo "==> generating SSH key for the Hetzner storage box"
  ssh-keygen -q -t ed25519 -N "" -C "server-setup@$(hostname)" -f "$HETZNER_SSH_DIR/hetzner_backup"
  chown "$HETZNER_KEY_OWNER" "$HETZNER_SSH_DIR/hetzner_backup" "$HETZNER_SSH_DIR/hetzner_backup.pub"
  echo
  echo "  ****************************************************************"
  echo "  * ONE-TIME MANUAL STEP: authorize this key on the Hetzner box. *"
  echo "  *                                                            *"
  cat "$HETZNER_SSH_DIR/hetzner_backup.pub"
  echo "  *                                                            *"
  echo "  * Hetzner Robot -> Storage Box -> SSH keys -> paste the key. *"
  echo "  * (or: sftp -P 23 u<id>@u<id>.your-storagebox.de and place   *"
  echo "  *       the .pub into ~/.ssh/authorized_keys)                *"
  echo "  ****************************************************************"
  echo
fi

echo "Host packages installed."