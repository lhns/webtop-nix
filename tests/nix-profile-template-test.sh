#!/usr/bin/env bash
# The starter flake's template upgrade (modules/nix-profile), without Nix: unmodified flakes follow the
# template by recorded hash, edited ones are left alone. nix-profile-image-test.sh runs them on the image
# with a frozen earlier template.
set -euo pipefail
src=$(cd "$(dirname "$0")/../modules/nix-profile" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL  $*"; exit 1; }
ok() { echo "PASS  $*"; }

home=$t/storage/home
dir=$home/.config/home-manager
state=$home/.local/state/webtop
mkdir -p "$t/bin" "$t/seed" "$home"
# As the module runs them: $home ahead of the text, the template with its build-time values rendered.
for s in webtop-template webtop-home-manager-template; do
  { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo "home=$home"; cat "$src/$s.sh"; } > "$t/bin/$s"
  chmod +x "$t/bin/$s"
done
export PATH=$t/bin:$PATH WEBTOP_TEMPLATE_DIR=$t/seed USER=ci HOME=/home/ci WEBTOP_HOME_PATHS=
cp "$src/starter/packages.json" "$t/seed/"
seed() {
  sed -e 's/@system@/x86_64-linux/g' -e 's/@stateVersion@/26.05/g' "$src/starter/flake.nix" > "$t/seed/flake.nix"
  sed -e 's/@system@/x86_64-linux/g' -e 's/@stateVersion@/26.05/g' "$src/starter/home.nix" > "$t/seed/home.nix"
}
run() { webtop-home-manager-template; }
rendered() { sed -e 's/@user@/ci/g' -e 's|@home@|/home/ci|g' "$t/seed/$1"; }
is_current() { [ "$(cat "$dir/$1")" = "$(rendered "$1")" ]; }
seed

run
is_current flake.nix && is_current home.nix || fail "first boot did not write the starter"
grep -qxF "$(sha256sum < "$dir/flake.nix" | cut -d' ' -f1)  $dir/flake.nix" "$state/templates.sha256" \
  || fail "the hash is not keyed by the home's storage path"
[ -e "$state/home-manager-switch" ] || fail "first boot did not ask for a switch"
ok "first boot writes the starter, hashes keyed by the storage path"

# The starter imports the admin's home.nix through its `defaults` input.
grep -q 'url = "path:/run/webtop/defaults";' "$src/starter/flake.nix" && grep -qF '"${defaults}/home.nix"' "$src/starter/flake.nix" \
  || fail "the starter has no defaults input and module"
grep -q 'defaults' "$dir/flake.nix" || fail "the first boot's starter has no defaults input"

# The template before the `defaults` input, as that image rendered it (recorded by hash): unmodified,
# so it follows the template, and is current afterwards.
sed -e 's/@system@/x86_64-linux/g' -e 's/@user@/ci/g' -e 's|@home@|/home/ci|g' \
  "$(dirname "$0")/fixtures/starter-flake-before-defaults.nix" > "$t/before-defaults.nix"
! grep -q defaults "$t/before-defaults.nix" || fail "the fixture already has the defaults input"
rm "$state/home-manager-switch"
webtop-template write "$dir/flake.nix" "$t/before-defaults.nix"
run
is_current flake.nix || fail "the starter from before the defaults input was not upgraded"
grep -q 'path:/run/webtop/defaults' "$dir/flake.nix" || fail "the upgraded starter has no defaults input"
[ -e "$state/home-manager-switch" ] || fail "the upgrade did not ask for a switch"
rm "$state/home-manager-switch"
out=$(run)
{ [ -z "$out" ] && [ ! -e "$state/home-manager-switch" ] && is_current flake.nix; } || fail "the upgraded starter is not stable: $out"
ok "a starter from before the defaults input follows the template, then stays current"

# An earlier template, recorded by hash, with the packages.nix it imported.
rm -f "$state/home-manager-switch"
echo '# earlier template' > "$t/old-flake.nix"; echo 'old packages' > "$t/old-packages.nix"
webtop-template write "$dir/flake.nix" "$t/old-flake.nix"
webtop-template write "$dir/packages.nix" "$t/old-packages.nix"
echo '{ "version": 1, "elements": { "hello": {} } }' > "$dir/packages.json"
pj=$(sha256sum < "$dir/packages.json")
run
is_current flake.nix || fail "the unmodified earlier flake was not upgraded"
[ ! -e "$dir/packages.nix" ] || fail "the earlier packages.nix was not removed"
! grep -q packages.nix "$state/templates.sha256" || fail "packages.nix's hash was not forgotten"
[ "$(sha256sum < "$dir/packages.json")" = "$pj" ] || fail "the upgrade changed packages.json"
[ -e "$state/home-manager-switch" ] || fail "the upgrade did not ask for a switch"
ok "an unmodified earlier flake follows the template"

# A flake written under another storage path no longer counts as recorded.
webtop-template write "$dir/flake.nix" "$t/old-flake.nix"
sed -i "s|  $dir/flake.nix\$|  /other$dir/flake.nix|" "$state/templates.sha256"
sum=$(sha256sum < "$dir/flake.nix")
run
[ "$(sha256sum < "$dir/flake.nix")" = "$sum" ] || fail "a hash under another key still counted"
ok "hashes count only under their own key"

# Edited: kept, the user told once per template; local.nix never touched.
cp "$t/old-flake.nix" "$dir/flake.nix"; echo '# mine' >> "$dir/flake.nix"
echo '{ }' > "$dir/local.nix"
sum=$(sha256sum < "$dir/flake.nix")
rm -f "$state/template-notified"
out=$(run)
[ "$(sha256sum < "$dir/flake.nix")" = "$sum" ] || fail "an edited flake was changed"
grep -q 'webtop-home-manager-update' <<<"$out" || fail "no notice for an edited flake: $out"
out=$(run)
[ -z "$out" ] || fail "the notice repeats: $out"
[ "$(cat "$dir/local.nix")" = '{ }' ] || fail "local.nix was touched"
grep -q 'pathExists ./local.nix' "$src/starter/flake.nix" || fail "the starter does not import local.nix"
ok "an edited flake is kept, with one notice"

# Another login name in the home paths: the template rendered for it counts as unmodified.
for f in flake.nix home.nix; do
  sed -e 's/@user@/old/g' -e 's|@home@|/home/old|g' "$t/seed/$f" > "$dir/$f"
done
WEBTOP_HOME_PATHS=/home/old run >/dev/null
is_current flake.nix && is_current home.nix || fail "a rename did not rewrite the starter"
ok "a rename follows the template"
