#!/usr/bin/env bash
# The starter's `defaults` input (README, "Software"; ADR 0015) on real Nix, stock and patched:
#   A3  a lockable non-store `path:` input with `flake = false` evaluates in a pure eval, its narHash is
#       verified, and a changed directory fails the evaluation until the input is relocked.
#   modules/nix-profile/webtop-home-manager.sh, with home-manager stubbed, relocks such an input when its
#       directory no longer hashes to the lock, switches then, and leaves the others alone.
# Usage: defaults-input-test.sh [<patched Nix out path>]. Needs jq and flock; offline.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
script=$repo/modules/nix-profile/webtop-home-manager.sh
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL  $*"; exit 1; }
ok() { echo "PASS  $*"; }

bins=("$(dirname "$(command -v nix)")")
if [ -n "${1:-}" ]; then bins+=("$1/bin"); fi

# A flake for an indirect input, which the script checks as a store path.
mkdir "$t/other"
echo '{ outputs = _: { }; }' > "$t/other/flake.nix"

n=0
for bin in "${bins[@]}"; do
  n=$((n + 1))
  w=$t/run$n
  echo "== $bin/nix $("$bin/nix" --version)"
  mkdir -p "$w/src" "$w/home/.config" "$w/bin"
  export PATH=$w/bin:$bin:$PATH HOME=$w/home XDG_CACHE_HOME=$w/cache W=$w
  hm=$HOME/.config/home-manager src=$w/src
  mkdir "$hm"
  export NIX_CONFIG="experimental-features = nix-command flakes
flake-registry = $w/registry.json
substituters ="
  other=$(nix store add --name other "$t/other")
  cat > "$w/registry.json" <<JSON
{ "version": 2, "flakes": [ { "from": { "type": "indirect", "id": "other" }, "to": { "type": "path", "path": "$other" } } ] }
JSON
  echo '{ marker = "one"; }' > "$src/home.nix"
  cat > "$hm/flake.nix" <<NIX
{
  inputs = {
    other.url = "other";
    defaults = { url = "path:$src"; flake = false; };
  };
  outputs = { defaults, ... }: { text = builtins.readFile "\${defaults}/home.nix"; };
}
NIX
  ev() { nix eval --raw "path:$hm#text" 2>"$w/err"; }
  locked() { jq -r '.nodes.defaults.locked.narHash' "$hm/flake.lock"; }

  nix path-info --all | sort > "$w/paths-before"
  nix flake lock "path:$hm" 2>"$w/err" || { cat "$w/err"; fail "locking a path input with flake = false"; }
  [ "$(jq -r '.nodes.defaults.locked.type' "$hm/flake.lock")" = path ] \
    && [ "$(jq -r '.nodes.defaults.locked.path' "$hm/flake.lock")" = "$src" ] \
    && [ "$(locked)" = "$(nix hash path --sri "$src")" ] \
    || fail "the lock entry is not type path with narHash = nix hash path --sri: $(jq -c .nodes.defaults "$hm/flake.lock")"
  [ "$(ev)" = '{ marker = "one"; }' ] || { cat "$w/err"; fail "a pure eval of the locked input"; }
  ok "A3: a locked path input with flake = false evaluates; its narHash is the directory's"

  # The directory changed, the lock did not.
  echo '{ marker = "two"; }' > "$src/home.nix"
  if out=$(ev); then fail "A3: the changed directory evaluated against the old lock: $out"; fi
  grep -qiE 'hash mismatch' "$w/err" || { cat "$w/err"; fail "A3: the evaluation failed, but not on the hash"; }
  ok "A3: a changed directory fails the evaluation on its narHash"
  # Without the old copy in the store, nothing can serve the old content either.
  nix path-info --all | sort | comm -13 "$w/paths-before" - > "$w/paths-new"
  echo "store paths from the first evaluation: $(paste -sd' ' "$w/paths-new")"
  xargs -r nix store delete < "$w/paths-new" || echo "note: the old copy could not be deleted"
  if out=$(ev); then fail "A3: the changed directory evaluated after the store was collected: $out"; fi
  ok "A3: also with the old copy gone from the store"

  # The script, with the stubs it needs. The apply lock re-executes it, so it is a file of its own.
  stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$w/bin/$1"; chmod +x "$w/bin/$1"; }
  stub home-manager 'echo "$*" >> "$W/switches"'
  stub webtop-restore-progress ':'
  stub webtop-notify ':'
  { echo '#!/usr/bin/env bash'; echo 'set -euo pipefail'; echo "WEBTOP_FLAKE=$w/none"; cat "$script"; } > "$w/bin/webtop-home-manager"
  chmod +x "$w/bin/webtop-home-manager"
  run() { : > "$w/switches"; webtop-home-manager > "$w/out" 2>&1 || { cat "$w/out"; fail "the script failed"; }; }

  # The lock still holds "one".
  run
  grep -qx 'relocking stale inputs: defaults' "$w/out" || { cat "$w/out"; fail "the changed directory was not relocked"; }
  [ "$(locked)" = "$(nix hash path --sri "$src")" ] || fail "the lock does not hold the directory's hash"
  [ "$(cat "$w/switches")" = "switch --flake $hm" ] || fail "no switch after a relock: $(cat "$w/switches")"
  [ "$(ev)" = '{ marker = "two"; }' ] || { cat "$w/err"; fail "the relocked input does not evaluate to the new content"; }
  ok "a changed directory is relocked, a switch follows, the new content evaluates"

  # Nothing changed; `other` (indirect, at a valid store path) is left alone too.
  before=$(cat "$hm/flake.lock")
  run
  ! grep -q relocking "$w/out" || { cat "$w/out"; fail "an unchanged lock was relocked"; }
  [ ! -s "$w/switches" ] || fail "a switch without a change"
  [ "$(cat "$hm/flake.lock")" = "$before" ] || fail "flake.lock changed without a reason"
  ok "unchanged inputs (path and indirect) are left alone"

  # The directory is gone: the relock fails, the lock stays and nothing is switched.
  mv "$src" "$w/src.gone"
  run
  grep -qx 'relocking failed; flake.lock is as it was' "$w/out" || { cat "$w/out"; fail "a missing directory did not report the failed relock"; }
  [ "$(cat "$hm/flake.lock")" = "$before" ] && [ ! -s "$w/switches" ] || fail "a failed relock changed the lock or switched"
  mv "$w/src.gone" "$src"
  ok "a missing directory: the relock fails, lock and generation stay"

  # A relative path input is not the script's to hash.
  mkdir "$hm/sub"
  echo '{ }' > "$hm/sub/home.nix"
  sed -i 's|other.url = "other";|other.url = "other"; rel = { url = "path:./sub"; flake = false; };|' "$hm/flake.nix"
  nix flake lock "path:$hm" 2>"$w/err" || { cat "$w/err"; fail "locking a relative path input"; }
  run
  ! grep -q relocking "$w/out" || { cat "$w/out"; fail "a relative path input was relocked"; }
  ok "a relative path input is left alone"
done
