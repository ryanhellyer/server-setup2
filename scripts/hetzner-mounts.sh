#!/usr/bin/env bash
# =============================================================================
# hetzner-mounts.sh — set up passwordless SSH to BOTH Hetzner Storage Boxes
# and mount the u458814 box's /home/gmail and /home/databases into the admin
# user's home via sshfs.
#
#   sudo bash scripts/hetzner-mounts.sh
#
# What it does:
#   1. Generates a dedicated ed25519 key on this server if one is missing.
#   2. Installs that key's public half on BOTH boxes (u458814 + u513410), so
#      connecting to either never asks for a password. This asks for each box's
#      password ONCE during setup. Existing keys on the boxes are PRESERVED —
#      Hetzner's `install-ssh-key` appends, it never replaces.
#   3. Writes /etc/fstab entries for the u458814 mounts only (_netdev,
#      x-systemd.automount, reconnect) so they return after a reboot, then
#      mounts them now. The u513410 box is authorised but NOT mounted.
#
# Config (override in .env, all optional):
#   HETZNER_PRESSABL_HOST   default u458814.your-storagebox.de
#   HETZNER_PRESSABL_USER   default u458814
#   HETZNER_SECONDARY_HOST  default u513410.your-storagebox.de
#   HETZNER_SECONDARY_USER  default u513410
#   HETZNER_SSH_PORT        default 23 (both boxes)
#   HETZNER_MOUNT_HOME      default: home of the invoking user (~)
#   HETZNER_MOUNT_USER      default: $SUDO_USER, else ryan, else current user
#   HETZNER_IDENTITY_FILE   default: $HETZNER_MOUNT_HOME/.ssh/hetzner_ed25519
# =============================================================================
set -euo pipefail
SELF="$(readlink -f "$0")"
cd "$(dirname "$SELF")/.."

# ---- root is needed to write /etc/fstab and mount sshfs system-wide ----
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$SELF" "$@"
fi

[ -f .env ] && set -a && source .env && set +a

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

PORT="${HETZNER_SSH_PORT:-23}"

PRESSABL_HOST="${HETZNER_PRESSABL_HOST:-u458814.your-storagebox.de}"
PRESSABL_USER="${HETZNER_PRESSABL_USER:-u458814}"
SECONDARY_HOST="${HETZNER_SECONDARY_HOST:-u513410.your-storagebox.de}"
SECONDARY_USER="${HETZNER_SECONDARY_USER:-u513410}"

# Both boxes get the key; only the pressabl box gets mounts.
BOXES=("$PRESSABL_USER@$PRESSABL_HOST" "$SECONDARY_USER@$SECONDARY_HOST")
# mount spec: "user@host:remote-dir  local-folder-name"
MOUNT_SPECS=("$PRESSABL_USER@$PRESSABL_HOST:/home/gmail gmail" \
             "$PRESSABL_USER@$PRESSABL_HOST:/home/databases databases")

# ---- where to mount: the invoking user's home (~) ----
resolve_mount_user() {
  if [ -n "${HETZNER_MOUNT_USER:-}" ]; then printf '%s' "$HETZNER_MOUNT_USER"; return; fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then printf '%s' "$SUDO_USER"; return; fi
  if id ryan >/dev/null 2>&1; then printf '%s' "ryan"; return; fi
  id -un
}
MOUNT_USER="$(resolve_mount_user)"
MOUNT_HOME="${HETZNER_MOUNT_HOME:-$(getent passwd "$MOUNT_USER" | cut -d: -f6)}"
[ -n "$MOUNT_HOME" ] || { warn "Could not resolve a home directory for '$MOUNT_USER'."; exit 1; }
MOUNT_UID="$(id -u "$MOUNT_USER")"
MOUNT_GID="$(id -g "$MOUNT_USER")"
KEY="${HETZNER_IDENTITY_FILE:-$MOUNT_HOME/.ssh/hetzner_ed25519}"

# ---- packages ----
if ! command -v sshfs >/dev/null 2>&1; then
  say "Installing sshfs"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y sshfs
fi

# FUSE only honours `allow_other` when it is enabled in /etc/fuse.conf.
if [ -f /etc/fuse.conf ] && ! grep -qs '^[[:space:]]*user_allow_other' /etc/fuse.conf; then
  printf '\nuser_allow_other\n' >> /etc/fuse.conf
fi

# ---- keypair ----
SSH_DIR="$(dirname "$KEY")"
install -d -m 700 "$SSH_DIR"
chown "$MOUNT_UID:$MOUNT_GID" "$SSH_DIR" 2>/dev/null || true
if [ ! -f "$KEY" ]; then
  say "Generating SSH key for the Storage Boxes: $KEY"
  ssh-keygen -t ed25519 -N '' -C "server-setup hetzner" -f "$KEY" >/dev/null
  chmod 600 "$KEY"
  chmod 644 "$KEY.pub"
  chown "$MOUNT_UID:$MOUNT_GID" "$KEY" "$KEY.pub" 2>/dev/null || true
fi

key_works() { # "$1" user@host
  ssh -i "$KEY" -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
      -o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new \
      "$1" ls >/dev/null 2>&1
}

install_key() { # "$1" user@host
  local target="$1"
  if key_works "$target"; then
    ok "Passwordless SSH to $target already works."
    return 0
  fi
  if [ ! -e /dev/tty ]; then
    warn "A terminal is needed to enter the Storage Box password exactly once."
    warn "Re-run from an interactive shell: sudo bash scripts/hetzner-mounts.sh"
    return 1
  fi
  say "Installing this server's public key on $target"
  say "You will be asked for that box's password ONCE. Existing keys are kept."
  if cat "$KEY.pub" | ssh -p "$PORT" -o StrictHostKeyChecking=accept-new \
       "$target" install-ssh-key; then
    :
  elif command -v ssh-copy-id >/dev/null 2>&1 \
       && ssh-copy-id -p "$PORT" -s -i "$KEY.pub" "$target"; then
    :
  else
    warn "Automatic key install failed for $target."
    warn "Add this public key to that box's /home/.ssh/authorized_keys (OpenSSH"
    warn "format) by hand, then re-run:"
    printf '\n    %s\n\n' "$(cat "$KEY.pub")"
    return 1
  fi
  if key_works "$target"; then
    ok "Passwordless SSH to $target is working."
    return 0
  fi
  warn "The key was installed on $target but passwordless login still fails."
  warn "Check that SSH support is enabled for that Storage Box in the Hetzner Console."
  return 1
}

# ---- 1. passwordless auth on BOTH boxes ----
for target in "${BOXES[@]}"; do
  install_key "$target" || exit 1
done

# ---- 2. /etc/fstab: persistent automounts for the pressabl box (idempotent) ----
FSTAB=/etc/fstab
BEGIN='# BEGIN server-setup hetzner mounts'
END='# END server-setup hetzner mounts'
[ -f "$FSTAB.server-setup.bak" ] || cp "$FSTAB" "$FSTAB.server-setup.bak"

OPTS="_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=60,IdentityFile=$KEY,port=$PORT,uid=$MOUNT_UID,gid=$MOUNT_GID,allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,StrictHostKeyChecking=accept-new"

TMP="$(mktemp)"
if grep -qsF "$BEGIN" "$FSTAB"; then
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$FSTAB" > "$TMP"
else
  cp "$FSTAB" "$TMP"
fi
{
  printf '%s\n' "$BEGIN"
  for spec in "${MOUNT_SPECS[@]}"; do
    printf '%s %s/%s fuse.sshfs %s 0 0\n' "${spec%% *}" "$MOUNT_HOME" "${spec##* }" "$OPTS"
  done
  printf '%s\n' "$END"
} >> "$TMP"
cat "$TMP" > "$FSTAB"
rm -f "$TMP"
say "Updated $FSTAB (backup: $FSTAB.server-setup.bak)"

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi

# ---- 3. mount now ----
for spec in "${MOUNT_SPECS[@]}"; do
  connection="${spec%% *}"   # user@host:/remote/dir
  name="${spec##* }"         # local folder name
  local_dir="$MOUNT_HOME/$name"

  if mountpoint -q "$local_dir" 2>/dev/null; then
    ok "Already mounted: $local_dir"
    continue
  fi

  mkdir -p "$local_dir"
  chown "$MOUNT_UID:$MOUNT_GID" "$local_dir" 2>/dev/null || true

  say "Mounting $connection -> $local_dir"
  mounted=0
  if command -v systemctl >/dev/null 2>&1; then
    # Start the automount unit and touch the path to trigger the actual mount.
    systemctl restart "$(systemd-escape -p --suffix=automount "$local_dir")" >/dev/null 2>&1 || true
    ls "$local_dir" >/dev/null 2>&1 || true
    mountpoint -q "$local_dir" && mounted=1
  fi
  if [ "$mounted" -eq 0 ]; then
    if sshfs "$connection" "$local_dir" -p "$PORT" \
        -o "IdentityFile=$KEY,uid=$MOUNT_UID,gid=$MOUNT_GID,allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,StrictHostKeyChecking=accept-new"; then
      mounted=1
    fi
  fi

  if [ "$mounted" -eq 1 ]; then
    ok "Mounted $local_dir"
  else
    warn "Could not mount $local_dir."
    warn "Check the Storage Box is reachable, then re-run: sudo bash scripts/hetzner-mounts.sh"
  fi
done

echo
echo "Done. Passwordless access to both boxes; u458814 gmail+databases mounted under $MOUNT_HOME."
echo "Mounts are in /etc/fstab and reappear automatically after reboot."
