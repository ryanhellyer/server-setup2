# server-setup

The containerised web stack for **hellyer.kiwi** (Nginx + PHP 8.5 + MariaDB +
Valkey + Node), deployed with Podman. Everything needed to rebuild the server
lives in this repo.

## Install on a fresh Ubuntu server — one line

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install/setup.sh \
  -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

That one command is fully hands-off after the two prompt types below:

1. **Installs the host tools** (podman, podman-compose, curl, openssl, nano...) plus the
   **Starship prompt** (config in `config/starship.toml`).
2. **Creates an admin user `ryan`** with your SSH key and passwordless `sudo`
   (key-only; `scripts/create-admin-user.sh`).
3. **Downloads the repo as a tarball** from GitHub (public — no git/keys needed).
4. **Opens the firewall ports** 22/80/443.
5. **Generates a standard storage key** (`~/.ssh/id_ed25519`) and authorises it on
   both storage boxes, then mounts `gmail`/`databases` under `ryan`'s home.
6. **Deploys automatically** — creates `.env` with a generated MariaDB root
   password (no editor), builds the images, brings up the whole stack, installs
   systemd units + the nightly-backup/TLS-renewal timers, then **imports every
   site (files + databases, each with its own DB user) and the Open WebUI data**
   from the newest storage snapshot.
7. **Issues real TLS** for the domains in `CERTBOT_DOMAINS_FILE` (test mode: the
   test domain(s)); this needs DNS pointed at the host first.

The only manual bits: **point DNS** at this host, and type each **storage box
password once** when asked (to authorise the key).

> **Where does each script run?** `install/setup.sh` (and `deploy.sh`) install on the
> machine they are **executed on** — they do not touch anything remote. Run
> `install/setup.sh` **on the server**. To install a *remote* server from your laptop,
> use `bootstrap.sh` below. (Both refuse to run on a host without `apt-get` +
> `systemd`, so a stray `install/setup.sh` on your laptop won't install anything.)

## Install / manage a remote server from your laptop

`bootstrap.sh` provisions and drives a server over SSH from your own machine.
Hetzner ships boxes with password auth, so the first contact uses the password
**once**; the script then installs your public key, creates the admin user, and
disables password auth.

```bash
./bootstrap.sh --host 203.0.113.10        # provision, then open the on-server menu
./bootstrap.sh --host box.example.com --no-harden
```

What it does, in order:

1. Installs your key for the login user (default `root`) — one password prompt.
2. Creates `ryan` with the same key and `NOPASSWD` sudo
   (`scripts/create-admin-user.sh`).
3. Hardens sshd — `PasswordAuthentication no`, `PermitRootLogin
   prohibit-password` (`scripts/harden-sshd.sh`). It refuses to run unless a key
   is already installed for `root` or `ryan`, so it can't lock you out.
4. Runs the installer: the fresh-host bootstrap on a new box, or the on-server
   menu if the repo is already at `/opt/server-setup`.

Flags: `--user`, `--admin-user`, `--port`, `--identity`, `--install`,
`--no-harden`. The password is entered by `ssh` and never stored.

> Changed your mind? `sudo bash scripts/harden-sshd.sh --revert` restores
> password authentication.

## Everything else: `sudo ./install/setup.sh`

`install/setup.sh` is the one script to remember. On the server it shows an interactive
menu that delegates to the scripts in `scripts/`:

- **1)** full deploy / update the stack
- **2)** add a new site
- **3)** back up
- **4)** restore from backup
- **5)** issue / renew TLS certificates
- **6)** re-install systemd units
- **7)** install host CLI tools (php, composer, mariadb, ...)
- **8)** show stack status
- **9)** tail container logs
- **10)** connect the storage boxes (passwordless key + `gmail`/`databases` mounts)
- **11)** harden SSH (disable password authentication)

## Manual path

```bash
sudo ./scripts/host-setup.sh          # one-time host setup (packages + dirs + swap)
mkdir -p /opt/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz | \
  tar -xz --strip-components=1 -C /opt/server-setup
cd /opt/server-setup
cp .env.example .env      # scripts/deploy.sh does this (with generated secrets) automatically
sudo ./install/setup.sh                 # menu: pick "Full install / deploy / update"
```

> **Config templates:** `nginx/nginx.conf`, `php/fpm-www.conf` and `maria/my.cnf`
> are generated from their `.template` files by `scripts/render-config.sh` on
> every deploy (values from `.env`). They're not committed — edit the `.template`
> files instead. A fresh `podman compose up` without a prior deploy won't find
> them, so always go through `scripts/deploy.sh` first.

## Day-to-day

| Thing | Command |
|---|---|
| Everything (menu: deploy, add a site, backup, restore, certs...) | `sudo ./install/setup.sh` |
| Deploy / update the stack (no menu) | `sudo bash scripts/deploy.sh` (refreshes files from the tarball, keeps `.env`) |
| Refresh images + container OS packages (no data changes) | `sudo bash scripts/update.sh` (weekly `server-update.timer`) |
| Add a site (no menu) | `sudo bash scripts/new-site.sh <domain> <type>` |
| Back up | `sudo bash scripts/backup.sh` |
| Restore from backup | `sudo bash scripts/restore.sh` |
| Issue/renew TLS | `sudo bash scripts/certbot-issue.sh` |
| Fix web-dir ownership + permissions (ryan:www-data, setgid) | `sudo bash scripts/fix-perms.sh` (re-run after `restore.sh`) |
| Import every site + DB + Open WebUI (always fresh) | `sudo bash scripts/provision-all.sh` (auto-run by `deploy.sh`) |
| Restore one site fully (files + DB) | `sudo bash scripts/provision-site.sh <snapshot-dir> [--to <dir>]` |
| Restore every site found in the snapshot | `sudo bash scripts/migrate-sites.sh [--dry-run]` |
| Connect the storage boxes + mount `gmail`, `databases` | `sudo bash scripts/storage-mounts.sh` |
| Create/refresh the admin user (`ryan`) with a key + passwordless sudo | `sudo bash scripts/create-admin-user.sh` |
| Harden SSH (keys only) / revert | `sudo bash scripts/harden-sshd.sh [--revert]` |
| Provision/install a remote server, or open its menu over SSH | `./bootstrap.sh --host <ip>` |
| Run CLI tools on the host (php, composer, mariadb, ffmpeg...) | `bash scripts/install-cli.sh` |
| Open a terminal in a container (defaults to the PHP box) | `pod-login [container]` |
| Install / remove the SSH login helper banner | `sudo bash scripts/install-login-help.sh [--remove]` |
| Re-apply host packages / Starship / swap / firewall / fail2ban / journald cap | `sudo bash scripts/host-setup.sh` |
| See the full architecture & rebuild plan | [`PODMAN_PLAN.md`](PODMAN_PLAN.md) |

### Host helper commands

`scripts/install-cli.sh` (run by `deploy.sh`, or menu item 7) drops wrappers into
the admin user's `~/.local/bin` — the php/composer/mariadb/... commands above,
plus these container helpers:

| Command | What it does |
|---|---|
| `pod-login [container]` | interactive shell (default `php-fpm`); mirrors cwd, auto-sudo, `-u user` |
| `pod-logs [container] [-f] [-n N]` | print / follow a container's logs (default `php-fpm`) |
| `pod-status` | fixed-order stack state + health table; exits non-zero if degraded |
| `pod-restart <container>` / `--all [-y]` | restart one container or the whole stack |
| `sites` | list the sites under `~/www` with their type and database |
| `cert-status` | TLS certificate domains + expiry (offline, via `openssl`) |

```bash
pod-login                 # root shell in php-fpm (the main PHP box)
pod-login mariadb         # root shell in the database container
pod-login -u www-data php-fpm   # as www-data, so files stay owned correctly
pod-login --list          # show the running stack containers
pod-logs nginx -f         # follow the web-server logs
pod-restart --all         # restart the whole stack
```

`pod-login` mirrors your current directory into the container when you are under
the web root (`~/www` -> `/var/www`) and runs under `sudo` automatically; it
defaults to `php-fpm` because that is where the PHP tooling (and the site files)
live.

**The same list is shown every time you log in over SSH.** `deploy.sh` installs
`/etc/update-motd.d/99-server-setup`, which Ubuntu's `pam_motd` prints on
interactive logins. Re-install or remove it with:

```bash
sudo bash scripts/install-login-help.sh            # (re)install the banner
sudo bash scripts/install-login-help.sh --remove   # remove it
```

### Automatic updates

* **Host OS:** `unattended-upgrades` installs all Ubuntu 26.04 updates daily
  (including security/ESM). If an update needs a reboot, the box reboots itself
  at **03:30** (`/etc/apt/apt.conf.d/99-server-setup-autoreboot`), and superseded
  kernels + auto-installed dependencies are cleaned up.
* **Containers:** nothing updates the images by itself — `compose up` reuses the
  local image. `server-update.timer` runs `scripts/update.sh` weekly (Sun 04:00,
  up to 30 min staggered) to pull the upstream images
  (`mariadb`/`valkey`/`open-webui`/`certbot`) and rebuild `php`/`nginx`/`node`,
  which re-runs `apt` so the Ubuntu packages *inside* the images are updated.
  It does **not** re-provision sites, so site data is untouched. Logs:
  `/var/log/server-setup/update.log`.

### Firewall (ufw) and the containers

`deploy.sh` enables ufw and sets up two things, both required because the
containers sit behind podman's NAT:

1. **Routed web ports** — `ufw route allow ... port 80/443`. Published container
   ports are DNAT'd, so inbound traffic crosses ufw's FORWARD chain; without
   this the default `deny (routed)` drops it and the box looks closed on 80/443
   (even though it answers on 22).
2. **The podman subnets** (input + routed), discovered via
   `podman network inspect`. Without this, ufw blocks the netavark DNS, so
   containers can't resolve `mariadb`/`valkey`/`open-webui` and the sites hang
   (WordPress: "Error establishing a database connection"; Laravel:
   name-resolution timeouts).

### Open WebUI resilience

`chat.hellyer.kiwi` keeps its SQLite DB on the shared volume. The container has
**no podman restart policy** — systemd supervises it with a bounded restart
(`StartLimitBurst=5`) and `CPUQuota=100%` / `MemoryMax=1536M`
(`scripts/install-systemd.sh`), so a crash-looping app can't peg a core or spin
forever. `scripts/provision-openwebui.sh` runs `PRAGMA integrity_check` on the
restored `webui.db` and moves a corrupt one aside (Open WebUI then rebuilds a
fresh DB) instead of looping.

## Where the site files live

Site files live in the **admin user's home** — `~/www` (e.g. `/home/ryan/www`),
not `/var/www` — so they sit on the home partition and survive a move to an
atomic/immutable distro such as Fedora Silverblue. Override in `.env` with
`WWW_ROOT`.

The containers still see the same files at **`/var/www`**: `compose.yaml` mounts
`${WWW_ROOT:-/home/ryan/www}:/var/www`, so the nginx config
(`nginx/conf.d/*.conf`) and the container images are unchanged. Host-side
scripts translate between the two via `scripts/lib-paths.sh`.

> **Upgrading a box that still has content in `/var/www`?** Move it once:
> `sudo install -d -o ryan -g www-data -m 2775 /home/ryan/www && sudo rsync -a /var/www/ /home/ryan/www/`,
> then `sudo bash scripts/deploy.sh` (or re-run `scripts/provision-all.sh`).

`~/www` uses a shared-hosting permission model so files stay editable both by
`ryan` (SSH) and by the containers (`www-data` — same uid/gid 33 on host and
images):

* owner `ryan`, group `www-data`; dirs `2775` (setgid), files `664`.
* `ryan` is added to the `www-data` group and gets `umask 002` in `.bashrc`
  (`scripts/host-setup.sh`).
* PHP-FPM creates files with `umask = 0002` (`php/fpm-www.conf`).
* `sudo bash scripts/fix-perms.sh` re-applies ownership/modes (idempotent, run
  automatically by `deploy.sh` and `new-site.sh`; re-run after `restore.sh`).

> **Editing PHP on the host:** changes appear within ~10 seconds — OPcache
> revalidates file timestamps every 10s (`opcache.revalidate_freq = 10` in
> `php/10-opcache.ini`). To apply one immediately, `php-reload` (graceful) or
> `sudo podman restart php-fpm`; `deploy.sh` reloads FPM automatically after
> provisioning. (A stale `wp-config.php` otherwise shows up as WordPress's
> "Error establishing a database connection" even when the DB is fine.)

## Remote storage (snapshots, DB dumps)

Snapshots of the old `/var/www`, the weekly DB dumps and the Open WebUI data
live on remote storage (a Hetzner Storage Box by default), described by generic
`STORAGE_*` vars in `.env`:

* `STORAGE_USER` / `STORAGE_HOST` / `STORAGE_PORT` — the box.
* `STORAGE_KEY` — the SSH key (`~/.ssh/id_ed25519`, generated by
  `host-setup.sh`; authorised on the box by `storage-mounts.sh`).
* `SNAPSHOT_ROOT` — dated snapshot dirs (e.g. `/home/pressabl/2026-09-20`); the
  newest is used automatically. Pin `SNAPSHOT_DIR` to force a date.
* `SNAPSHOT_RENAMES` — map a snapshot dir to a different local dir, e.g.
  `spam-destroyer.com=spam-destroyer.hellyer.kiwi`.
* `DB_DUMP_DIR` — where the `<db>-<date>.sql.gz` dumps are (the `~/databases`
  mount).

**One-time key authorisation:** `storage-mounts.sh` installs the key on both
boxes (asking for each box's password once) with Hetzner's `install-ssh-key`,
which appends and never replaces existing keys.

## Migrating all sites (files + databases)

`scripts/provision-site.sh` restores **one** site from the newest snapshot,
deriving everything from the site's own files (no manifest). It is **always
fresh**: files are rsynced with `--delete`, and the database is dropped,
recreated and re-imported.

1. syncs `<snapshot>/<dir>/` into `~/www/<local-dir>` (`SNAPSHOT_RENAMES`
   applies, so `spam-destroyer.com` lands in `spam-destroyer.hellyer.kiwi`);
2. detects the database from the app — Laravel `.env` (`DB_*`), **Symfony
   `.env` (`DATABASE_URL`; sqlite → skipped)**, WordPress `wp-config.php`, or
   sqlite (file only);
3. creates the DB + its **own user (named after the DB)** with a fresh random
   password and a least-privilege grant, then imports the newest
   `<db>-*.sql.gz` (DEFINER clauses are stripped so the old shared user isn't
   needed);
4. points the app at the containers (`DB_HOST=mariadb`, `REDIS_HOST=valkey`,
   `REDIS_PASSWORD=`), clears caches, fixes permissions, reloads nginx.

```bash
sudo bash scripts/provision-site.sh cvs.hellyer.kiwi
sudo bash scripts/provision-site.sh spam-destroyer.com --to spam-destroyer.hellyer.kiwi
sudo bash scripts/provision-site.sh gpx.hellyer.kiwi --files-only   # SQLite app
```

`scripts/migrate-sites.sh` runs it across every site found in the newest
snapshot (dirs with `public/`, `public_html/`, `.env` or `wp-config.php`), and
`scripts/provision-all.sh` additionally imports the Open WebUI data — this is
what `deploy.sh` runs on **every** deploy:

```bash
sudo bash scripts/migrate-sites.sh --dry-run        # show what it would do
sudo bash scripts/provision-all.sh                  # everything, for real
sudo bash scripts/migrate-sites.sh --prune-placeholders
```

Flags: `--files-only`, `--db-only`, `--dry-run`, `--prune-placeholders`.

> **Every deploy is destructive to server-side data** (files, DBs and Open WebUI
> are replaced from the newest snapshot) — this box is a mirror of the backups.

> Only the databases listed in the old `backup.conf` have dumps
> (`pressabl`, `secure`, `events`, `cvs_hellyer_kiwi`, `spamannihilator`,
> `kartastrophecup`). Other apps use SQLite, or are created empty and migrated.

## Open WebUI (`chat.hellyer.kiwi`)

`chat.hellyer.kiwi` is served by **Open WebUI** — its own container, not a PHP
site. It's part of `compose.yaml` (service `open-webui`, data at
`~/www/chat.hellyer.kiwi:/app/backend/data`), and nginx proxies to it over the
`web` network (`nginx/conf.d/node-proxy.conf` → upstream `open-webui:8080`,
with WebSocket + long-timeout settings).

Restore/refresh its data from the storage box (newest dated snapshot):

```bash
sudo bash scripts/provision-openwebui.sh
sudo bash scripts/provision-openwebui.sh --drop-vector-db   # force ChromaDB rebuild
sudo bash scripts/provision-openwebui.sh --dry-run
```

It rsyncs `webui.db` + `uploads/` (skipping the transient `webui.db-wal`/`-shm`,
`cache/`, and the old `install.sh`/tooling), reads `OPENROUTER_API_KEY` from the
snapshot's `install.sh` into `.env` (never printed/committed), brings up the
`open-webui` service, waits for `/api/version`, and reloads nginx.

Notes: `vector_db/` is kept by default because the container path
(`/app/backend/data`) is stable; use `--drop-vector-db` if RAG/embeddings
misbehave. The container is localhost-published on `127.0.0.1:3000` for health
checks/debugging; nginx reaches it by name on the compose network.

## TLS certificates

* Every server block serves the same **`pressabl`** certificate
  (`env/letsencrypt/live/pressabl`). Before a real one is issued,
  `gen-test-certs.sh` (test mode) or the deploy.sh bootstrap creates a
  self-signed placeholder there — covering every configured domain in test
  mode — so nginx always starts and every site still gets a (bypassable)
  certificate.
* The real cert is issued by `scripts/certbot-issue.sh`, driven by
  `certbot/domains.txt` — one line = one certificate, `pressabl <all domains>`.
  Test mode uses `certbot/domains.test.txt` (`pressabl
  spam-destroyer.hellyer.kiwi`). Every listed domain must have DNS pointed at
  this host before it can be issued.
* **HSTS is sent in production only.** In test mode `render-config.sh` drops
  the `Strict-Transport-Security` header, so browsers still let you proceed
  past the self-signed fallback certs (HSTS errors are non-bypassable).

## Scheduled jobs (automatic)

No cron is needed — `scripts/deploy.sh` installs systemd timers on every
install/deploy:

| Job | Schedule | Runs |
|---|---|---|
| Nightly backup | daily 03:00 | `scripts/backup.sh` |
| TLS renewal | 2×/day (renews only when <30 days left) | `scripts/certbot-issue.sh` |

Check them with `systemctl list-timers 'server-backup.timer' 'certbot-renew.timer'`.

> **Note:** `scripts/backup.sh` is a **work in progress** — it's a simple
> "mysqldump everything + tar `~/www`" script and needs upgrading to match
> the real production backup system. The current real backup system from the
> main site lives in [`temp-backup/`](temp-backup/) (`backup.sh`,
> `backup-config.sh`, `backups/`) — use it as the reference to build the real
> new backup system. Until then, treat `scripts/backup.sh` as a starting
> point, not the final backup solution.