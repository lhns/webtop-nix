#!/usr/bin/env bash
# Pins the store overlay's layout on the volume (ADR 0013): existing desktops keep their volumes across
# the move of this code from kube-webtop-workspaces, with no migration. Runs webtop-nix-lower as an
# entrypoint would, with busybox alone on PATH, on a scratch directory, and compares the names it
# creates with the layout a volume made by the former code has. The overlay mount options are pinned in
# the script text (a mount needs root).
#
# Usage: store-overlay-layout-test.sh <storeOverlay.init> <busybox>
set -euo pipefail

init=$1
busybox=$2
export PATH=$busybox/bin
fail() { echo "FAIL: $*" >&2; exit 1; }
want() { # <what> <got> <expected>
  [ "$2" = "$3" ] || fail "$1: got
$2
expected
$3"
}

# --- the script text that cannot run here
store_init=$init/bin/webtop-store-init
grep -qxF 'N=/persist/nix' "$store_init" || fail "the default persist path is not /persist/nix"
grep -qxF 'LOWER=/.lower' "$store_init" || fail "the default lower root is not /.lower"
grep -qF '"lowerdir=$LOWER/nix/store,upperdir=$N/upper,workdir=$N/work,userxattr,index=off,xino=off"' "$store_init" \
  || fail "the overlay mount options changed"
grep -qF 'mkdir -p "$N/upper" "$N/work" "$N/var"' "$store_init" || fail "the directories prepared changed"
grep -qF 'mount --bind "$N/var" /nix/var/nix' "$store_init" || fail "the Nix state is not bound from \$N/var"
echo "mount script: ok"

# The defaults of the built scripts are the former code's (the runs below override them: a volume path is
# not writable here).
lower_script=$init/bin/webtop-nix-lower
partial_script=$init/bin/webtop-nix-partial
for l in 'STAMP_FILE=${STAMP_FILE:-/webtop-image-stamp}' 'N=${WEBTOP_NIX_PERSIST:-/persist/nix}' \
  'LOWER=${WEBTOP_LOWER_ROOT:-/.lower}' 'HOMES=${WEBTOP_HOMES_ROOT:-/home}' 'export N LOWER'; do
  grep -qxF "$l" "$lower_script" || fail "webtop-nix-lower lacks: $l"
done
for l in 'N=${N:-/persist/nix}' 'LOWER=${LOWER:-/.lower}'; do
  grep -qxF "$l" "$partial_script" || fail "webtop-nix-partial lacks: $l"
done
echo "script defaults: ok"

# --- webtop-nix-lower
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
n=$t/persist/nix
export STAMP_FILE=$t/stamp WEBTOP_NIX_PERSIST=$n WEBTOP_HOMES_ROOT=$t/persist/home WEBTOP_LOWER_ROOT=$t/lower
export PARTIAL=$t/partial
# What webtop-nix-partial does for the layout: --write-lower-paths saves "stamp <s>", the invalidation
# itself is what the case below makes of it (exit code).
cat > "$PARTIAL" <<EOS
#!$busybox/bin/sh
if [ "\$1" = --write-lower-paths ]; then echo "stamp \$2" > "\$WEBTOP_NIX_PERSIST/lower-paths"; exit 0; fi
exit \${PARTIAL_RC:-0}
EOS
chmod +x "$PARTIAL"
lower() { "$init/bin/webtop-nix-lower" 2>&1; }
names() { (cd "$1" && find . -mindepth 1 | sed 's|^\./||; s|trash-[0-9]*-reset|trash-N-reset|' | sort); }

echo s1 > "$t/stamp"
lower >/dev/null
want "first boot" "$(names "$n")" "lower-paths
lower-stamp"
want "stamp" "$(cat "$n/lower-stamp")" s1
want "paths list" "$(head -n1 "$n/lower-paths")" "stamp s1"
out=$(lower); [ -z "$out" ] || fail "an unchanged image logged: $out"
echo "first boot: ok"

# An image update the partial invalidation cannot handle: the overlay is reset, the restore is called for.
mkdir -p "$n/upper/x" "$n/work/w" "$n/var/db" "$n/var/gcroots/auto" "$n/var/profiles/per-user"
echo db > "$n/var/db/db.sqlite"
ln -s /nix/store/aaa-root "$n/var/gcroots/auto/r1"
ln -s /nix/store/bbb-profile-1-link "$n/var/profiles/per-user/p"
h=$t/persist/home/user/.local/state/nix/profiles
mkdir -p "$h" "$n/upper/ccc-profile"
ln -s profile-1-link "$h/profile"
ln -s /nix/store/ccc-profile "$h/profile-1-link"
echo '{"version":3}' > "$n/upper/ccc-profile/manifest.json"
touch "$n/partial.attempts" # left by an interrupted partial invalidation
echo s2 > "$t/stamp"
PARTIAL_RC=1 lower >/dev/null
want "reset" "$(names "$n")" "lower-paths
lower-stamp
reinstall
reinstall/pending
reinstall/restore
reinstall/user.manifest.json
trash-N-reset
trash-N-reset/junk
trash-N-reset/upper
trash-N-reset/upper/ccc-profile
trash-N-reset/upper/ccc-profile/manifest.json
trash-N-reset/upper/x
trash-N-reset/var
trash-N-reset/var/db
trash-N-reset/var/db/db.sqlite
trash-N-reset/var/gcroots
trash-N-reset/var/gcroots/auto
trash-N-reset/var/gcroots/auto/r1
trash-N-reset/var/profiles
trash-N-reset/var/profiles/per-user
trash-N-reset/var/profiles/per-user/p
trash-N-reset/work
trash-N-reset/work/w
var
var/gcroots
var/gcroots/auto
var/gcroots/auto/r1
var/profiles
var/profiles/per-user
var/profiles/per-user/p"
want "stamp after the reset" "$(cat "$n/lower-stamp")" s2
want "recorded manifest" "$(cat "$n/reinstall/user.manifest.json")" '{"version":3}'
echo "reset: ok"

# A fresh volume under a home that already has a profile: the reinstall is due, with the manifest the
# image's store has for it.
export WEBTOP_NIX_PERSIST=$t/fresh/nix
n=$WEBTOP_NIX_PERSIST
mkdir -p "$t/lower/nix/store/ccc-profile"
echo '{"version":3}' > "$t/lower/nix/store/ccc-profile/manifest.json"
echo s3 > "$t/stamp"
lower >/dev/null
want "fresh volume, existing home" "$(names "$n")" "lower-paths
lower-stamp
reinstall
reinstall/pending
reinstall/user.manifest.json"
echo "fresh volume under a home: ok"
