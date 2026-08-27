#!/usr/bin/env bash
# =============================================================================
# setup.sh — the ONE entry point for this repo. Everything admin runs from here.
#
# Single-line usage on a bare Ubuntu host (no docs, no keys, no git):
#
#   curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/setup.sh \
#     -o /tmp/setup.sh && sudo bash /tmp/setup.sh
#
# Two modes, auto-detected:
#
#   * FRESH HOST (no repo installed — the curl|bash one-liner above):
#       1. Installs the host packages (podman, podman-compose, curl, openssl, nano...).
#       2. Prompts to create an admin user 'ryan' with sudo privileges.
#       3. Downloads this whole repo as a tarball from GitHub (public repo — no
#          SSH keys needed) into /opt/server-setup and writes a .tarball marker
#          so deploy.sh can refresh the files the same way later.
#       4. Re-execs the installed copy, which presents the menu.
#
#   * INSTALLED SERVER (repo found next to this script, or in /opt/server-setup):
#       Presents an interactive menu; each option delegates to a script in
#       scripts/ (sudo added only where the target needs root).
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

ask_yn() { # "$1" prompt; returns 0 on yes, 1 on no (default: yes)
  local ans
  if [ -e /dev/tty ]; then
    read -r -p "$1 [Y/n] " ans < /dev/tty
  else
    read -r -p "$1 [Y/n] " ans
  fi
  case "${ans,,}" in
    n|no) return 1 ;;
    *)    return 0 ;;
  esac
}

# ---- locate the repo: this script's dir, else the canonical install dir ----
REPO_DIR="$SCRIPT_DIR"
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
    exit 1
  fi

  say "Installing fetch tools (curl, tar, ca-certificates ...)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y curl tar ca-certificates
  ok "Fetch tools installed."

  # ---- admin user ----
  if ask_yn "Create admin user 'ryan' with sudo privileges?"; then
    if id ryan >/dev/null 2>&1; then
      say "User 'ryan' already exists — ensuring sudo."
      usermod -aG sudo ryan
    else
      say "Creating user 'ryan'."
      useradd -m -s /bin/bash ryan
      usermod -aG sudo ryan
      echo
      echo "Set a password for 'ryan' (needed for sudo)."
      passwd ryan
    fi
    ok "User 'ryan' has sudo privileges."

    # ---- SSH key for passwordless login ----
    say "Installing SSH public key for 'ryan'."
    install -d -o ryan -g "$(id -gn ryan)" -m 700 /home/ryan/.ssh
    touch /home/ryan/.ssh/authorized_keys
    chmod 600 /home/ryan/.ssh/authorized_keys
    chown ryan:"$(id -gn ryan)" /home/ryan/.ssh/authorized_keys
    grep -qs 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEheqtRv6dkhK3KNjuCwxfKDgvZAEzNcnBt7fL/XQWGX' \
      /home/ryan/.ssh/authorized_keys \
      || echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEheqtRv6dkhK3KNjuCwxfKDgvZAEzNcnBt7fL/XQWGX ryanhellyer@gmail.com' >> /home/ryan/.ssh/authorized_keys
    ok "SSH key installed for passwordless login."
  fi

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

  [ -f "$REPO_DIR/setup.sh" ] || { echo "Download failed — no setup.sh found in the tarball."; exit 1; }
  ok "Files installed at $REPO_DIR"

  # Transition guard: this is a tarball install — drop any stale .git left by an
  # earlier git-clone install so deploy.sh stays in tarball refresh mode.
  if [ -d "$REPO_DIR/.git" ]; then
    say "Removing stale .git from an earlier git-clone install (tarball mode now)."
    rm -rf "$REPO_DIR/.git"
  fi

  # ---- full host setup: packages + bind-mount dirs + swap ----
  # (delegates to host-setup.sh so the package list lives in ONE place; also
  # runs apt-get upgrade and creates a swapfile on small boxes.)
  say "Running scripts/host-setup.sh (host packages, dirs, swap)"
  bash "$REPO_DIR/scripts/host-setup.sh"
  ok "Host packages installed."

  say "Re-running the installed copy to present the menu."
  cd "$REPO_DIR"
  exec bash "$REPO_DIR/setup.sh"
fi

# =============================================================================
# INSTALLED SERVER — interactive menu
# =============================================================================
cd "$REPO_DIR"
source scripts/lib-containers.sh

# The menu is interactive — without a terminal, tell the caller to use the
# automation path instead of looping on failed reads.
if [ ! -e /dev/tty ]; then
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
    0|q|quit) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
  set -e
done