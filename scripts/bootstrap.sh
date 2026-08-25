#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — one-time host setup for a fresh Ubuntu server: installs the
# host packages + creates bind-mount dirs, then prints the next steps.
# Run once as root.
#
#   sudo ./scripts/bootstrap.sh
#
# (install.sh does all of this in one shot; bootstrap.sh just does the host
# half if you want to watch the steps.)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/host-setup.sh

echo
echo "Host bootstrap complete."
echo
echo "Next steps:"
echo "  Easiest — run the one-liner (installs packages, downloads files, deploys):"
echo "    curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/main/install.sh"
echo "      -o /tmp/install.sh && sudo bash /tmp/install.sh"
echo
echo "  Or manually (public repo — no git, no SSH keys needed):"
echo "    mkdir -p /opt/server-setup"
echo "    curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/main.tar.gz |"
echo "      tar -xz --strip-components=1 -C /opt/server-setup"
echo "    cd /opt/server-setup && cp .env.example .env && nano .env"
echo "    sudo ./deploy.sh"
echo "    sudo ./scripts/test-site.sh      # scaffold the ionos test page"
echo "    sudo ./scripts/certbot-issue.sh  # real TLS for ionos.hellyer.kiwi"