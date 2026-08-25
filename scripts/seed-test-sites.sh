#!/usr/bin/env bash
# =============================================================================
# seed-test-sites.sh — create fake TEMPORARY placeholder pages in every web
# root the nginx config references that doesn't already contain an index file.
#
# Purpose: on a fresh/test server the sites haven't been migrated in yet, so
# every configured domain would 404. This drops a small placeholder into each
# empty root so any hostname resolves to a "temporary test site" page instead.
#
# Safe: never overwrites an existing index file, idempotent, and harmless on
# production (real sites already have content, so they're skipped).
#
#   sudo ./scripts/seed-test-sites.sh     (also called by deploy.sh)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

PLACEHOLDER='<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Temporary test site</title></head>
<body style="font-family:system-ui,sans-serif;margin:3rem auto;max-width:40rem">
<h1>Temporary test site</h1>
<p>This placeholder was created because the real site content has not been
deployed yet (fresh or test server).</p>
</body>
</html>'

# Every web root the config references (roots end in /public or /public_html).
ROOTS="$(grep -rhoE '/var/www/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*' \
           nginx/nginx.conf nginx/conf.d 2>/dev/null \
         | grep -E '/public(_html)?$' | sort -u)"

created=0
skipped=0
while IFS= read -r root; do
  [ -n "$root" ] || continue
  if find "$root" -maxdepth 1 -type f \( -name 'index.html' -o -name 'index.php' -o -name 'index.htm' \) 2>/dev/null | grep -q .; then
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$root"
  printf '%s\n' "$PLACEHOLDER" > "$root/index.html"
  # index.php too, so PHP-only vhosts (e.g. the WordPress block) serve it.
  printf '<?php header("Content-Type: text/html; charset=utf-8"); ?>\n%s\n' "$PLACEHOLDER" > "$root/index.php"
  created=$((created + 1))
done <<< "$ROOTS"

echo "Seeded $created temporary placeholder site(s); $skipped already had content."