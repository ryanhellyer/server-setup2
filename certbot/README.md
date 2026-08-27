# Certbot

TLS is issued with Let's Encrypt using the **http01 webroot** challenge on port
80 (`/var/www/acme`), served by `nginx/conf.d/http-redirect.conf` before the
HTTPS redirect.

## Automation

```bash
sudo ./scripts/certbot-issue.sh        # issue/renew every cert in domains.txt
```

## How it works

- `domains.txt` lists certificates, one per line: `<cert-name> <domain>...`.
- The script runs the `certbot/certbot` image (or a local certbot if present)
  for each line, storing results under `env/letsencrypt/` (which compose mounts
  read-only into nginx as `/etc/letsencrypt`).
- Each server block serves **one** certificate (hardcoded path — nginx can't
  reliably select a cert per-SNI via variables). Certs live in their own
  `env/letsencrypt/live/<cert-name>/` dirs; blocks without a real cert serve
  the self-signed multi-SAN fallback `live/test-all`. `deploy.sh` seeds a
  placeholder into each `live/<name>` so a not-yet-issued cert doesn't stop
  nginx from starting.

## Manual (single domain)

```bash
sudo podman run --rm \
  -v "$PWD/env/letsencrypt:/etc/letsencrypt" \
  -v /var/www/acme:/var/www/acme \
  certbot/certbot certonly --webroot -w /var/www/acme \
  --email admin@hellyer.kiwi --agree-tos --no-eff-email \
  --cert-name example.hellyer.kiwi -d example.hellyer.kiwi
```

## Notes

- Keep the `acme-challenge` location in `http-redirect.conf` on port 80.
- Renewal is automatic: `scripts/install-systemd.sh` installs the
  `certbot-renew.timer` (runs `certbot-issue.sh` 2×/day) on every deploy —
  no cron needed. The script only renews certs with <30 days left, so it
  never hits Let's Encrypt rate limits.