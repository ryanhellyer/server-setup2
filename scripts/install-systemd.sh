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
# It also installs systemd timers for the scheduled jobs: `server-backup.timer`
# (nightly 03:00) and `certbot-renew.timer` (2x/day), so backups + TLS renewal
# happen automatically.
#
# Re-run anytime (idempotent) — e.g. after `compose up` recreates a container.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh

command -v systemctl >/dev/null 2>&1 || { echo "systemd not present — skipping."; exit 0; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./scripts/install-systemd.sh)."; exit 1; }

# Containers compose creates (defined once in lib-containers.sh).
CONTAINERS=("${ALL_CONTAINERS[@]}")

SYSTEMD_DIR=/etc/systemd/system

# Ensure the stack is up so units can be generated from live containers.
if podman compose version >/dev/null 2>&1; then
  podman compose up -d
else
  podman-compose up -d
fi

for c in "${CONTAINERS[@]}"; do
  if ! podman container exists "$c" 2>/dev/null; then
    echo "  (container '$c' not running yet — skipping its unit; re-run after compose up)"
    continue
  fi
  echo "==> Generating systemd unit for $c"
  # Note: `--files` writes to the CURRENT directory, not to $SYSTEMD_DIR, so
  # the unit must be redirected explicitly or `systemctl enable` below fails.
  podman generate systemd --name "$c" > "$SYSTEMD_DIR/container-$c.service"
done

# nginx depends on the shared FPM socket: start it after php-fpm/node.
OVERRIDE="$SYSTEMD_DIR/container-$CONTAINER_NGINX.service.d/order.conf"
mkdir -p "$(dirname "$OVERRIDE")"
cat > "$OVERRIDE" <<EOF
[Unit]
After=container-$CONTAINER_PHP_FPM.service container-$CONTAINER_NODE.service
Wants=container-$CONTAINER_PHP_FPM.service container-$CONTAINER_NODE.service
EOF

systemctl daemon-reload

for c in "${CONTAINERS[@]}"; do
  if ! podman container exists "$c" 2>/dev/null; then
    continue
  fi
  echo "==> Enabling container-$c.service"
  systemctl enable "container-$c.service" >/dev/null 2>&1
  systemctl start "container-$c.service" 2>/dev/null || true
done

# ---- scheduled jobs: nightly backup + TLS renewal (systemd timers) ----
# Installed automatically on every deploy so nothing depends on an admin
# remembering to cron them. Idempotent — unit files are overwritten and the
# timers re-enabled. `enable --now` on a .timer only arms the schedule
# (OnCalendar); it does NOT run the oneshot service immediately.
write_job() { # "$1" name, "$2" service desc, "$3" exec, "$4" timer desc, "$5" OnCalendar, "$6" delay
  local name="$1" sdesc="$2" exec="$3" tdesc="$4" cal="$5" delay="$6"
  cat > "$SYSTEMD_DIR/$name.service" <<EOF
[Unit]
Description=$sdesc
After=network-online.target

[Service]
Type=oneshot
ExecStart=$exec
EOF
  cat > "$SYSTEMD_DIR/$name.timer" <<EOF
[Unit]
Description=$tdesc

[Timer]
OnCalendar=$cal
RandomizedDelaySec=$delay

[Install]
WantedBy=timers.target
EOF
}

# Backup nightly at 03:00 (staggered up to 15 min).
write_job "server-backup" \
  "server-setup nightly backup" \
  "/bin/bash $PWD/scripts/backup.sh" \
  "run the server-setup nightly backup" \
  "*-*-* 03:00:00" "15m"

# TLS renewal twice a day (Let's Encrypt recommendation); certbot only renews
# when a cert has <30 days left, so this never hits rate limits.
write_job "certbot-renew" \
  "server-setup TLS certificate renewal" \
  "/bin/bash $PWD/scripts/certbot-issue.sh" \
  "run the server-setup TLS certificate renewal" \
  "*-*-* 00,12:00:00" "30m"

echo "==> Enabling scheduled jobs (nightly backup + TLS renewal)"
systemctl daemon-reload
systemctl enable --now server-backup.timer certbot-renew.timer

echo
echo "Systemd units installed and enabled. The stack will start at boot:"
echo "  systemctl list-units 'container-*.service'"
echo "Scheduled jobs (timers):"
echo "  systemctl list-timers 'server-backup.timer' 'certbot-renew.timer'"