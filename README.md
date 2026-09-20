# server-setup

The containerised web stack for **hellyer.kiwi** (Nginx + PHP 8.5 + MariaDB +
Valkey + Node), deployed with Podman. Everything needed to rebuild the server
lives in this repo.

## Install on a fresh Ubuntu server — one line

**First, point DNS:** create an `A` record `ionos.hellyer.kiwi` → this host's IP.
That's the one manual step (it lives in your DNS provider) — everything below is
automatic.

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install/setup.sh \
  -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

That one command:

1. **Installs the host tools** (podman, podman-compose, curl, openssl, nano...) plus the
   **Starship prompt** for a nicer, consistent host shell (config in `config/starship.toml`).
2. **Creates an admin user `ryan`** with your SSH key and passwordless
   `sudo` (no account password — access is key-only; `scripts/create-admin-user.sh`).
3. **Downloads the whole repo as a tarball** from GitHub — the repo is public,
   so no SSH keys, no git, no GitHub console work are needed.
4. **Opens the firewall ports** 22/80/443 (added automatically; harmless if ufw
   is off).
5. **Deploys** — creates `.env` and opens it in **nano** for you to fill in
   secrets, builds the nginx + PHP images, brings up the whole stack (nginx,
   php-fpm, mariadb, valkey, node), installs systemd units so it starts at boot,
   schedules the **nightly backup** and **TLS renewal** (systemd timers, no
   cron needed), and **issues the real TLS cert for `ionos.hellyer.kiwi`
   automatically** (it checks DNS first — if DNS isn't propagated yet, it tells
   you exactly what to do and you just re-run `sudo ./install/setup.sh`).

No further commands needed — visit `https://ionos.hellyer.kiwi` when the deploy
finishes.

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
- **6)** scaffold the ionos test site
- **7)** re-install systemd units
- **8)** install host CLI tools (php, composer, mariadb, ...)
- **9)** show stack status
- **10)** tail container logs
- **11)** connect the Hetzner Storage Boxes (passwordless key + `gmail`/`databases` mounts)
- **12)** harden SSH (disable password authentication)

## Manual path

```bash
sudo ./scripts/host-setup.sh          # one-time host setup (packages + dirs + swap)
mkdir -p /opt/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz | \
  tar -xz --strip-components=1 -C /opt/server-setup
cd /opt/server-setup
cp .env.example .env && nano .env      # scripts/deploy.sh does this for you automatically
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
| Add a site (no menu) | `sudo bash scripts/new-site.sh <domain> <type>` |
| Back up | `sudo bash scripts/backup.sh` |
| Restore from backup | `sudo bash scripts/restore.sh` |
| Issue/renew TLS | `sudo bash scripts/certbot-issue.sh` |
| Fix web-dir ownership + permissions (ryan:www-data, setgid) | `sudo bash scripts/fix-perms.sh` (re-run after `restore.sh`) |
| Import/re-sync a site from the Hetzner storage box | `sudo bash scripts/sync-site.sh` (auto-run by `deploy.sh`) |
| Restore one site fully (files + DB) | `sudo bash scripts/provision-site.sh <site-dir>` |
| Restore every site found in the snapshot | `sudo bash scripts/migrate-sites.sh [--dry-run]` |
| Set up Hetzner Storage Box access (both boxes) + mount `gmail`, `databases` | `sudo bash scripts/hetzner-mounts.sh` |
| Create/refresh the admin user (`ryan`) with a key + passwordless sudo | `sudo bash scripts/create-admin-user.sh` |
| Harden SSH (keys only) / revert | `sudo bash scripts/harden-sshd.sh [--revert]` |
| Provision/install a remote server, or open its menu over SSH | `./bootstrap.sh --host <ip>` |
| Run CLI tools on the host (php, composer, mariadb, ffmpeg...) | `bash scripts/install-cli.sh` |
| Re-apply host packages / Starship prompt / swap | `sudo bash scripts/host-setup.sh` |
| See the full architecture & rebuild plan | [`PODMAN_PLAN.md`](PODMAN_PLAN.md) |

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
> then `sudo bash scripts/deploy.sh` (or re-run `scripts/sync-site.sh`).

`~/www` uses a shared-hosting permission model so files stay editable both by
`ryan` (SSH) and by the containers (`www-data` — same uid/gid 33 on host and
images):

* owner `ryan`, group `www-data`; dirs `2775` (setgid), files `664`.
* `ryan` is added to the `www-data` group and gets `umask 002` in `.bashrc`
  (`scripts/host-setup.sh`).
* PHP-FPM creates files with `umask = 0002` (`php/fpm-www.conf`).
* `sudo bash scripts/fix-perms.sh` re-applies ownership/modes (idempotent, run
  automatically by `deploy.sh` and `new-site.sh`; re-run after `restore.sh`).

## Site import from the Hetzner storage box

On a fresh box, real site content is pulled from the Hetzner storage box so the
sites resolve instead of showing the seeded placeholder. Configure it in `.env`
(`HETZNER_SYNC_*`), then `scripts/sync-site.sh` (called automatically by every
`deploy.sh`) rsyncs the snapshot in and keeps it in sync.

**One-time step — authorize the SSH key on the box:**

1. `sudo bash scripts/host-setup.sh` generates `~/.ssh/hetzner_backup` (if
   missing) and prints the **public** key with instructions.
2. Install it on the box with Hetzner's built-in command (it asks for the
   storage box password):
   ```bash
   cat ~/.ssh/hetzner_backup.pub | ssh -p 23 u<id>@u<id>.your-storagebox.de install-ssh-key
   ```
3. Re-run `sudo bash scripts/sync-site.sh` — or let the next deploy do it.
   (`sync-site.sh` can also offer to run step 2 for you when it hits an
   unauthorized key, and retries after.)

> The snapshot is **files only**. Making a site actually run also needs its
> database imported into the MariaDB container and `.env` pointed at it — see
> the migration scripts below.

## Migrating all sites (files + databases)

`scripts/provision-site.sh` restores **one** site end-to-end, deriving
everything from the site's own files (no manifest):

1. rsyncs the site's directory from the snapshot (`HETZNER_SNAPSHOT_DIR`) into
   `~/www/<dir>`;
2. reads the app's config to find its database — Laravel `.env`
   (`DB_DATABASE`/`DB_USERNAME`/`DB_PASSWORD`), WordPress `wp-config.php`, or
   SQLite (just ensures the file exists);
3. creates the DB + user + grants and imports the newest
   `<db>-*.sql.gz` from `DB_DUMP_DIR` — **only if the DB is empty**;
4. rewrites the app config for the containers (`DB_HOST=mariadb`,
   `REDIS_HOST=valkey`, `REDIS_PASSWORD=`), clears Laravel caches, fixes
   permissions and reloads nginx.

```bash
sudo bash scripts/provision-site.sh cvs.hellyer.kiwi
sudo bash scripts/provision-site.sh spam-destroyer.com --domain spam-destroyer.com
sudo bash scripts/provision-site.sh gpx.hellyer.kiwi --files-only   # SQLite app
```

`scripts/migrate-sites.sh` runs it across every site it finds in the snapshot
(kept: dirs with `public/`, `public_html/`, `.env` or `wp-config.php`):

```bash
sudo bash scripts/migrate-sites.sh --dry-run        # show what it would do
sudo bash scripts/migrate-sites.sh                  # all sites
sudo bash scripts/migrate-sites.sh --files-only
sudo bash scripts/migrate-sites.sh cvs.hellyer.kiwi kartastrophecup.de
```

Useful flags: `--files-only`, `--db-only`, `--force` (wipe + re-import the
dump), `--dry-run`. Re-runs are safe: files are an exact `rsync --delete`
mirror of the snapshot, and a non-empty database is left untracked unless
`--force`.

> Only the databases listed in the old `backup.conf` have dumps
> (`pressabl`, `secure`, `events`, `cvs_hellyer_kiwi`, `spamannihilator`,
> `kartastrophecup`). Other Laravel apps use SQLite, or will be created empty
> and migrated with `php artisan migrate`.

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
  Test mode uses `certbot/domains.test.txt` (`pressabl ionos.hellyer.kiwi
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