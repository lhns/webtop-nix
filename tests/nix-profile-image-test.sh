#!/usr/bin/env bash
# Software installation on the standalone image, against the real patched Nix and home-manager: the
# `nix profile` backends (ADR 0014), hooks and rollback, the software center's backend, an unfree app
# surviving a switch, and the starter template's lifecycle (upgrade from the frozen earlier template in
# tests/previous-template, notices, relock, webtop-home-manager-update). Needs network access to substitute.
#
# Usage: nix-profile-image-test.sh <image> <timeout-seconds>
set -euo pipefail

image=$1
timeout=$2
here=$(cd "$(dirname "$0")" && pwd)
# The runner is native, so this is the image's system too.
nixsys=$(uname -m)-linux
c=webtop-profile
fail() { echo "::error::$*"; docker logs "$c" 2>&1 | tail -n 80; exit 1; }
x() { docker exec "$c" "$@"; }
as_user() { x runuser -u user -- env HOME=/home/user PATH=/home/user/.nix-profile/bin:/home/user/.local/state/nix/profiles/profile/bin:/run/current-system/sw/bin XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$@"; }

docker rm -f "$c" >/dev/null 2>&1 || true
vol=webtop-profile-home pvol=webtop-profile-persist
docker volume rm "$vol" "$pvol" >/dev/null 2>&1 || true
docker run -d --name "$c" --privileged --cgroupns=private --shm-size=1g -v "$vol:/home" -v "$pvol:/persist" "$image" >/dev/null
trap 'docker rm -f "$c" >/dev/null 2>&1 || true; docker volume rm "$vol" "$pvol" >/dev/null 2>&1 || true' EXIT

deadline=$(($(date +%s) + timeout))
wait_for() { # <what> <command...>
  local what=$1; shift
  until "$@" >/dev/null 2>&1; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || fail "the container exited"
    [ "$(date +%s)" -lt "$deadline" ] || fail "no $what within ${timeout}s"
    sleep 3
  done
}
compositing() { as_user busctl --user get-property org.kde.KWin /Compositor org.kde.kwin.Compositing active | grep -qx 'b true'; }
wait_for "KWin compositing" compositing

# Until the setup unit's run ends; a unit that has not run yet also has Result=success.
unit_prop() { x systemctl show -P "$1" webtop-home-manager; }
wait_setup() {
  for _ in $(seq 1 150); do
    [ "$(unit_prop ActiveState)" = active ] || [ "$(unit_prop ExecMainExitTimestampMonotonic)" = 0 ] || return 0
    sleep 2
  done
}
decl=/home/user/.config/home-manager/packages.json
hmdir=/home/user/.config/home-manager
wait_setup
[ "$(unit_prop Result)" = success ] \
  || { x journalctl -u webtop-home-manager --no-pager | tail -n 50; fail "webtop-home-manager failed"; }

! x sh -c 'command -v discover' || fail "Discover is installed"
grep -q -- -knewstuff- <<<"$(x nix-store -qR /run/current-system)" || fail "KNewStuff is not in the system"
[ "$(as_user sh -c 'command -v nix')" = /run/current-system/sw/bin/nix ] || fail "nix on the user's PATH is not the system's"
backend=$(as_user nix config show profile-backend)
[ "$backend" = "declaration:$decl" ] || fail "profile-backend is '$backend'"
as_user nix profile add nixpkgs#hello || fail "nix profile add nixpkgs#hello failed"
as_user jq -e '.elements.hello.originalUrl == "flake:nixpkgs"' "$decl" >/dev/null || fail "hello is not in packages.json"
as_user hello >/dev/null || fail "hello is not on PATH after the switch"
out=$(as_user nix profile list 2>&1)
{ grep -q 'hello' <<<"$out" && grep -q 'Backend: *declaration' <<<"$out"; } || fail "nix profile list: $out"
! grep -qE 'ignoring (the client-specified|untrusted)' <<<"$out" || fail "the daemon got the client-side settings: $out"
as_user nix profile list --json | jq -e '.elements.hello.backend == "declaration"
  and (.elements | to_entries | any(.value.backend == "profile" and (.value.storePaths[0] // "" | endswith("home-manager-path"))))' >/dev/null \
  || fail "nix profile list --json is not marked or lacks home-manager-path"
as_user home-manager switch --flake /home/user/.config/home-manager >/dev/null || fail "a direct home-manager switch failed"
as_user nix profile remove hello || fail "nix profile remove hello failed"
! as_user jq -e '.elements.hello' "$decl" >/dev/null || fail "hello is still in packages.json"
! as_user sh -c 'command -v hello' >/dev/null || fail "hello is still installed"
# Not piped into grep -q: with pipefail, nix dying of SIGPIPE fails the pipeline.
out=$(as_user nix profile history)
grep -q 'hello' <<<"$out" || fail "nix profile history does not show hello: $out"
as_user nix profile rollback || fail "nix profile rollback failed"
as_user hello >/dev/null || fail "rollback did not bring hello back"
sum=$(as_user sha256sum "$decl")
! as_user nix profile remove --profile-hook /run/current-system/sw/bin/false hello 2>/dev/null || fail "a failing hook did not fail"
[ "$(as_user sha256sum "$decl")" = "$sum" ] || fail "a failing hook did not restore packages.json"
out=$(as_user nix profile remove --profile-hook '' hello 2>&1 || true)
grep -q "needs 'profile-hook'" <<<"$out" || fail "an empty hook was accepted: $out"
# Store paths and explicit profiles bypass the declaration.
jqpath=$(as_user sh -c 'dirname "$(dirname "$(readlink -f /run/current-system/sw/bin/jq)")"')
as_user nix profile add "$jqpath" || fail "adding a store path failed"
as_user nix profile list --json | jq -e '.elements.jq.backend == "profile"' >/dev/null || fail "the store path is not in the profile"
as_user nix profile remove jq || fail "removing the store path failed"
{ as_user nix profile add --profile-backend profile "$jqpath" && as_user nix profile remove --profile-backend profile jq; } \
  || fail "--profile-backend profile failed"
! as_user nix profile add --profile-backend profile --profile-hook /run/current-system/sw/bin/false "$jqpath" 2>/dev/null \
  || fail "a failing hook did not fail a profile change"
! as_user nix profile list --profile-backend profile --json | jq -e '.elements.jq' >/dev/null \
  || fail "a failing hook did not roll the profile back"
{ as_user nix profile add --profile /tmp/ci-profile nixpkgs#hello && as_user test -x /tmp/ci-profile/bin/hello; } \
  || fail "--profile <path> failed"
[ "$(as_user sha256sum "$decl")" = "$sum" ] || fail "a profile backend changed packages.json"
out=$(as_user nix profile list --profile /tmp/ci-profile --profile-backend profile 2>&1 || true)
grep -q 'cannot be used together' <<<"$out" || fail "--profile with --profile-backend was accepted: $out"
# A profile element of the same name moves into the declaration.
as_user nix profile add --profile-backend profile "$jqpath" || fail "adding jq to the profile failed"
as_user nix profile add nixpkgs#jq || fail "adding nixpkgs#jq failed"
as_user jq -e '.elements.jq' "$decl" >/dev/null || fail "jq is not declared"
! as_user nix profile list --profile-backend profile --json | jq -e '.elements.jq' >/dev/null || fail "jq is still in the profile"
as_user nix profile remove jq >/dev/null || fail "removing the declared jq failed"
# --all matches the declaration only: upgrade does not look at home-manager-path.
out=$(as_user nix profile upgrade --all 2>&1) || fail "nix profile upgrade --all failed: $out"
! grep -q 'not added from a flake' <<<"$out" || fail "upgrade --all reached the profile: $out"
# A store path may not shadow a declared package.
out=$(as_user nix profile add "$(as_user sh -c 'dirname "$(dirname "$(readlink -f "$(command -v hello)")")"')" 2>&1 || true)
grep -q 'is declared in the declaration' <<<"$out" || fail "a store path shadowing a declared package was accepted: $out"
# One command, two backends: when the declaration's hook fails, the profile change is undone too.
as_user sh -c 'printf "#!/bin/sh\n[ \"\$NIX_PROFILE_BACKEND\" != declaration ]\n" > /tmp/ci-decl-fails && chmod +x /tmp/ci-decl-fails'
sum=$(as_user sha256sum "$decl")
pcontents=$(as_user nix profile list --profile-backend profile --json | jq -S .elements)
! as_user nix profile add --profile-hook /tmp/ci-decl-fails "$jqpath" nixpkgs#tree 2>/dev/null \
  || fail "a failing declaration hook did not fail the command"
[ "$(as_user sha256sum "$decl")" = "$sum" ] || fail "packages.json changed although the command failed"
! as_user nix profile list --profile-backend profile --json | jq -e '.elements.jq' >/dev/null \
  || fail "the profile part of a failed command was kept"
# A revert is a commit of its own, so the contents come back under a new generation.
[ "$(as_user nix profile list --profile-backend profile --json | jq -S .elements)" = "$pcontents" ] || fail "the profile's contents did not come back"
as_user hello >/dev/null || fail "hello went missing in a failed command"
# Rollback right after a hand edit goes back to the last recorded version; the edit becomes a version.
as_user sh -c "jq '.elements.handedit = {originalUrl: \"flake:nixpkgs\", attrPath: \"legacyPackages.$nixsys.tree\"}' $decl > /tmp/ci-decl && cat /tmp/ci-decl > $decl"
as_user nix profile rollback || fail "rollback after a hand edit failed"
[ "$(as_user sha256sum "$decl")" = "$sum" ] || fail "rollback after a hand edit did not restore the recorded version"
hist=$(as_user nix profile history | sed 's/\x1b\[[0-9;]*m//g')
newest=$(grep -o '^Version [0-9]*' <<<"$hist" | tail -n1 | cut -d' ' -f2)
tail -n 3 <<<"$hist" | grep -q 'tree' || fail "the hand edit is not the newest version: $hist"
as_user nix profile rollback --to "$newest" || fail "rollback --to the hand edit failed"
as_user jq -e '.elements.handedit' "$decl" >/dev/null || fail "rollback --to did not restore the hand edit"
as_user nix profile remove handedit >/dev/null || fail "removing the hand edit failed"
# Packages from another flake (builtins.getFlake), including a quoted attribute name with a dot.
as_user sh -c 'mkdir -p /tmp/ci-flake && printf "%s\n" "{" "  inputs.nixpkgs.url = \"nixpkgs\";" \
  "  outputs = { nixpkgs, ... }: { packages.'"$nixsys"' = { ci-hello = nixpkgs.legacyPackages.'"$nixsys"'.hello;" \
  "    \"ci.dotted\" = nixpkgs.legacyPackages.'"$nixsys"'.hello; }; };" "}" > /tmp/ci-flake/flake.nix'
# Locked first: locking writes flake.lock into the directory, which changes its hash.
as_user nix flake lock path:/tmp/ci-flake || fail "locking the local flake failed"
as_user nix profile add path:/tmp/ci-flake#ci-hello 'path:/tmp/ci-flake#"ci.dotted"' \
  || fail "adding packages from a local flake failed"
as_user jq -e '[.elements[] | select(.originalUrl | startswith("path:"))] | length == 2' "$decl" >/dev/null \
  || fail "the local flake's packages are not declared: $(as_user cat "$decl")"
as_user nix profile remove --regex '.*ci-flake.*' >/dev/null || fail "removing the local flake's packages failed"
# A flake dir that is a git repo: packages.json is added with --intent-to-add; a git-ignored one is refused.
as_user sh -c "cd $hmdir && git init -q && git add -A && git rm -q --cached packages.json"
as_user nix profile add nixpkgs#tree || fail "nix profile add in a git flake dir failed"
grep -qx packages.json <<<"$(as_user git -C "$hmdir" ls-files)" || fail "packages.json was not added to git"
as_user sh -c "cd $hmdir && echo packages.json > .gitignore && git rm -q --cached packages.json"
sum=$(as_user sha256sum "$decl")
out=$(as_user nix profile remove tree 2>&1 || true)
grep -q 'git ignores' <<<"$out" || fail "a git-ignored packages.json was not refused: $out"
[ "$(as_user sha256sum "$decl")" = "$sum" ] || fail "a refused change was not reverted"
as_user rm -rf "$hmdir/.git" "$hmdir/.gitignore"
as_user nix profile remove tree >/dev/null || fail "removing tree failed"
# The software center's backend against the patched Nix, next to a declared element it must leave alone.
as_user nix profile add nixpkgs#tree || fail "adding tree failed"
nsc=$(as_user sh -c 'readlink -f "$(command -v nix-software-center)"')
smoke=$(dirname "$(dirname "$nsc")")/libexec/nix-software-center/nsc-backend-smoke
as_user "$smoke" nixpkgs#cowsay --require-progress || fail "software center backend smoke failed"
as_user nix profile list --json | jq -e '.elements.tree.backend == "declaration" and (.elements.cowsay == null)' >/dev/null || fail "the smoke disturbed the declaration: $(as_user nix profile list --json)"
as_user nix profile remove tree >/dev/null || fail "removing tree after the smoke failed"
# An unfree app (nixpkgs-unfree) survives a switch although its recorded url no longer exists: the
# switch rebuilds it from the image's nixpkgs, with no prompt (stdin is closed) and no --impure.
as_user nix profile add nixpkgs-unfree#hello-unfree || fail "nix profile add nixpkgs-unfree#hello-unfree failed"
as_user jq -e '.elements["hello-unfree"].originalUrl == "flake:nixpkgs-unfree"' "$decl" >/dev/null   || fail "hello-unfree is not declared as flake:nixpkgs-unfree: $(as_user cat "$decl")"
as_user hello-unfree >/dev/null || fail "hello-unfree is not on PATH after the add"
as_user sh -c "jq '.elements[\"hello-unfree\"].url = \"path:/nonexistent/old-unfree-flake\"' $decl > /tmp/ci-decl && cat /tmp/ci-decl > $decl"
as_user jq -e '.elements["hello-unfree"].url == "path:/nonexistent/old-unfree-flake"' "$decl" >/dev/null || fail "the recorded url was not broken"
out=$(as_user timeout 900 home-manager switch --flake /home/user/.config/home-manager 2>&1)   || fail "home-manager switch with a stale unfree url failed: $out"
grep -qiE 'prompt|allowUnfree|--impure|refusing to evaluate' <<<"$out" && fail "the unfree restore complained: $out"
as_user hello-unfree >/dev/null || fail "hello-unfree is gone after the switch with a stale url"
as_user nix profile remove hello-unfree >/dev/null || fail "removing hello-unfree failed"
! as_user sh -c 'command -v hello-unfree' >/dev/null || fail "hello-unfree is still installed"
out=$(as_user nix eval --impure --raw --expr 'toString <nixpkgs>' 2>&1) || fail "<nixpkgs> does not resolve: $out"
grep -q 'search path entry' <<<"$out" && fail "nix warns about the search path: $out"
# The starter template's lifecycle. Files are written from the host (docker cp does not see /home, a
# bind mount); the previous template is frozen in previous-template/ (it imported packages.nix).
pdir=$hmdir
wst=/home/user/.local/state/webtop
put() { as_user sh -c "echo $(base64 -w0 <<<"$2") | base64 -d > $1"; }
prev() { sed -e 's|@user@|user|g' -e "s|@system@|$nixsys|g" "$here/previous-template/$1"; }
lock() { as_user cat "$hmdir/flake.lock"; }
# The previous template as the template unit wrote it (hashes recorded).
write_prev() {
  put /tmp/prev-flake.nix "$(prev flake.nix)"
  put /tmp/prev-packages.nix "$(prev packages.nix)"
  as_user webtop-template write $pdir/flake.nix /tmp/prev-flake.nix
  as_user webtop-template write $pdir/packages.nix /tmp/prev-packages.nix
}
# One run of the template unit: its journal.
tmpl() {
  sleep 1 # --since has second resolution
  local since
  since=$(x date '+%Y-%m-%d %H:%M:%S')
  x systemctl restart webtop-home-manager-template
  x journalctl -u webtop-home-manager-template --since "$since" -o cat
}
now() { sleep 1; x date '+%Y-%m-%d %H:%M:%S'; }
run_setup() {
  x systemctl start webtop-home-manager
  wait_setup
  [ "$(x systemctl show -P Result webtop-home-manager)" = success ] \
    || { x journalctl -u webtop-home-manager --no-pager | tail -n 50; fail "webtop-home-manager failed"; }
}
setup_log() { x journalctl -u webtop-home-manager --since "$1" --no-pager -o cat; }
as_user test ! -e $pdir/packages.nix || fail "the starter has a packages.nix"
as_user grep -qF 'flake:webtop' $pdir/flake.nix || fail "the starter does not use the webtop module"

# The previous template, recorded by hash, is upgraded without asking: packages.nix goes, packages.json
# stays, and the flake is locked for the new input.
as_user jq -e ".elements.hello" "$decl" >/dev/null || fail "hello is not declared before the upgrade"
write_prev
put $hmdir/flake.lock "$(lock | jq 'del(.nodes.root.inputs.webtop) | del(.nodes.webtop)')"
sum=$(as_user sha256sum "$decl")
out=$(tmpl)
grep -q 'rewrote the starter flake' <<<"$out" || fail "the previous template was not upgraded: $out"
as_user test ! -e $pdir/packages.nix || fail "the upgrade left packages.nix"
! as_user grep -q 'packages.nix' $wst/templates.sha256 || fail "packages.nix's hash was not forgotten"
as_user grep -qF 'flake:webtop' $pdir/flake.nix || fail "the upgrade did not write the new flake"
[ "$(as_user sha256sum "$decl")" = "$sum" ] || fail "the upgrade changed packages.json"
run_setup
as_user hello >/dev/null || fail "hello is gone after the upgrade"
lock | jq -e '.nodes.root.inputs.webtop' >/dev/null || fail "the upgrade did not lock webtop"
lock | jq -e '.nodes.defaults.locked.type == "path" and .nodes.defaults.locked.path == "/run/webtop/defaults"' >/dev/null || fail "the upgrade did not lock the defaults input"

# A failing switch fails the unit and says so.
as_user sh -c "cp $decl /tmp/decl.bak && jq '.elements.broken = {originalUrl: \"flake:nixpkgs\", attrPath: \"legacyPackages.$nixsys.noSuchPackageCi\"}' /tmp/decl.bak > $decl"
gen=/home/user/.local/state/nix/profiles/home-manager
link=$(as_user readlink "$gen")
as_user ln -sfn /nix/store/00000000000000000000000000000000-gone "$gen"
since=$(now)
x systemctl start webtop-home-manager
wait_setup
[ "$(x systemctl show -P Result webtop-home-manager)" = exit-code ] || fail "a failing switch did not fail the unit"
grep -q 'home-manager switch failed' <<<"$(x journalctl -u webtop-home-manager --no-pager)" \
  || fail "a failing switch was not reported"
as_user cp /tmp/decl.bak "$decl"
as_user ln -sfn "$link" "$gen"

# local.nix is the user's: the flake imports it when present.
put $hmdir/local.nix '{ home.file.".ci-local-nix".text = "ok"; }'
as_user home-manager switch --flake $hmdir >/dev/null || fail "a switch with local.nix failed"
as_user test -e /home/user/.ci-local-nix || fail "local.nix was not picked up"

# Settings for an installed package (ADR 0016): a mapping applies while the package is declared, and
# webtop.packages.replaced lets it install its own build without a collision.
mapping() { # <body>
  put $hmdir/local.nix "{ config, lib, pkgs, ... }: lib.mkIf (config.webtop.packages.installed ? \"nixpkgs#hello\") { $1 }"
}
own='home.file.".ci-mapping".text = "ok"; home.packages = [ (pkgs.writeShellScriptBin "hello" "echo mapped") ];'
as_user nix profile remove hello >/dev/null || fail "removing hello failed"
mapping "$own"
out=$(as_user nix profile add nixpkgs#hello 2>&1) && fail "a colliding mapping did not fail the add"
grep -q 'webtop.packages.replaced' <<<"$out" || fail "the collision gives no hint: $out"
! as_user jq -e '.elements.hello' "$decl" >/dev/null || fail "a failed add kept hello in packages.json"
mapping "$own webtop.packages.replaced = [ \"nixpkgs#hello\" ];"
as_user nix profile add nixpkgs#hello >/dev/null || fail "adding hello with a mapping failed"
as_user test -e /home/user/.ci-mapping || fail "the mapping did not apply"
[ "$(as_user hello)" = mapped ] || fail "the declared hello was not replaced by the mapping's"
as_user nix profile remove hello >/dev/null || fail "removing hello with a mapping failed"
as_user test ! -e /home/user/.ci-mapping || fail "the mapping outlived the package"
# A mapping that breaks while installed (a bad value) does not block removing its package. One that sets
# an option that does not exist fails every switch, mkIf or not, and the error names it.
as_user nix profile add nixpkgs#hello >/dev/null || fail "adding hello failed"
mapping 'home.file.".ci-mapping".text = 42;'
! as_user home-manager switch --flake $hmdir >/dev/null 2>&1 || fail "a broken mapping did not fail the switch"
as_user nix profile remove hello >/dev/null || fail "a broken mapping blocked removing its package"
mapping 'programs.noSuchProgramCi.enable = true;'
out=$(as_user nix profile add nixpkgs#hello 2>&1) && fail "a mapping setting a missing option did not fail"
grep -q 'noSuchProgramCi. does not exist' <<<"$out" && grep -q 'local.nix' <<<"$out" \
  || fail "the error does not name the option and file: $out"
put $hmdir/local.nix '{ home.file.".ci-local-nix".text = "ok"; }'

# A `webtop` input locked to another store path is relocked, although that path is valid.
want=$(lock | jq -r '.nodes.webtop.locked.path')
sri=$(as_user nix hash convert --hash-algo sha256 --to sri "$(as_user nix-store -q --hash "$jqpath")")
put $hmdir/flake.lock "$(lock | jq --arg p "$jqpath" --arg h "$sri" '.nodes.webtop.locked |= (.path = $p | .narHash = $h)')"
since=$(now)
run_setup
grep -q 'relocking stale inputs: webtop' <<<"$(setup_log "$since")" || fail "the stale webtop input was not relocked"
[ "$(lock | jq -r '.nodes.webtop.locked.path')" = "$want" ] || fail "webtop is not locked to the image's flake again"
since=$(now)
run_setup
! grep -q 'relocking' <<<"$(setup_log "$since")" || fail "an up-to-date lock was relocked"

# webtop-home-manager-update: without arguments nothing changes; --apply backs up, installs the
# template as unmodified and switches; a failing switch puts files and hashes back.
files() { as_user sh -c "cd $hmdir && sha256sum flake.nix home.nix packages.json local.nix && ls"; }
put $hmdir/flake.nix "$(as_user cat $hmdir/flake.nix)"$'\n# mine'
before=$(files)
out=$(as_user webtop-home-manager-update) || fail "webtop-home-manager-update failed: $out"
grep -q '^-# mine' <<<"$out" || fail "the update diff does not show the edit: $out"
[ "$(files)" = "$before" ] || fail "webtop-home-manager-update without --apply changed files"
pj=$(as_user sha256sum "$decl")
lj=$(as_user sha256sum $hmdir/local.nix)
out=$(as_user webtop-home-manager-update --apply 2>&1) || fail "--apply failed: $out"
as_user webtop-template unmodified $pdir/flake.nix || fail "the applied template does not count as unmodified"
! as_user grep -q '# mine' $hmdir/flake.nix || fail "--apply kept the edit"
as_user sh -c "grep -qx '# mine' $hmdir/flake.nix.bak-*" || fail "--apply made no backup of the edited flake"
! as_user sh -c "ls $hmdir/home.nix.bak-*" 2>/dev/null || fail "--apply backed up an unchanged home.nix"
[ "$(as_user sha256sum "$decl")" = "$pj" ] && [ "$(as_user sha256sum $hmdir/local.nix)" = "$lj" ] \
  || fail "--apply touched packages.json or local.nix"
put $hmdir/flake.nix "$(as_user cat $hmdir/flake.nix)"$'\n# mine'
flake=$(as_user sha256sum $hmdir/flake.nix)
hashes=$(as_user sha256sum $wst/templates.sha256)
as_user sh -c "jq '.elements.broken = {originalUrl: \"flake:nixpkgs\", attrPath: \"legacyPackages.$nixsys.noSuchPackageCi\"}' /tmp/decl.bak > $decl"
! as_user webtop-home-manager-update --apply >/dev/null 2>&1 || fail "--apply did not fail with a failing switch"
[ "$(as_user sha256sum $hmdir/flake.nix)" = "$flake" ] || fail "a failing --apply did not restore flake.nix"
[ "$(as_user sha256sum $wst/templates.sha256)" = "$hashes" ] || fail "a failing --apply did not restore the hashes"
as_user cp /tmp/decl.bak "$decl"

# An edited flake that still imports packages.nix keeps working untouched; the new template is
# announced once.
put $hmdir/flake.nix "$(prev flake.nix)"$'\n# mine'
put $hmdir/packages.nix "$(prev packages.nix)"
files() { as_user sh -c "cd $hmdir && sha256sum flake.nix home.nix packages.nix packages.json"; }
before=$(files)
out=$(tmpl)
grep -q 'webtop-home-manager-update' <<<"$out" || fail "no notice for an edited flake: $out"
[ "$(files)" = "$before" ] || fail "an edited flake was changed"
out=$(tmpl)
! grep -q 'webtop-home-manager-update' <<<"$out" || fail "the notice repeats: $out"
as_user home-manager switch --flake $hmdir >/dev/null || fail "the edited flake with packages.nix does not switch"
as_user nix profile add nixpkgs#tree || fail "nix profile add through packages.nix failed"
as_user jq -e '.elements.tree' "$decl" >/dev/null || fail "tree is not in packages.json"
as_user nix profile remove tree >/dev/null || fail "removing tree failed"

# An unmodified old flake with an edited packages.nix is held: nothing renamed or removed, announced once.
write_prev
put $hmdir/packages.nix "$(prev packages.nix)"$'
# mine'
as_user rm -f $wst/template-notified
files() { as_user sh -c "cd $hmdir && sha256sum flake.nix home.nix packages.nix packages.json"; }
before=$(files)
out=$(tmpl)
grep -q 'packages.nix is edited' <<<"$out" || fail "no notice for an edited packages.nix: $out"
! grep -q 'rewrote' <<<"$out" || fail "a starter was upgraded over an edited packages.nix: $out"
[ "$(files)" = "$before" ] || fail "an edited packages.nix was renamed, removed or rewritten"
out=$(tmpl)
! grep -q 'webtop-home-manager-update' <<<"$out" || fail "the packages.nix notice repeats: $out"

# A nix.conf of the user's own: the starter is not upgraded (the new module would write that file).
write_prev
as_user sh -c "rm -f /home/user/.config/nix/nix.conf $wst/template-notified && echo '# own' > /home/user/.config/nix/nix.conf"
out=$(tmpl)
! grep -q 'rewrote' <<<"$out" || fail "a flake was upgraded over the user's nix.conf: $out"
grep -q 'nix.conf' <<<"$out" || fail "no notice about the user's nix.conf: $out"
as_user grep -qF './packages.nix' $hmdir/flake.nix || fail "the flake was upgraded over the user's nix.conf"
echo "nix profile image test: ok"
