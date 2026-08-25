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
- nginx config points every vhost at
  `/etc/letsencrypt/live/pressabl12.hellyer.kiwi/...` — the combined cert used
  by this server.

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
- Renewal is handled by running `certbot-issue.sh` (cron it if you like) or by
  certbot's own timer when installed natively.