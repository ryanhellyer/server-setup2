#!/usr/bin/env bash
# =============================================================================
# lib-paths.sh — resolve where the SITE FILES live on the host.
#
# Sites live under the admin user's home (default ~/www) instead of /var/www,
# so they sit on the persistent home partition and survive a move to an atomic
# / immutable distro (e.g. Fedora Silverblue) where /var is best left to the OS.
#
# The containers still see the same files at /var/www: compose.yaml mounts
#   ${WWW_ROOT:-/home/ryan/www}:/var/www
# so the nginx config (nginx/conf.d/*.conf) and the container images are
# UNCHANGED — they keep referring to /var/www. Only host-side scripts care
# about the real location.
#
#   source scripts/lib-paths.sh
#   WWW_ROOT="$(resolve_www_root)"     # call AFTER .env is loaded
#
# Override the location with WWW_ROOT in .env.
# =============================================================================

# Path as seen INSIDE the containers. Must match compose.yaml's mount target and
# the roots referenced by nginx/conf.d. Do not change without editing those.
CONTAINER_WWW="/var/www"

# Print the host web root. Precedence: $WWW_ROOT (from .env) > the admin user's
# home (~/www) resolved from $SUDO_USER, then ryan, then the current user.
resolve_www_root() {
  if [ -n "${WWW_ROOT:-}" ]; then printf '%s' "$WWW_ROOT"; return 0; fi
  local user home
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    user="$SUDO_USER"
  elif id ryan >/dev/null 2>&1; then
    user="ryan"
  else
    user="$(id -un)"
  fi
  home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
  [ -n "$home" ] || home="${HOME:-/root}"
  printf '%s' "$home/www"
}

# Map a container path (/var/www[/...]) to its host location ($WWW_ROOT[...]).
# Non-/var/www paths are returned unchanged.
www_host_path() {
  local p="$1"
  case "$p" in
    "$CONTAINER_WWW")   printf '%s' "$WWW_ROOT" ;;
    "$CONTAINER_WWW"/*) printf '%s/%s' "$WWW_ROOT" "${p#"$CONTAINER_WWW"/}" ;;
    *)                  printf '%s' "$p" ;;
  esac
}
