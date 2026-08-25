# Podman Migration Plan — hellyer.kiwi server

**Goal:** Move ~15 sites (Laravel + WordPress + static + Node) from a bare-metal
Ubuntu server to a fully containerised stack running under Podman, so the box can
be rebuilt from scratch in minutes, not days. Nginx remains the only web server /
reverse proxy (no Varnish).

* * *

## 1. Target architecture

Single host running Podman. Everything else runs as containers.

```
Internet -> [Nginx proxy container :80/:443]   (Certbot TLS, brotli, gzip)
              |-> PHP-FPM container(s)        (Laravel + WordPress; one shared "app" image)
              |-> Node.js container(s)        (per Node site or a shared runner)
              |-> MariaDB container           (all DBs)
              `-> Redis container             (sessions + WP object cache)
```

*   One **shared PHP-FPM container** (PHP **8.5**) is enough for all sites (same
    PHP version, same extensions). Per-site PHP is only needed if a site truly
    needs a different PHP version — add an extra app container then.

*   One **MariaDB** container hosts all site DBs. One **Redis** container shared
    by WP + Laravel.

*   **Nginx** is its own container. The whole `/etc/nginx` layout is bind-mounted
    read-only from the repo's `nginx/` directory, so the repo is the single
    source of truth.

### Container OS image choice

*   Use **ubuntu:24.04** for PHP-FPM and Nginx (24.04 LTS is stable, and what the
    PHP packages target well). PHP **8.5** comes from the **ondrej/php** PPA.

*   Node image: official **node:22 (Debian)** slim — simplest and stable.

*   Host runs **Ubuntu 26.04**. The host only needs podman, git, sshfs etc —
    nothing that lags behind on 26.04 — and all app packages live inside the
    containers (which stay on 24.04, where PHP 8.5 etc. are best supported).

* * *

## 2. Repository layout (single git repo = instant rebuild)

```
server-setup/
|-- README.md                   # one-line install + day-to-day cheatsheet
|-- install.sh                  # EMERGENCY one-shot installer (curl | bash)
|-- deploy.sh                   # MAIN entry point: .env + refresh + build + compose up
|-- compose.yaml                 # root docker compose: full stack
|-- .env.example                 # secrets template (copy to .env, git-ignored)
|-- nginx/
|   |-- Containerfile            # ubuntu:24.04 + nginx + brotli modules
|   |-- nginx.conf               # main config (gzip, brotli, cache, maps, upstreams)
|   |-- conf.d/                  # the JOINED server blocks (few blocks, many domains)
|   |   |-- http-redirect.conf       # port 80: ACME challenge + 301 (all domains)
|   |   |-- php-site.conf            # ONE block: all Laravel/generic-PHP sites
|   |   |-- wordpress-multisite.conf # ONE block: pressabl multisite (~20 subdomains)
|   |   |-- static-site.conf         # ONE block: chocolate, julia, stuff, mum, dad
|   |   |-- static-spa.conf          # ONE block: comicjet, historic-wordpress
|   |   |-- node-proxy.conf          # chat.hellyer.kiwi (Node)
|   |   |-- secure-site.conf         # secure.hellyer.kiwi (auth + fallback)
|   |   |-- redirects.conf           # ONE block: all 301 redirects
|   |   `-- ionos-test.conf          # TEST-ONLY vhost (remove for production)
|   |-- snippets/                # SHARED building blocks (change once -> many)
|   |   |-- ssl-params.conf          # TLS protocols, ciphers, OCSP stapling
|   |   |-- security-headers.conf    # HSTS/CSP/X-Frame etc. header set
|   |   |-- static-assets.conf       # long-cache asset locations
|   |   |-- fastcgi-php.conf         # the PHP location shared by every PHP site
|   |   `-- wordpress-locations.conf # WP multisite locations
|   |-- sites/                   # per-site override notes + test site content
|   |   `-- ionos.hellyer.kiwi/      # PHP diagnostics page (test)
|   `-- _legacy/                 # old garbled configs, kept for reference only
|-- php/
|   |-- Containerfile            # ubuntu:24.04 + php8.5-fpm (ondrej PPA) + extensions
|   |-- 10-opcache.ini
|   |-- 20-fpm-security.ini
|   `-- fpm-www.conf
|-- maria/
|   |-- init/example.sql         # DB + user grant template (idempotent)
|   `-- my.cnf
|-- redis/
|   `-- redis.conf               # maxmemory 64mb (test) / via REDIS_MAXMEMORY
|-- node/
|   `-- Containerfile
|-- certbot/
|   |-- domains.txt              # one line per certificate: "<name> <domain>..."
|   |-- domains.test.txt         # test list: only ionos.hellyer.kiwi
|   `-- README.md
|-- scripts/
|   |-- bootstrap.sh              # one-time host setup (packages + dirs)
|   |-- deploy.sh                 # git pull -> nginx -t -> podman compose up -d --build
|   |-- new-site.sh               # scaffold a site into the joined blocks
|   |-- backup.sh                 # dump DBs + archive site dirs to Hetzner
|   |-- restore.sh                # restore DBs + /var/www from the latest backup
|   |-- certbot-issue.sh          # issue/renew certs (env-driven cert list)
|   |-- install-cli.sh            # symlink host CLI wrappers into ~/.local/bin
|   |-- install-systemd.sh        # systemd units so the stack starts at boot
|   `-- test-site.sh              # scaffold the ionos.hellyer.kiwi test page
|-- bin/
|   `-- pod-exec                  # run php/composer/mariadb/ffmpeg/... in the right container
|-- .tarball                      # (generated by install.sh) marks a tarball install so
|                                 #   deploy.sh refreshes the files the same way
`-- .env                          # passwords/secrets (git-ignored)
```

Everything needed to rebuild lives in this repo. A fresh host = the
`install.sh` one-liner (which downloads the files as a tarball — public repo,
**no git / no SSH keys** — then runs `deploy.sh`).

* * *

## 3. Nginx: consolidation ("change one block -> changes many")

The old config had **~25 near-identical server blocks** (one per domain, each with
copied-and-pasted PHP/SSL/static locations — and several conflicting backup files).

The new layout collapses those into **8 server blocks for all ~45 domains**:

| Block | Domains served | What differs per domain |
|---|---|---|
| `http-redirect.conf` | every domain (port 80) | nothing (ACME + 301) |
| `php-site.conf` | gpx, ryan, kartastrophecup.de, spam-destroyer.com, german, cvs, ai, instantattend.com | root, log path (via maps) |
| `wordpress-multisite.conf` | de, undiecar, berlin-advice, book, external-posts, facebook, forum, ice, instagram, invoices, nb, offline-demo, slapshot, tweets, wordpress, dunedinicehockey, psychedelicsocietyberlin.org, carly, admin.ryan (+ undiecar.com) | nothing (shared pressabl root) |
| `static-site.conf` | chocolate, julia, stuff, mum, dad | root (map), dad's auth (map) |
| `static-spa.conf` | comicjet.com, historic-wordpress.hellyer.kiwi | root (map) |
| `node-proxy.conf` | chat.hellyer.kiwi | — |
| `secure-site.conf` | secure.hellyer.kiwi | too different to join |
| `redirects.conf` | events, spamannihilator, hellyer/geek/random, www variants | target (map) |

**How a single change propagates to every site:**

*   **PHP version/socket** → one `upstream php-fpm` in `nginx.conf`
    (`php8.5-fpm.sock`). Edit once, every vhost follows.
*   **TLS/ciphers/OCSP** → `snippets/ssl-params.conf`, included once at the
    `http` level.
*   **Security headers** → `snippets/security-headers.conf`.
*   **PHP handling** (split-path, params, SCRIPT_FILENAME) →
    `snippets/fastcgi-php.conf`, included by every PHP location.
*   **Cache control** → maps in `nginx.conf` (single `$no_cache_final` flag used
    by every PHP block) + one shared `fastcgi_cache_key`.
*   **Static asset caching** → `snippets/static-assets.conf`.

**Per-site differences within a joined block** are expressed as `map`s
(`$site_root`, `$site_access_log`, `$static_auth_realm`) and **host-scoped
locations** guarded by a flag map (see `$ryan_extra` in `php-site.conf`). This
keeps the "one file = the source of truth" property even for the few sites that
need their own quirks.

**PHP socket note:** all three old sockets (`php8.4-fpm.sock`,
`php8.4-fpm-admin.sock`, `php8.4-fpm-ryan.sock`) are now a single
`php8.5-fpm.sock` served by the shared FPM pool, matching the single shared
PHP container.

* * *

## 4. PHP-FPM container (the workhorse)

Containerfile (base **ubuntu:24.04**, PHP **8.5** from ondrej/php):

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y software-properties-common ca-certificates \
    && add-apt-repository -y ppa:ondrej/php \
    && apt-get update && apt-get install -y \
      php8.5-fpm php8.5-mysql php8.5-mbstring php8.5-zip php8.5-intl \
      php8.5-imagick php8.5-gd php8.5-curl php8.5-dom php8.5-xml php8.5-cli \
      php8.5-redis php8.5-sqlite3 php8.5-opcache \
      composer ffmpeg
```

*   OPcache enabled (128M, 10000 slots, JIT 1255/64M) via `10-opcache.ini`.
*   `cgi.fix_pathinfo = 0`, `expose_php = Off` via `20-fpm-security.ini`.
*   Site files mounted from the host `/var/www`.
*   FPM listens on `/run/php/php8.5-fpm.sock`, shared with the Nginx container
    through the `php-socket` volume.

* * *

## 5. Nginx container (the only thing facing the internet)

*   Ubuntu 24.04 base with the distro nginx + `libnginx-mod-http-brotli-filter`
    / `-static` (brotli on; gzip fallback also enabled).
*   The repo's `nginx/` directory is mounted read-only at `/etc/nginx` — the
    repo **is** the config.
*   Port 80 is a single catch-all block: ACME webroot challenge + unconditional
    301 to https (see `conf.d/http-redirect.conf`).
*   TLS via Certbot-managed certs under `env/letsencrypt`, mounted read-only.

**Note:** Varnish is dropped entirely. The old Varnish/8081/CNAME juggling goes
away. Let's Encrypt uses `http01` webroot on port 80 before the redirect.

* * *

## 6. Stateful services

### MariaDB

*   One container on host volume `/var/lib/mysql`.
*   Init scripts (`maria/init/*.sql`) create each DB + least-privilege user.
*   Per-site credentials live in `.env`, generated by `new-site.sh`.

### Redis

*   One container. `maxmemory` defaults to **64 MB** on the test server (2 GB
    RAM); set `REDIS_MAXMEMORY=1024mb` in `.env` on production. Policy is
    `maxmemory-policy allkeys-lru`.
*   Runs on the **internal** container network (sessions/cache only).

### NodeJS

*   One `node:22-slim` container (or one per app if you need isolation).
*   Serves Node-based sites behind Nginx (`node-proxy.conf`).

* * *

## 7. Storage / the Hetzner sshfs mounts

Keep the same remote storage, but mount at the **host level** (not inside a
container), then bind-mount into the containers. SSHFS in a container is fragile
(FUSE + device access).

*   Host: `sshfs` mounts `/var/gmail`, `/var/yandex-disk`, `/var/databases`,
    `/var/sync` via `/etc/fstab` (same options: `x-systemd.automount`, `_netdev`,
    `reconnect`, fixed IdentityFile).
*   Compose bind-mounts these into the app containers where sites need them.
*   This preserves your backup/offload mounts unchanged.

* * *

## 8. Migration of the sites

1.  Copy site files to the host layout `/var/www/<domain>` (rsync from the old
    box as you already do).
2.  Dump each MariaDB/WordPress DB, load it into the container.
3.  Run `scripts/new-site.sh <domain> <type>` for each site. It adds the domain
    to the right joined block's map + `server_name`, creates the web root + logs,
    generates the DB/user (for Laravel/WP), then `nginx -t` + reloads.
4.  `nginx -t`; reload the Nginx container; request the TLS cert via
    `scripts/certbot-issue.sh` (edit `certbot/domains.txt` first).

Most sites need **no per-site nginx changes at all** — the joined block already
handles their platform.

* * *

## 9. Rebuild procedure (the whole point)

### Production

**Emergency path (no docs needed)** — installs packages, downloads the repo as a
tarball (public repo — no SSH keys, no git) and deploys, all in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/main/install.sh \
  -o /tmp/install.sh && sudo bash /tmp/install.sh
```

**Stepped path** (if you want to watch each stage):

```bash
sudo ./scripts/bootstrap.sh              # one-time: packages + dirs
mkdir -p /opt/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/main.tar.gz | \
  tar -xz --strip-components=1 -C /opt/server-setup
cd /opt/server-setup
cp .env.example .env                     # fill secrets, DEPLOY_ENV=production
# apply Hetzner sshfs mounts (fstab / automount)
sudo ./deploy.sh                         # refresh files -> nginx -t -> compose up -d --build
                                         # (also installs systemd units for boot-start)
sudo ./scripts/certbot-issue.sh          # request TLS for every domain
sudo ./scripts/restore.sh                # restore DBs + site files from the latest backup
```

`deploy.sh` also generates and enables a `container-<name>.service` for every
container, so the stack **starts automatically at boot** and is supervised by
systemd (nginx is ordered after php-fpm, since it uses the shared FPM socket).
Compose remains the source of truth for the container definitions.

The whole stack comes up from the repo in **under ~30 minutes once base images
are cached**.

### Test server (2 GB box)

```bash
sudo ./scripts/bootstrap.sh
mkdir -p /opt/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/main.tar.gz | \
  tar -xz --strip-components=1 -C /opt/server-setup
cd /opt/server-setup
cp .env.example .env                     # keep DEPLOY_ENV=test
sudo ./deploy.sh                         # builds + starts the whole stack
sudo ./scripts/test-site.sh              # scaffold the ionos.hellyer.kiwi test page
sudo ./scripts/certbot-issue.sh          # REAL cert for ionos.hellyer.kiwi only
# point DNS ionos.hellyer.kiwi at this box, then open https://ionos.hellyer.kiwi
```

The repo lives at **`/opt/server-setup`** — a stable path outside `/home`, so the
systemd units (`scripts/install-systemd.sh`) and CLI wrappers (`bin/pod-exec`)
keep resolving correctly across reboots and user sessions.

In test mode the box is lightweight by design:

*   **Redis** capped at **64 MB** (`REDIS_MAXMEMORY` in `.env`).
*   **TLS** is only handled for **ionos.hellyer.kiwi**
    (`CERTBOT_DOMAINS_FILE=certbot/domains.test.txt`). `certbot-issue.sh`
    issues that one cert and symlinks it into the cert path every vhost
    references — other domains still resolve but show a cert warning (expected
    on a test box).
*   The **ionos.hellyer.kiwi** vhost (`nginx/conf.d/ionos-test.conf`, delete
    for production) serves a PHP diagnostics page that proves nginx -> php-fpm
    -> Redis/MariaDB networking, PHP extensions, ffmpeg and OPcache all work.

* * *

## 10. Security hardening

Applied **in this repo** (ships with the config):

*   **TLS**: TLSv1.2 + TLSv1.3 only, ECDHE-only cipher suite, strong ECDH curves,
    OCSP stapling, session tickets off, `server_tokens off` (`snippets/ssl-params.conf`).
    Regenerate a 2048-bit dhparam if you ever enable DHE:
    `openssl dhparam -out /etc/nginx/dhparam.pem 2048`.
*   **Headers**: HSTS (63072000s, includeSubdomains, preload), `X-Frame-Options
    SAMEORIGIN`, `nosniff`, Referrer-Policy, Permissions-Policy, X-XSS-Protection
    (`snippets/security-headers.conf`).
*   **PHP**: `cgi.fix_pathinfo = 0`, `expose_php = Off`, `display_errors = Off`,
    plus nginx-side `try_files $uri =404` before FastCGI
    (`snippets/fastcgi-php.conf`, `php/20-fpm-security.ini`).
*   **Filesystem hygiene**: `.git` access routed away, direct `blogs.dir` blocked,
    PHP execution under `/images/` denied, no access logs for static assets.
*   **Least-privilege DB**: one DB + limited-grant user per site
    (`maria/init/example.sql`).
*   **Secrets**: passwords only in `.env` (git-ignored); `.env.example` is the
    only committed copy.

Applied **at deploy time** (documented here so you don't forget):

*   **Host firewall**: `sudo ufw allow 22,80,443/tcp && sudo ufw enable`.
*   **SSH**: disable password login + root login in `/etc/ssh/sshd_config`;
    use SSH keys only. Optionally fail2ban for the whole box.
*   **Unattended-upgrades** on the **host only** (`sudo apt install
    unattended-upgrades`) — containers stay frozen; you update them by rebuilding
    the repo.
*   **Swap** on low-RAM hosts: `fallocate -l 2G /swapfile` still recommended.
*   **MariaDB**: bind to the internal container network only (never publish port
    3306 to the host). Already the case in `compose.yaml`.
*   **Backups off-host**: `scripts/backup.sh` offloads nightly dumps + a site
    archive to the Hetzner storage box.
*   **TLS renewal**: run `scripts/certbot-issue.sh` on a cron timer.
*   **Monitoring**: `podman ps` in a cron job, plus watch `/var/log/nginx/error.log`.

* * *

## 11. Automation (everything scriptable is scripted)

| Script | What it does |
|---|---|
| `install.sh` | Emergency one-shot: installs packages, downloads the repo as a tarball (public repo — no git/keys), then runs `deploy.sh`. |
| `scripts/host-setup.sh` | Installs the host package set + creates bind-mount dirs (called by install.sh/bootstrap.sh and auto by deploy.sh). |
| `scripts/bootstrap.sh` | One-time host setup + prints the key/clone/deploy next steps. |
| `deploy.sh` (root) | MAIN entry point: auto-installs podman if missing, creates + opens `.env` in nano, refreshes files (git pull OR tarball re-download), `nginx -t`, `compose up -d --build`, systemd units. |
| `scripts/new-site.sh` | Adds a domain to the right joined block (map + `server_name`), creates web root/logs, generates DB + user + `.env` password (Laravel/WP), validates + reloads nginx. |
| `scripts/backup.sh` | Dumps all DBs, archives `/var/www`, prunes 14 days, rsyncs to Hetzner. |
| `scripts/restore.sh` | Restores the latest DB dump + `/var/www` archive from `/var/databases` (no-op if none exist yet). |
| `scripts/certbot-issue.sh` | Issues/renews certs from `CERTBOT_DOMAINS_FILE` (test = `domains.test.txt`) via the webroot challenge; links the cert into the path nginx serves. |
| `scripts/test-site.sh` | Scaffolds the ionos.hellyer.kiwi diagnostics page into `/var/www` and reloads nginx. |
| `scripts/install-cli.sh` | Installs host-side CLI wrappers (see below). |
| `scripts/install-systemd.sh` | Generates + enables `container-*.service` units so the stack auto-starts at boot (called by deploy.sh). |

### Running CLI tools from the host

Nothing (php, composer, mariadb, ffmpeg, redis-cli, node…) is installed on the
host — it all lives in the containers. To still type those commands on the host,
the repo ships a thin dispatcher (`bin/pod-exec`) that wraps `podman exec`:

```bash
./scripts/install-cli.sh                  # symlinks into ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"      # add to ~/.bashrc, BEFORE /usr/bin
```

Then, from the host (as root):

| Command | Runs inside | Notes |
|---|---|---|
| `php`, `composer` | php-fpm | as `www-data`; cwd mirrored when you're under `/var/www` |
| `artisan <cmd>` | php-fpm | `php artisan …` in the current site dir |
| `wp <cmd>` | php-fpm | WP-CLI (now in the PHP image) |
| `ffmpeg`, `ffprobe` | php-fpm | |
| `mysql`, `mariadb` | mariadb | root creds pulled from `.env` automatically |
| `mysqldump`, `mariadb-dump` | mariadb | adds `--single-transaction` |
| `redis-cli` | redis | |
| `node`, `npm`, `npx`, `yarn` | node | |
| `pod-exec <container> <cmd>` | any | escape hatch for arbitrary commands |

Example session:

```bash
sudo -i
cd /var/www/some-site && composer install && artisan migrate
wp --path=/var/www/pressabl/public_html core version
mysqldump pressabl | gzip > /var/databases/pressabl.sql.gz
ffmpeg -i video.mov video.webm
redis-cli ping
```

* * *

## 12. Decisions

Confirmed — these are locked in and reflected throughout this plan:

*   **Host release: 26.04.** The host only runs podman/git/sshfs etc. — nothing
    that lags behind on 26.04; all app packages live in the 24.04-based
    containers.
*   **One shared PHP-FPM, all PHP 8.5.** A single `php8.5-fpm.sock` served by one
    FPM pool/container. A second PHP container is added only if a site ever
    truly needs a different version.
*   **Orchestration: `podman compose`.** `scripts/deploy.sh` prefers `podman
    compose` and falls back to `podman-compose` if it isn't available.
*   **Boot-start: systemd units.** `deploy.sh` generates + enables
    `container-*.service` units so the stack comes up automatically on reboot.