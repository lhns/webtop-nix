#!/usr/bin/env bash
# The `nixpkgs-unfree` registry flake (modules/nix-profile/nixpkgs-unfree-flake) on real Nix: an unfree
# package installs with no --impure, is recorded as flake:nixpkgs-unfree, and packages.nix resolves it
# without the recorded store path. Needs `nix` and a built patched Nix (.#nix-profile-backends).
set -euo pipefail
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL  $*"; exit 1; }
ok() { echo "PASS  $*"; }

sys=$(nix eval --raw --impure --expr builtins.currentSystem)
attr=hello-unfree
nixpkgs=$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')
unfree=$(nix build .#nixpkgs-unfree-flake --no-link --print-out-paths)
for o in $(nix build .#nix-profile-backends --no-link --print-out-paths); do
  if [ -x "$o/bin/nix" ]; then patched=$o/bin/nix; fi
done

# As the module's flake-registry: the image's pins, offline.
cat > "$t/global.json" <<JSON
{ "version": 2, "flakes": [
  { "from": { "type": "indirect", "id": "nixpkgs" }, "to": { "type": "path", "path": "$nixpkgs" } },
  { "from": { "type": "indirect", "id": "nixpkgs-unfree" }, "to": { "type": "path", "path": "$unfree" } } ] }
JSON
export NIX_CONFIG="experimental-features = nix-command flakes
flake-registry = $t/global.json"
export HOME=$t/home; mkdir -p "$HOME"

nix eval "nixpkgs#legacyPackages.$sys.$attr.drvPath" >/dev/null 2>&1 && fail "plain nixpkgs accepts an unfree package"
ok "plain nixpkgs refuses $attr"
nix eval "nixpkgs-unfree#legacyPackages.$sys.$attr.drvPath" >/dev/null 2>"$t/err" \
  || { cat "$t/err"; fail "nixpkgs-unfree refuses $attr without --impure"; }
ok "nixpkgs-unfree evaluates $attr without --impure"

# nix profile add (patched, declaration backend) with a hook that accepts the change.
printf '#!/bin/sh\nexit 0\n' > "$t/hook"; chmod +x "$t/hook"
echo '{ "version": 1, "elements": {} }' > "$t/packages.json"
"$patched" profile add --profile-backend "declaration:$t/packages.json" --option profile-hook "$t/hook" \
  "nixpkgs-unfree#$attr" 2>"$t/err" || { cat "$t/err"; fail "nix profile add nixpkgs-unfree#$attr"; }
cat "$t/packages.json"
[ "$(jq -r '.elements[].originalUrl' "$t/packages.json")" = flake:nixpkgs-unfree ] \
  || fail "packages.json does not record flake:nixpkgs-unfree"
ok "nix profile add records flake:nixpkgs-unfree"

# The locked url names a store path that is gone, as after an image update.
jq '.elements[].url = "path:/nix/store/00000000000000000000000000000000-gone?narHash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D"' \
  "$t/packages.json" > "$t/gone.json"
name=$(nix eval --raw --impure --expr "
  let
    pkgs = import $nixpkgs { system = \"$sys\"; };
    m = import $PWD/modules/nix-profile/webtop-flake/packages.nix $t/gone.json { config.webtop.packages.replaced = [ ]; inherit (pkgs) lib; inherit pkgs; };
  in (builtins.head m.home.packages).name")
[ "$name" = "$(nix eval --raw --impure --expr "(import $nixpkgs { system = \"$sys\"; config.allowUnfree = true; }).$attr.name")" ] \
  || fail "packages.nix resolved '$name'"
ok "packages.nix resolves it without the recorded store path ($name)"
