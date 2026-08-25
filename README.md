# server-setup

The containerised web stack for **hellyer.kiwi** (Nginx + PHP 8.5 + MariaDB +
Redis + Node), deployed with Podman. Everything needed to rebuild the server
lives in this repo.

## Install on a fresh Ubuntu server — one line

**First, point DNS:** create an `A` record `ionos.hellyer.kiwi` → this host's IP.
That's the one manual step (it lives in your DNS provider) — everything below is
automatic.

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install.sh \
  -o /tmp/install.sh && sudo bash /tmp/install.sh
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
   and **issues the real TLS cert for `ionos.hellyer.kiwi` automatically** (it
   checks DNS first — if DNS isn't propagated yet, it tells you exactly what to
   do and you just re-run `sudo ./deploy.sh`).

No further commands needed — visit `https://ionos.hellyer.kiwi` when the deploy
finishes.

## Manual path

```bash
sudo ./scripts/bootstrap.sh            # one-time host setup (packages + dirs)
mkdir -p /opt/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz | \
  tar -xz --strip-components=1 -C /opt/server-setup
cd /opt/server-setup
cp .env.example .env && nano .env      # deploy.sh does this for you automatically
sudo ./deploy.sh
```

## Day-to-day

| Thing | Command |
|---|---|
| Deploy / update the stack | `sudo ./deploy.sh` (refreshes files from the tarball, keeps `.env`) |
| Add a site | `sudo ./scripts/new-site.sh <domain> <type>` |
| Back up | `sudo ./scripts/backup.sh` (cron it) |
| Restore from backup | `sudo ./scripts/restore.sh` |
| Issue/renew TLS | `sudo ./scripts/certbot-issue.sh` |
| Run CLI tools on the host (php, composer, mariadb, ffmpeg...) | `./scripts/install-cli.sh` |
| See the full architecture & rebuild plan | [`PODMAN_PLAN.md`](PODMAN_PLAN.md) |