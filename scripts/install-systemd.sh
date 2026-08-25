#!/usr/bin/env bash
# =============================================================================
# install-systemd.sh — make the compose-managed containers start at boot and be
# supervised by systemd. Run as root; deploy.sh calls it automatically.
#
# For each container it generates a `container-<name>.service` with
# `podman generate systemd` (start/stop the EXISTING container, so it stays
# compatible with compose, which remains the source of truth), enables it, and
# adds ordering so nginx starts after the FPM socket provider (php-fpm).
#
# Re-run anytime (idempotent) — e.g. after `compose up` recreates a container.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

command -v systemctl >/dev/null 2>&1 || { echo "systemd not present — skipping."; exit 0; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./scripts/install-systemd.sh)."; exit 1; }

# Containers compose creates (must match compose.yaml service names).
CONTAINERS=(nginx php-fpm mariadb redis node)

SYSTEMD_DIR=/etc/systemd/system

# Ensure the stack is up so units can be generated from live containers.
if podman compose version >/dev/null 2>&1; then
  podman compose up -d
else
  podman-compose up -d
fi

for c in "${CONTAINERS[@]}"; do
  echo "==> Generating systemd unit for $c"
  if ! podman generate systemd --name "$c" --files >/dev/null 2>&1; then
    podman generate systemd --name "$c" > "$SYSTEMD_DIR/container-$c.service"
  fi
done

# nginx depends on the shared FPM socket: start it after php-fpm/node.
OVERRIDE="$SYSTEMD_DIR/container-nginx.service.d/order.conf"
mkdir -p "$(dirname "$OVERRIDE")"
cat > "$OVERRIDE" <<'EOF'
[Unit]
After=container-php-fpm.service container-node.service
Wants=container-php-fpm.service container-node.service
EOF

systemctl daemon-reload

for c in "${CONTAINERS[@]}"; do
  echo "==> Enabling container-$c.service"
  systemctl enable "container-$c.service" >/dev/null 2>&1
  systemctl start "container-$c.service" 2>/dev/null || true
done

echo
echo "Systemd units installed and enabled. The stack will start at boot:"
echo "  systemctl list-units 'container-*.service'"