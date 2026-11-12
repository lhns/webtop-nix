# Builds the image's NixOS system extended with an admin's module into <out>, for
# webtop-system-install to put into the stock image (ADR 0017, README "System module"). Runs in the
# builder image as root without a daemon: a Dockerfile RUN.
#   webtop-system-build <module.nix> [<out>]      <out> defaults to /webtop-system
# <out>: the new system's toplevel, its store paths the image lacks (store/) and their registration,
# the image's stamp, and the installer with a static busybox (the stock image has no shell).
# Set by the wrapper: flake, attr, imagePaths, installer, busybox, cacert.
module=$(realpath -- "$1")
out=${2:-/webtop-system}

log() { echo "webtop-system-build: $*" >&2; }

# A RUN has no /etc (no nix.conf, nixbld group or CA bundle) and no room for Nix's own sandbox.
export HOME=${HOME:-/tmp} NIX_SSL_CERT_FILE=${NIX_SSL_CERT_FILE:-$cacert}
export NIX_CONFIG="experimental-features = nix-command flakes
build-users-group =
sandbox = false
${NIX_CONFIG:-}"

export WEBTOP_FLAKE=$flake WEBTOP_ATTR=$attr WEBTOP_MODULE=$module
# shellcheck disable=SC2016
expr='let
  f = builtins.getFlake "path:${builtins.getEnv "WEBTOP_FLAKE"}";
  sys = f.nixosConfigurations.${builtins.getEnv "WEBTOP_ATTR"}.extendModules {
    modules = [ (/. + builtins.getEnv "WEBTOP_MODULE") ];
  };
in sys.config.system.build.toplevel'
log "building $attr of $flake with $module"
toplevel=$(nix build --impure --no-link --print-out-paths --expr "$expr")
log "built $toplevel"

tmp=$(mktemp -d)
nix-store -qR "$toplevel" | sort >"$tmp/closure"
sort "$imagePaths" >"$tmp/image"
comm -23 "$tmp/closure" "$tmp/image" >"$tmp/delta"

rm -rf -- "$out"
mkdir -p "$out/store" "$out/bin"
while IFS= read -r p; do cp -a -- "$p" "$out/store/"; done <"$tmp/delta"
: >"$out/registration"
if [ -s "$tmp/delta" ]; then xargs nix-store --dump-db <"$tmp/delta" >"$out/registration"; fi
printf '%s\n' "$toplevel" >"$out/toplevel"
cp /webtop-image-stamp "$out/image-stamp"
# The image's own Nix: the installer registers the paths with it.
dirname -- "$(command -v nix-store)" >"$out/nix-bin"
cp "$installer" "$out/install"
cp "$busybox/bin/busybox" "$out/bin/busybox"
for a in sh cat cp cut ln mv rm sha256sum readlink; do ln -s busybox "$out/bin/$a"; done
log "$(wc -l <"$tmp/delta") store paths for the image ($(du -sh "$out/store" | cut -f1)) in $out"
rm -rf -- "$tmp"
