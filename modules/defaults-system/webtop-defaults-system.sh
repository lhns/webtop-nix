# Builds the image's own NixOS system extended with the admin's system.nix (ADR 0016) into a profile,
# for webtop-defaults-boot to boot at the next start. Never changes the running system.
#   webtop-defaults-system <snapshot> <profile> <flake> <name> <notice>
# Rebuilds only when the image (its stamp) or system.nix changed since the last build; without a
# system.nix it removes the profile. A failed build leaves no profile and a notice for the user.
snap=$1 profile=$2 flake=$3 name=$4 notice=$5
module=$snap/system.nix
keyFile=$profile.key

log() { echo "webtop-defaults-system: $*"; }

if [ ! -f "$module" ]; then
  if [ -e "$keyFile" ] || [ -e "$profile" ]; then
    log "no system.nix: removing $profile"
    rm -f -- "$keyFile" "$profile" "$profile"-*-link
  fi
  exit 0
fi

# The same key as webtop-defaults-boot computes from the source: image stamp, then system.nix's hash.
key="$(cat "${STAMP_FILE:-/webtop-image-stamp}") $(sha256sum <"$module" | cut -d' ' -f1)"
if [ "$(cat -- "$keyFile" 2>/dev/null)" = "$key" ] && [ -e "$profile/init" ]; then
  log "up to date: $(readlink -f -- "$profile")"
  exit 0
fi

# A stale profile must not boot while this one builds; the key is written only after a build.
rm -f -- "$keyFile"
log "building $name of $flake with $module"
export WEBTOP_FLAKE=$flake WEBTOP_NAME=$name WEBTOP_MODULE=$module
# shellcheck disable=SC2016
expr='let
  f = builtins.getFlake "path:${builtins.getEnv "WEBTOP_FLAKE"}";
  sys = f.nixosConfigurations.${builtins.getEnv "WEBTOP_NAME"}.extendModules {
    modules = [ (/. + builtins.getEnv "WEBTOP_MODULE") ];
  };
in sys.config.system.build.toplevel'
if nix build --impure --profile "$profile" --expr "$expr"; then
  nix-env -p "$profile" --delete-generations old >/dev/null 2>&1 || true
  printf '%s\n' "$key" >"$keyFile.tmp" && mv -f -- "$keyFile.tmp" "$keyFile"
  log "built $(readlink -f -- "$profile"): booted at the next start"
  exit 0
fi

log "system.nix could not be built: the desktop keeps the image's system"
rm -f -- "$profile" "$profile"-*-link
text="system.nix could not be built and is not applied; the desktop runs the image's system. Tell your administrator."
if [ -s "$notice" ]; then
  printf '%s\n' "$text" >>"$notice"
else
  printf '%s\n' "Admin defaults: system.nix not applied" "$text" >"$notice"
fi
systemctl restart --no-block webtop-defaults-notice.service 2>/dev/null || true
exit 1
