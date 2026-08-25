# server-setup

The containerised web stack for **hellyer.kiwi** (Nginx + PHP 8.5 + MariaDB +
Redis + Node), deployed with Podman. Everything needed to rebuild the server
lives in this repo.

## Install on a fresh Ubuntu server — one line

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/main/install.sh \
  -o /tmp/install.sh && sudo bash /tmp/install.sh
```

That one command:

1. **Installs the host tools** (podman, podman-compose, curl, openssl, nano...).
2. **Downloads the whole repo as a tarball** from GitHub — the repo is public,
   so no SSH keys, no git, no GitHub console work are needed.
3. **Deploys** — it creates `.env` and opens it in **nano** for you to fill in
   secrets, builds the nginx + PHP images, brings up the whole stack, and
   installs systemd units so it starts at boot.

After that, point DNS `ionos.hellyer.kiwi` at the host and run:

```bash
cd /opt/server-setup
sudo ./scripts/test-site.sh      # scaffold the ionos test page
sudo ./scripts/certbot-issue.sh  # real TLS for ionos.hellyer.kiwi (test mode)
```

## Manual path

```bash
sudo ./scripts/bootstrap.sh            # one-time host setup (packages + dirs)
mkdir -p /opt/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/main.tar.gz | \
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