# Copies the admin's defaults directory (services.webtop.defaults.source) to a root-owned snapshot, so
# its content is fixed for the life of the container: a ConfigMap update reaches the mount live.
#   webtop-defaults <source> <snapshot>
# Keeps session.conf, xdg/ and home.nix. Never fails on bad content: what is unusable is dropped
# and logged, and the desktop starts with the module's own defaults.
# A home.nix that does not parse also leaves a notice for the user (title, then text) in
# <parent of snapshot>/defaults-notice, which webtop-defaults-notice.service shows.
src=$1 dst=$2

log() { echo "webtop-defaults: $*"; }

parent=$(dirname -- "$dst")
mkdir -p -- "$parent"
rm -f -- "$parent/defaults-notice"
tmp=$(mktemp -d -- "$parent/.defaults.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

if [ -d "$src" ]; then
  # -L: ConfigMap files are links through ..data.
  if cp -rL -- "$src"/. "$tmp"/; then
    find "$tmp" -mindepth 1 -maxdepth 1 ! -name session.conf ! -name xdg ! -name home.nix -exec rm -rf -- {} +
    find "$tmp" -mindepth 1 ! -type f ! -type d -delete
  else
    log "could not copy $src: using empty defaults"
    find "$tmp" -mindepth 1 -delete
  fi
else
  log "no defaults at $src"
fi

# webtop-locale owns this layer of the cascade.
if [ -e "$tmp/xdg/plasma-localerc" ]; then
  log "xdg/plasma-localerc is reserved: dropped"
  rm -f -- "$tmp/xdg/plasma-localerc"
fi

# A syntax error here would fail every user's home-manager switch.
if [ -f "$tmp/home.nix" ]; then
  if ! err=$(nix-instantiate --parse "$tmp/home.nix" 2>&1 >/dev/null); then
    log "home.nix does not parse, replaced by an empty module: $(printf '%s' "$err" | tr -d '\000-\010\013-\037\177' | head -c 300)"
    rm -f -- "$tmp/home.nix"
    printf '%s\n' "Admin defaults: home.nix ignored" \
      "It has a syntax error and is not applied to anyone's home-manager setup. Tell your administrator." >"$parent/defaults-notice"
  fi
fi
[ -f "$tmp/home.nix" ] || echo '{ }' >"$tmp/home.nix"

chown -R root:root "$tmp"
chmod -R u=rwX,go=rX "$tmp"
rm -rf -- "$dst.old"
if [ -e "$dst" ]; then mv -T -- "$dst" "$dst.old"; fi
mv -T -- "$tmp" "$dst"
trap - EXIT
rm -rf -- "$dst.old"
log "snapshot of $src at $dst"
