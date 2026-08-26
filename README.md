# server-setup

The containerised web stack for **hellyer.kiwi** (Nginx + PHP 8.5 + MariaDB +
Redis + Node), deployed with Podman. Everything needed to rebuild the server
lives in this repo.

## Install on a fresh Ubuntu server — one line

**First, point DNS:** create an `A` record `ionos.hellyer.kiwi` → this host's IP.
That's the one manual step (it lives in your DNS provider) — everything below is
automatic.

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/setup.sh \
  -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

That one command:

1. **Installs the host tools** (podman, podman-compose, curl, openssl, nano...).
2. **Prompts to create an admin user `ryan`** with sudo privileges (skips it if
   the user already exists).
3. **Downloads the whole repo as a tarball** from GitHub — the repo is public,
   so no SSH keys, no git, no GitHub console work are needed.
4. **Opens the firewall ports** 22/80/443 (added automatically; harmless if ufw
   is off).
5. **Deploys** — creates `.env` and opens it in **nano** for you to fill in
   secrets, builds the nginx + PHP images, brings up the whole stack (nginx,
   php-fpm, mariadb, redis, node), installs systemd units so it starts at boot,
   schedules the **nightly backup** and **TLS renewal** (systemd timers, no
   cron needed), and **issues the real TLS cert for `ionos.hellyer.kiwi`
   automatically** (it checks DNS first — if DNS isn't propagated yet, it tells
   you exactly what to do and you just re-run `sudo ./setup.sh`).

No further commands needed — visit `https://ionos.hellyer.kiwi` when the deploy
finishes.

## Everything else: `sudo ./setup.sh`

`setup.sh` is the one script to remember. On the server it shows an interactive
menu that delegates to the scripts in `scripts/`:

- **1)** full deploy / update the stack
- **2)** add a new site
- **3)** back up
- **4)** restore from backup
- **5)** issue / renew TLS certificates
- **6)** scaffold the ionos test site
- **7)** re-install systemd units
- **8)** install host CLI tools (php, composer, mariadb, ...)
- **9)** show stack status
- **10)** tail container logs

## Manual path

```bash
sudo ./scripts/bootstrap.sh            # one-time host setup (packages + dirs)
mkdir -p /opt/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz | \
  tar -xz --strip-components=1 -C /opt/server-setup
cd /opt/server-setup
cp .env.example .env && nano .env      # scripts/deploy.sh does this for you automatically
sudo ./setup.sh                        # menu: pick "Full install / deploy / update"
```

## Day-to-day

| Thing | Command |
|---|---|
| Everything (menu: deploy, add a site, backup, restore, certs...) | `sudo ./setup.sh` |
| Deploy / update the stack (no menu) | `sudo bash scripts/deploy.sh` (refreshes files from the tarball, keeps `.env`) |
| Add a site (no menu) | `sudo bash scripts/new-site.sh <domain> <type>` |
| Back up | `sudo bash scripts/backup.sh` |
| Restore from backup | `sudo bash scripts/restore.sh` |
| Issue/renew TLS | `sudo bash scripts/certbot-issue.sh` |
| Run CLI tools on the host (php, composer, mariadb, ffmpeg...) | `bash scripts/install-cli.sh` |
| See the full architecture & rebuild plan | [`PODMAN_PLAN.md`](PODMAN_PLAN.md) |

## Scheduled jobs (automatic)

No cron is needed — `scripts/deploy.sh` installs systemd timers on every
install/deploy:

| Job | Schedule | Runs |
|---|---|---|
| Nightly backup | daily 03:00 | `scripts/backup.sh` |
| TLS renewal | 2×/day (renews only when <30 days left) | `scripts/certbot-issue.sh` |

Check them with `systemctl list-timers 'server-backup.timer' 'certbot-renew.timer'`.

> **Note:** `scripts/backup.sh` is a **work in progress** — it's a simple
> "mysqldump everything + tar `/var/www`" script and needs upgrading to match
> the real production backup system. The current real backup system from the
> main site lives in [`temp-backup/`](temp-backup/) (`backup.sh`,
> `backup-config.sh`, `backups/`) — use it as the reference to build the real
> new backup system. Until then, treat `scripts/backup.sh` as a starting
> point, not the final backup solution.