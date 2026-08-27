#!/usr/bin/env bash
# =============================================================================
# new-site.sh — scaffold a brand-new site from the consolidated nginx setup.
#
#   sudo ./scripts/new-site.sh <domain> <type> [target]
#
#   type:
#     laravel    -> joined php-site.conf block (root /var/www/<domain>/public)
#     wordpress  -> WordPress Multisite block (pressabl root, DB + user created)
#     static     -> joined static-site.conf block (autoindex, /public)
#     static-spa -> joined static-spa.conf block (/public_html, index.html app)
#     redirect   -> joined redirects.conf block (needs target, e.g.
#                   https://destination.example$request_uri)
#     node       -> node-proxy.conf block (chat-style Node app)
#
# What it does:
#   1. Adds the domain to the right map + server_name list in conf.d/.
#   2. Creates the web root + log dirs under /var/www.
#   3. For laravel/wordpress: generates a DB + least-privilege user
#      (maria/init/<domain>.sql) and stores the password in .env.
#   4. Runs nginx -t and reloads nginx.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh

usage() {
  echo "Usage: $0 <domain> <type> [target]"
  echo "  type: laravel | wordpress | static | static-spa | redirect | node"
  echo "  target: required for redirect, e.g. 'https://example.com\$request_uri'"
  exit 1
}

[ $# -lt 2 ] && usage
DOMAIN="$1"
TYPE="$2"
TARGET="${3:-}"

case "$DOMAIN" in
  *[!a-zA-Z0-9.-]*|'') echo "Invalid domain: $DOMAIN"; exit 1 ;;
esac

echo "==> Adding $DOMAIN ($TYPE)"

# ---- 1. Edit the nginx config (backup first, then insert) ----
NGINX_DIR="nginx" DOMAIN="$DOMAIN" TYPE="$TYPE" TARGET="$TARGET" python3 - <<'PY'
import os, re, sys

nginx_dir = os.environ["NGINX_DIR"]
domain    = os.environ["DOMAIN"]
stype     = os.environ["TYPE"]
target    = os.environ.get("TARGET", "")

# type -> (file, map name or None, root or None, server_name marker, needs target)
PLAN = {
  "laravel":   ("conf.d/php-site.conf",          "site_root",        "/var/www/%s/public" % domain,       "php-site domains",      False),
  "wordpress": ("conf.d/wordpress-multisite.conf", None,             None,                                 "wordpress domains",     False),
  "static":    ("conf.d/static-site.conf",       "static_root",      "/var/www/%s/public" % domain,       "static-site domains",   False),
  "static-spa":("conf.d/static-spa.conf",        "spa_root",         "/var/www/%s/public_html" % domain,  "static-spa domains",    False),
  "redirect":  ("conf.d/redirects.conf",         "redirect_target",  None,                                 "redirect domains",      True),
  "node":      ("conf.d/node-proxy.conf",        None,               None,                                 "node-proxy domains",    False),
}
if stype not in PLAN:
    sys.exit("Unknown type: %s" % stype)

path, map_name, root, marker, needs_target = PLAN[stype]
if needs_target and not target:
    sys.exit("redirect type requires a target argument")

filepath = os.path.join(nginx_dir, path)
with open(filepath) as fh:
    text = fh.read()

def insert_into_map(text, map_name, entry):
    """Insert `entry` inside the named $http_host map (after hostnames; or before })."""
    lines = text.split("\n")
    out = []
    inside = False
    inserted = False
    for ln in lines:
        if not inside and re.search(r"map \$http_host \$%s \{" % re.escape(map_name), ln):
            inside = True
            out.append(ln)
            continue
        if inside and not inserted:
            if re.match(r"\s*hostnames;\s*$", ln):
                out.append(ln)
                out.append(entry)
                inserted = True
                continue
            if ln.rstrip() == "}":
                out.append(entry)
                out.append(ln)
                inserted = True
                inside = False
                continue
        if inside and ln.rstrip() == "}":
            inside = False
        out.append(ln)
    if not inserted:
        raise RuntimeError("map %s not found or not editable" % map_name)
    return "\n".join(out)

def insert_into_server_name(text, marker, domain):
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if marker in ln:
            lines.insert(i, "\t\t%s" % domain)
            break
    else:
        raise RuntimeError("server_name marker not found: %s" % marker)
    return "\n".join(lines)

if map_name:
    entry = "\t%s      %s;" % (domain, root or target)
    text = insert_into_map(text, map_name, entry)
text = insert_into_server_name(text, marker, domain)

with open(filepath, "w") as fh:
    fh.write(text)
print("  -> edited %s" % filepath)
PY

# ---- 2. Create web root + logs ----
case "$TYPE" in
  laravel|static)   ROOT="/var/www/$DOMAIN/public" ;;
  static-spa)       ROOT="/var/www/$DOMAIN/public_html" ;;
  *)                ROOT="" ;;
esac
if [ -n "$ROOT" ]; then
  mkdir -p "$ROOT" "/var/www/$DOMAIN/logs"
  echo "  -> created $ROOT and /var/www/$DOMAIN/logs"
  "$PWD/scripts/fix-perms.sh" "/var/www/$DOMAIN"
fi

# ---- 3. Database for laravel / wordpress ----
if [ "$TYPE" = "laravel" ] || [ "$TYPE" = "wordpress" ]; then
  [ -f .env ] || cp .env.example .env
  DB_USER="$DOMAIN"
  DB_PASS="$(openssl rand -hex 16)"
  DB_KEY="SITE_DB_PASSWORD_$(echo "$DOMAIN" | tr '[:lower:].-' '[:upper:]___')"
  # Store the password in .env (idempotent).
  if ! grep -q "^$DB_KEY=" .env; then
    printf '%s=%s\n' "$DB_KEY" "$DB_PASS" >> .env
  fi
  sed "s/<domain>/$DOMAIN/g; s/<password>/$DB_PASS/g" maria/init/example.sql > "maria/init/$DOMAIN.sql"
  echo "  -> wrote maria/init/$DOMAIN.sql (password saved in .env as $DB_KEY)"
fi

# ---- 4. Validate + reload ----
if command -v nginx >/dev/null 2>&1; then
  nginx -t
  nginx -s reload
elif podman ps --format '{{.Names}}' | grep -q "^$CONTAINER_NGINX$"; then
  podman exec "$CONTAINER_NGINX" nginx -t
  podman exec "$CONTAINER_NGINX" nginx -s reload
else
  echo "  !! nginx not running here — run nginx -t and reload on the server."
fi

echo
echo "Site added: $DOMAIN ($TYPE)"
echo "Next steps:"
echo "  - sudo ./scripts/certbot-issue.sh   (add the domain to certbot/domains.txt if new)"
echo "  - point DNS at this host, then reload nginx."