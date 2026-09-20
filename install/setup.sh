#!/usr/bin/env bash
# =============================================================================
# setup.sh — the ONE entry point for this repo. Everything admin runs from here.
#
# Single-line usage on a bare Ubuntu host (no docs, no keys, no git):
#
#   curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install/setup.sh \
#     -o /tmp/setup.sh && sudo bash /tmp/setup.sh
#
# Two modes, auto-detected:
#
#   * FRESH HOST (no repo installed — the curl|bash one-liner above):
#       1. Installs the host packages (podman, podman-compose, curl, openssl, nano...).
#       2. Downloads this whole repo as a tarball from GitHub (public repo — no
#          SSH keys needed) into /opt/server-setup and writes a .tarball marker
#          so deploy.sh can refresh the files the same way later.
#       3. Creates an admin user 'ryan' — key-based, with passwordless
#          sudo (scripts/create-admin-user.sh). SERVER_SETUP_ADMIN_KEY supplies
#          the caller's key when run via bootstrap.sh.
#       4. Re-execs the installed copy, which presents the menu.
#
#   * INSTALLED SERVER (repo found in the parent of this script's dir, or in
#     /opt/server-setup): Presents an interactive menu; each option delegates to
#     a script in scripts/ (sudo added only where the target needs root).
#
# Menu options delegate to existing scripts, so the automation path is unchanged:
#   sudo bash scripts/deploy.sh        # full deploy (cron/automation friendly)
#   sudo bash scripts/new-site.sh ...  # add a site without the menu
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }

# Read from /dev/tty so prompts work even when piped in via curl | bash.
tty_read() { read -r "$1" < /dev/tty || true; }

# ---- locate the repo: the parent of this script's dir, else the install dir ----
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ ! -x "$REPO_DIR/scripts/deploy.sh" ] && [ -x /opt/server-setup/scripts/deploy.sh ]; then
  REPO_DIR="/opt/server-setup"
fi

# =============================================================================
# FRESH HOST bootstrap
# =============================================================================
if [ ! -x "$REPO_DIR/scripts/deploy.sh" ]; then
  # ---- root ----
  if [ "$(id -u)" -ne 0 ]; then
    say "Not running as root — re-running with sudo."
    exec sudo bash "$0"
  fi

  echo
  echo "hellyer.kiwi server installer"
  echo "============================="
  echo

  # ---- host packages ----
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This installer needs an Ubuntu/Debian host (apt-get). Aborting."
    echo "To install a REMOTE server from your laptop, run: ./bootstrap.sh --host <ip>"
    exit 1
  fi

  say "Installing fetch tools (curl, tar, ca-certificates ...)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y curl tar ca-certificates
  ok "Fetch tools installed."

  # ---- download the files (no git, no keys) ----
  REPO_DIR="/opt/server-setup"
  TARBALL_URL="${SERVER_SETUP_TARBALL:-https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz}"
  say "Downloading the server-setup files from GitHub"
  mkdir -p "$REPO_DIR"
  # Resolve the live branch SHA first: SHA tarballs are immutable, so a
  # CDN-cached stale branch tarball is never used.
  sha=""
  if [[ "$TARBALL_URL" =~ ^https://github.com/([^/]+)/([^/]+)/archive/refs/heads/([^/]+)\.tar\.gz$ ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; branch="${BASH_REMATCH[3]}"
    sha="$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" 2>/dev/null \
      | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)"
    if [ -n "$sha" ]; then
      say "resolved $branch @ ${sha:0:7}"
      TARBALL_URL="https://github.com/$owner/$repo/archive/$sha.tar.gz"
    fi
  fi
  curl -fsSL "$TARBALL_URL" -o /tmp/server-setup.tar.gz
  tar -xzf /tmp/server-setup.tar.gz --strip-components=1 -C "$REPO_DIR"
  rm -f /tmp/server-setup.tar.gz

  # Remember how we were installed so deploy.sh can refresh the same way.
  # Store the refs/heads BRANCH URL (not the SHA-pinned URL we downloaded):
  # deploy.sh parses it to re-resolve the live SHA on every deploy. .last-sha
  # records what's actually applied so it can skip when nothing changed.
  printf '%s\n' "https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz" > "$REPO_DIR/.tarball"
  chmod 600 "$REPO_DIR/.tarball"
  [ -n "$sha" ] && printf '%s\n' "$sha" > "$REPO_DIR/.last-sha"

  [ -f "$REPO_DIR/install/setup.sh" ] || { echo "Download failed — no install/setup.sh found in the tarball."; exit 1; }
  ok "Files installed at $REPO_DIR"

  # Transition guard: this is a tarball install — drop any stale .git left by an
  # earlier git-clone install so deploy.sh stays in tarball refresh mode.
  if [ -d "$REPO_DIR/.git" ]; then
    say "Removing stale .git from an earlier git-clone install (tarball mode now)."
    rm -rf "$REPO_DIR/.git"
  fi

  # ---- admin user 'ryan' (shared with bootstrap.sh) ----
  # SERVER_SETUP_ADMIN_KEY lets a remote caller (bootstrap.sh) supply the
  # caller's own key. Fallback: the maintainer's key, so a bare `curl | bash`
  # install still ends up with passwordless SSH. No password is set on the
  # account — access is key-only, with passwordless sudo. Always done (no
  # prompt): a fresh host must have the admin user + key.
  DEFAULT_ADMIN_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEheqtRv6dkhK3KNjuCwxfKDgvZAEzNcnBt7fL/XQWGX ryanhellyer@gmail.com'
  ADMIN_USER=ryan \
    ADMIN_KEY="${SERVER_SETUP_ADMIN_KEY:-$DEFAULT_ADMIN_KEY}" \
    bash "$REPO_DIR/scripts/create-admin-user.sh"
  ok "Admin user 'ryan' ready (key-based, passwordless sudo)."

  # ---- full host setup: packages + bind-mount dirs + swap ----
  # (delegates to host-setup.sh so the package list lives in ONE place; also
  # runs apt-get upgrade and creates a swapfile on small boxes.)
  say "Running scripts/host-setup.sh (host packages, dirs, swap)"
  bash "$REPO_DIR/scripts/host-setup.sh"
  ok "Host packages installed."

  # ---- Hetzner storage-box access + mounts (asks for each box password once) ----
  # Always set up: authorises this server's key on both boxes and mounts the
  # u458814 gmail + databases shares under the admin user's home.
  bash "$REPO_DIR/scripts/hetzner-mounts.sh" \
    || say "Hetzner mounts not configured — use menu option 11 later."

  say "Re-running the installed copy to present the menu."
  cd "$REPO_DIR"
  exec bash "$REPO_DIR/install/setup.sh"
fi

# =============================================================================
# INSTALLED SERVER — interactive menu
# =============================================================================
cd "$REPO_DIR"
source scripts/lib-containers.sh

# ---- safety: setup.sh acts on the machine it RUNS on, never remotely ----
# The stack targets Ubuntu + systemd. If either is missing you're almost
# certainly on the wrong machine (e.g. a laptop), where a stray menu choice
# could install/modify local services. Point people at bootstrap.sh instead.
if [ "${SETUP_ALLOW_UNSUPPORTED:-0}" != "1" ]; then
  if ! command -v apt-get >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo
    echo "!! This host does not look like the target Ubuntu server (needs apt-get + systemd)."
    echo "!! setup.sh installs on THIS machine. To install a REMOTE server, run this"
    echo "!! from your laptop instead:"
    echo
    echo "!!     ./bootstrap.sh --host <server-ip>"
    echo
    echo "!! (If you really mean to run here, prefix with SETUP_ALLOW_UNSUPPORTED=1.)"
    exit 1
  fi
fi

# The menu is interactive — without a usable terminal, tell the caller to use
# the automation path instead of looping on failed reads. (Testing the node with
# `[ -e /dev/tty ]` is not enough: the node exists even with no controlling tty.)
if ! { : < /dev/tty; } 2>/dev/null; then
  echo "No terminal available (piped/automation). Run the scripts directly:"
  echo "  sudo bash scripts/deploy.sh"
  echo "  sudo bash scripts/new-site.sh <domain> <type>"
  exit 1
fi

show_menu() {
  echo
  echo "server-setup — what would you like to do?"
  echo "------------------------------------------"
  echo " 1) Full install / deploy / update the stack"
  echo " 2) Add a new site"
  echo " 3) Back up"
  echo " 4) Restore from backup"
  echo " 5) Issue / renew TLS certificates"
  echo " 6) Scaffold the ionos test site"
  echo " 7) Re-install systemd units"
  echo " 8) Install host CLI tools (php, composer, mariadb, ...)"
  echo " 9) Show stack status"
  echo "10) Tail container logs"
  echo "11) Connect the Hetzner Storage Boxes"
  echo "12) Harden SSH (disable password authentication)"
  echo " 0) Quit"
  echo
}

# Sub-menu: pick a container from ALL_CONTAINERS (for tailing logs).
pick_container() {
  local i
  echo
  for i in "${!ALL_CONTAINERS[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${ALL_CONTAINERS[$i]}"
  done
  echo "  0) back"
  echo
  local choice
  tty_read choice
  if [ "$choice" = "0" ]; then
    return 0
  fi
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ALL_CONTAINERS[@]}" ]; then
    echo "Invalid choice."; return 1
  fi
  podman logs -f --tail 100 "${ALL_CONTAINERS[$((choice - 1))]}"
}

# Sub-menu: add a new site (prompt domain + type, then delegate).
add_site() {
  local domain type target
  echo
  echo "Site types: laravel | wordpress | static | static-spa | redirect | node"
  printf 'Domain: '; tty_read domain
  [ -n "$domain" ] || { echo "Domain required."; return 1; }
  printf 'Type:   '; tty_read type
  case "$type" in
    laravel|wordpress|static|static-spa|redirect|node) ;;
    *) echo "Unknown type: $type"; return 1 ;;
  esac
  if [ "$type" = "redirect" ]; then
    printf 'Target (e.g. https://example.com$request_uri): '; tty_read target
    [ -n "$target" ] || { echo "Target required for redirect."; return 1; }
    sudo bash scripts/new-site.sh "$domain" "$type" "$target"
  else
    sudo bash scripts/new-site.sh "$domain" "$type"
  fi
}

while true; do
  show_menu
  printf 'Choose: '
  tty_read choice
  # A failing delegated script (e.g. aborted logs) must return to the menu,
  # not kill setup.sh — so drop errexit for the dispatch only.
  set +e
  case "$choice" in
    1) sudo bash scripts/deploy.sh ;;
    2) add_site ;;
    3) sudo bash scripts/backup.sh ;;
    4) sudo bash scripts/restore.sh ;;
    5) sudo bash scripts/certbot-issue.sh ;;
    6) sudo bash scripts/test-site.sh ;;
    7) sudo bash scripts/install-systemd.sh ;;
    8) bash scripts/install-cli.sh ;;
    9) podman ps ;;
    10) pick_container ;;
    11) sudo bash scripts/hetzner-mounts.sh ;;
    12) sudo bash scripts/harden-sshd.sh ;;
    0|q|quit) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
  set -e
done