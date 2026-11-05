#!/usr/bin/env bash
# Concurrent `nix profile` commands (ADR 0007) with the patched Nix, real builds and home-manager: every
# command ends with the declaration, the manifest and what is on PATH in agreement.
# Usage: nix-profile-concurrency.sh <patched Nix out path>. Needs network; home is a temporary one.
set -uo pipefail

nix_out=$1
repo=$(cd "$(dirname "$0")/.." && pwd)
rev() { jq -r ".nodes[\"$1\"].locked.rev" "$repo/flake.lock"; }
np=$(rev nixpkgs)
hm=$(cd "$repo" && nix build --no-link --print-out-paths --inputs-from . home-manager#home-manager) || exit 1
system=$(nix eval --impure --raw --expr builtins.currentSystem) || exit 1

t=$(mktemp -d)
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export HOME=$t/home USER=$(id -un) PATH=$nix_out/bin:$hm/bin:$PATH
unset XDG_STATE_HOME XDG_CONFIG_HOME
H=$HOME/.config/home-manager L=$t/flake D=$HOME/.local/state/nix/profiles
# A git flake: every version stays fetchable, as a declared element's locked URL needs.
F=git+file://$L
mkdir -p "$H" "$L" "$t/pr" "$t/log" "$HOME/.local/state/nix/profiles"

cat > "$t/registry.json" <<EOF
{"version": 2, "flakes": [
  {"from": {"type": "indirect", "id": "nixpkgs"}, "to": {"type": "github", "owner": "NixOS", "repo": "nixpkgs", "rev": "$np"}},
  {"from": {"type": "indirect", "id": "home-manager"}, "to": {"type": "github", "owner": "nix-community", "repo": "home-manager", "rev": "$(rev home-manager)"}},
  {"from": {"type": "indirect", "id": "webtop"}, "to": {"type": "path", "path": "$repo/modules/nix-profile/webtop-flake"}}
]}
EOF
# The real hook. With $t/fail-hook (declaration) or $t/fail-plain-hook (profile), fails as a broken
# switch would, once another command has committed the store path named in that file (if any).
{
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\${NIX_PROFILE_BACKEND:-}" = declaration ] && [ -e "$t/fail-hook" ]; then
  other=\$(cat "$t/fail-hook"); rm "$t/fail-hook"
  [ -z "\$other" ] || nix profile add "\$other"
  exit 1
fi
if [ "\${NIX_PROFILE_BACKEND:-}" = profile ] && [ -e "$t/fail-plain-hook" ]; then
  other=\$(cat "$t/fail-plain-hook"); rm "$t/fail-plain-hook"
  [ -z "\$other" ] || nix profile add --profile "\$NIX_PROFILE" "\$other"
  exit 1
fi
EOF
  cat "$repo/modules/nix-profile/webtop-profile-hook.sh"
} > "$t/hook"
chmod +x "$t/hook"
export NIX_CONFIG="experimental-features = nix-command flakes
flake-registry = $t/registry.json
warn-dirty = false
profile-backend = declaration:$H/packages.json
profile-hook = $t/hook"

for f in flake.nix home.nix packages.json; do
  sed -e "s|@user@|$USER|g" -e "s|@home@|$HOME|g" -e "s|@stateVersion@|25.11|g" -e "s|@system@|$system|g" \
    "$repo/modules/nix-profile/starter/$f" > "$H/$f"
done

cat > "$L/flake.nix" <<EOF
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/$np";
  outputs = { nixpkgs, ... }: let
    p = nixpkgs.legacyPackages.$system;
    stamp = builtins.readFile ./stamp;
    mk = delay: n: derivation {
      name = n; system = "$system"; builder = "\${p.bash}/bin/bash"; PATH = "\${p.coreutils}/bin";
      args = [ "-c" ''
        sleep \${delay}; mkdir -p \$out/bin
        printf '#!/bin/sh\necho \${stamp}\n' > \$out/bin/tb-\${n}; chmod +x \$out/bin/tb-\${n}
      '' ];
    };
    many = pre: delay: builtins.listToAttrs (builtins.genList (i: rec { name = "\${pre}\${toString i}"; value = mk delay name; }) 4);
  in {
    packages.$system = many "fast" "0" // many "mid" "6" // {
      slow = mk "60" "slow";
      extra1 = mk "0" "extra1"; extra2 = mk "0" "extra2"; moved = mk "0" "moved";
      # The same names from a flake and as a store path, one of them slow.
      shadow = mk "0" "shadow"; shadowSlowPath = mk "25" "shadow";
      shadowSlow = mk "25" "shadowSlow"; shadowFastPath = mk "0" "shadowSlow";
    };
  };
}
EOF
n=0
stamp() {
  n=$((n + 1)); printf 's%s' "$n" > "$L/stamp"
  git -C "$L" add -A && git -C "$L" -c user.name=test -c user.email=test@example.invalid commit -qm "$n"
}
git init -q "$L" || exit 1
stamp
(cd "$L" && nix flake lock) || exit 1
stamp

fails=0
why() { grep -av 'SQLite database' "$1" | grep -a -A3 '^error' | head -n 6 | cut -c1-200; }
pass() { echo "PASS  $M: $*"; }
fail() { echo "FAIL  $M: $*"; fails=$((fails + 1)); }
sorted() { printf '%s\n' "$@" | sort -u | xargs; }

# nix profile on the backend under test; every command under timeout, so a deadlock is a failure.
pn() {
  local c=$1; shift
  if [ "$M" = plain ]; then timeout 300 nix profile "$c" --profile "$P" "$@"; else timeout 300 nix profile "$c" "$@"; fi
}
expr_of() { echo "(builtins.getFlake \"$F\").packages.$system.$1"; }
path_of() { nix build --no-link --print-out-paths "$F#$1"; }

bins() { ls -L "$1/bin" 2>/dev/null | sed -n 's/^tb-//p' | sort | xargs; }
manifest() { jq -r '.elements | keys[]' "$1/manifest.json" 2>/dev/null | grep -v '^home-manager-path' | sort | xargs; }
declared() { jq -r '.elements | keys[]' "$H/packages.json" | sort | xargs; }
bindir() { if [ "$M" = plain ]; then echo "$P"; else echo "$HOME/.nix-profile"; fi; }

# check <label> <in the declaration or plain profile...> [-- <in the profile next to a declaration...>]
check() {
  local label=$1; shift
  local a=() b=() in_b=
  for x in "$@"; do
    if [ "$x" = -- ]; then in_b=1; elif [ -n "$in_b" ]; then b+=("$x"); else a+=("$x"); fi
  done
  local want_a want_b want_all got
  want_a=$(sorted ${a[@]+"${a[@]}"}); want_b=$(sorted ${b[@]+"${b[@]}"}); want_all=$(sorted ${a[@]+"${a[@]}"} ${b[@]+"${b[@]}"})
  local bad=
  if [ "$M" = plain ]; then
    got=$(manifest "$P"); [ "$got" = "$want_a" ] || bad="$bad manifest=[$got] want=[$want_a]"
  else
    got=$(declared); [ "$got" = "$want_a" ] || bad="$bad file=[$got] want=[$want_a]"
    got=$(manifest "$D/profile"); [ "$got" = "$want_b" ] || bad="$bad manifest=[$got] want=[$want_b]"
    got=$(bins "$D/home-manager/home-path"); [ "$got" = "$want_a" ] || bad="$bad generation=[$got] want=[$want_a]"
  fi
  got=$(bins "$(bindir)"); [ "$got" = "$want_all" ] || bad="$bad PATH=[$got] want=[$want_all]"
  if [ -z "$bad" ]; then pass "$label"; else fail "$label:$bad"; fi
}

# File, manifest and PATH agree with each other, whatever the outcome of a race. Echoes the outcome.
agree() {
  local label=$1 got
  if [ "$M" = plain ]; then got=$(manifest "$P"); else got=$(declared); fi
  # shellcheck disable=SC2086
  check "$label (outcome [$got])" $got
}

# Each argument is a command line for pn, run at the same time. Sets rcs to their exit codes.
parallel() {
  local pids=() i=0 line rc
  for line in "$@"; do
    i=$((i + 1))
    # shellcheck disable=SC2086
    pn $line > "$t/log/p$i" 2>&1 &
    pids+=($!)
  done
  rcs=; i=0
  for p in "${pids[@]}"; do
    i=$((i + 1)); rc=0; wait "$p" || rc=$?
    rcs="$rcs$rc"
    [ "$rc" = 0 ] || { echo "--- command $i rc=$rc:"; why "$t/log/p$i"; }
  done
}
expect_ok() { case "$rcs" in *[!0]*) fail "$1: exit codes $rcs" ;; *) pass "$1: all exit 0" ;; esac; }

# Back to nothing added, and activated.
reset() {
  P=$t/pr/$1
  stamp
  [ "$M" = plain ] && return
  local name
  for name in $(manifest "$D/profile"); do nix profile remove --profile-backend profile "$name" > /dev/null 2>&1; done
  cp "$repo/modules/nix-profile/starter/packages.json" "$H/packages.json"
  timeout 300 home-manager switch --flake "$H" > "$t/log/reset" 2>&1 || { fail "reset: home-manager switch"; tail -n 20 "$t/log/reset"; }
}

scenario_parallel_adds() {
  local round
  for round in $(seq "$rounds"); do
    reset "adds$round"
    parallel "add $F#fast0" "add $F#fast1" "add $F#fast2" "add $F#fast3"
    expect_ok "4 parallel adds, round $round"
    check "4 parallel adds, round $round, none lost" fast0 fast1 fast2 fast3
  done
}

scenario_parallel_removes() {
  local round
  for round in $(seq "$rounds"); do
    reset "removes$round"
    pn add "$F#fast0" "$F#fast1" "$F#fast2" "$F#fast3" > /dev/null 2>&1
    parallel "remove fast0" "remove fast1" "remove fast2" "remove fast3"
    expect_ok "4 parallel removes, round $round"
    check "4 parallel removes, round $round, none resurrected"
  done
}

scenario_upgrades() {
  reset upgrades
  pn add "$F#mid0" "$F#mid1" "$F#mid2" "$F#mid3" > /dev/null 2>&1
  stamp
  parallel "upgrade mid0" "upgrade mid1" "upgrade mid2" "upgrade mid3"
  expect_ok "4 parallel upgrades"
  check "4 parallel upgrades, none lost" mid0 mid1 mid2 mid3
  local i dir want="s$n" bad=
  dir=$(bindir)
  for i in 0 1 2 3; do [ "$("$dir/bin/tb-mid$i")" = "$want" ] || bad="$bad mid$i"; done
  if [ -z "$bad" ]; then pass "4 parallel upgrades all new"; else fail "not upgraded:$bad"; fi

  stamp
  pn upgrade mid0 > "$t/log/u" 2>&1 & local u=$!
  sleep 2
  pn remove mid1 > /dev/null 2>&1
  local rc=0; wait "$u" || rc=$?
  [ "$rc" = 0 ] || { fail "upgrade with a remove meanwhile: rc=$rc"; why "$t/log/u"; }
  check "a remove during an upgrade stays removed" mid0 mid2 mid3
}

scenario_add_remove_same() {
  local round
  for round in $(seq "$rounds"); do
    reset "same$round"
    pn add "$F#fast0" > /dev/null 2>&1
    parallel "remove fast0" "add $F#fast0"
    expect_ok "remove and add of one name, present, round $round"
    agree "remove and add of one name, present, round $round"
    parallel "add $F#fast1" "remove fast1"
    expect_ok "add and remove of one name, absent, round $round"
    agree "add and remove of one name, absent, round $round"
  done
  # Both see the target; for the second it has gone by its commit, which is a no-op, not an error.
  reset sameremove
  pn add "$F#fast2" > /dev/null 2>&1
  parallel "remove fast2" "remove fast2"
  expect_ok "two removes of one name"
  check "two removes of one name"
}

scenario_slow_during_fast() {
  reset slowfast
  pn add "$F#fast1" > /dev/null 2>&1
  pn add "$F#slow" > "$t/log/slow" 2>&1 & local s=$!
  sleep 5
  local rc=0; pn add "$F#fast0" > "$t/log/fast" 2>&1 || rc=$?
  if kill -0 "$s" 2>/dev/null; then pass "fast add finishes while the slow one builds (rc=$rc)"
  else fail "fast add waited for the slow build (rc=$rc)"; fi
  pn remove fast1 > /dev/null 2>&1 || fail "remove during the slow add failed"
  rc=0; wait "$s" || rc=$?
  [ "$rc" = 0 ] || { fail "slow add: rc=$rc"; why "$t/log/slow"; }
  check "fast add kept, remove not resurrected" fast0 slow
}

# A command interrupted before its commit (0.3 s: evaluating, 6 s: building) changes nothing.
scenario_interrupted() {
  local sig delay c
  for sig in INT KILL; do
    for delay in 0.3 6; do
      reset "kill$sig$delay"
      pn add "$F#fast0" > /dev/null 2>&1
      stamp
      # Not through pn: timeout would put nix in a process group of its own.
      if [ "$M" = plain ]; then setsid nix profile add --profile "$P" "$F#slow" > /dev/null 2>&1 &
      else setsid nix profile add "$F#slow" > /dev/null 2>&1 &
      fi
      c=$!
      sleep "$delay"
      kill -"$sig" -- "-$c" 2>/dev/null
      wait "$c" 2>/dev/null
      check "SIG$sig after $delay s leaves the state alone" fast0
      pn add "$F#fast1" > "$t/log/a" 2>&1 || { fail "add after SIG$sig failed"; why "$t/log/a"; }
      check "no lock left behind by SIG$sig after $delay s" fast0 fast1
    done
  done
}

# A hook failing after the profile's lock was released: the revert keeps another command's commit.
scenario_plain_revert() {
  reset plainrevert
  pn add "$F#fast0" > /dev/null 2>&1
  local e rc=0; e=$(path_of extra2)
  echo "$e" > "$t/fail-plain-hook"
  pn add "$F#fast1" > "$t/log/r" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then pass "add fails with its hook"; else fail "add succeeded although its hook failed"; fi
  check "revert removes only its own element, another command's commit survives" fast0 extra2
  : > "$t/fail-plain-hook"
  rc=0; pn remove fast0 > "$t/log/r" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then pass "remove fails with its hook"; else fail "remove succeeded although its hook failed"; fi
  check "revert restores the removed element" fast0 extra2
  rm -f "$t/fail-plain-hook"
}

scenario_two_backends() {
  # A plain slow add during a declaration add: the switch's new home-manager-path is kept.
  reset mixed
  nix profile add --profile-backend profile "$F#slow" > "$t/log/s" 2>&1 & local s=$!
  sleep 5
  local rc=0; timeout 300 nix profile add "$F#fast0" > "$t/log/f" 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "declaration add: rc=$rc"
  rc=0; wait "$s" || rc=$?
  [ "$rc" = 0 ] || fail "plain slow add: rc=$rc"
  check "plain slow add during a declaration add" fast0 -- slow

  # Undo after a declaration failure, with another command's commit in between.
  reset undo
  local e1 e2; e1=$(path_of extra1); e2=$(path_of extra2)
  echo "$e2" > "$t/fail-hook"
  rc=0; timeout 300 nix profile add "$F#fast0" "$e1" > "$t/log/u" 2>&1 || rc=$?
  [ "$rc" != 0 ] && pass "two-backend add fails with its hook" || fail "two-backend add succeeded although its hook failed"
  check "undo removes only its own element, another command's commit survives" -- extra2

  # Undo restores what the command moved out of the profile.
  reset undomove
  local m; m=$(path_of moved)
  timeout 300 nix profile add "$m" > /dev/null 2>&1 || fail "adding moved"
  : > "$t/fail-hook"
  rc=0; timeout 300 nix profile add "$F#moved" > "$t/log/u" 2>&1 || rc=$?
  [ "$rc" != 0 ] && pass "moving add fails with its hook" || fail "moving add succeeded although its hook failed"
  check "undo restores the moved element" -- moved
  rm -f "$t/fail-hook"

  # Shadow rule under the lock: a store path whose name was declared while it built.
  reset shadow
  timeout 300 nix profile add --impure --expr "$(expr_of shadowSlowPath)" > "$t/log/s" 2>&1 & s=$!
  sleep 5
  timeout 300 nix profile add "$F#shadow" > /dev/null 2>&1 || fail "declaring shadow"
  rc=0; wait "$s" || rc=$?
  if [ "$rc" != 0 ] && grep -aq 'is declared in' "$t/log/s"; then pass "store path refused: its name was declared meanwhile"
  else fail "store path not refused (rc=$rc)"; fi
  check "the declared element alone" shadow

  # The reverse: a store path added while the flake output of that name built moves out of the profile.
  reset shadowrev
  timeout 300 nix profile add "$F#shadowSlow" > "$t/log/s" 2>&1 & s=$!
  sleep 5
  timeout 300 nix profile add --impure --expr "$(expr_of shadowFastPath)" > /dev/null 2>&1 || fail "adding the store path"
  rc=0; wait "$s" || rc=$?
  [ "$rc" = 0 ] || { fail "flake add over a store path: rc=$rc"; why "$t/log/s"; }
  check "the store path moved out when the flake output landed" shadowSlow
}

# home-manager uses `nix profile` only once the profile has a manifest.json.
hello=$(nix build --no-link --print-out-paths nixpkgs#hello) || exit 1
nix profile add --profile-backend profile "$hello" || exit 1
nix profile remove --profile-backend profile hello || exit 1
home-manager switch --flake "$H" > "$t/log/first" 2>&1 || { tail -n 40 "$t/log/first"; exit 1; }

# Many rounds where they are cheap: a declaration round runs home-manager for every command.
for M in plain declaration; do
  if [ "$M" = plain ]; then rounds=15; else rounds=5; fi
  scenario_parallel_adds
  scenario_parallel_removes
  scenario_upgrades
  scenario_add_remove_same
  scenario_slow_during_fast
  scenario_interrupted
done
M=plain
scenario_plain_revert
M=declaration
scenario_two_backends

echo "$fails failed"
[ "$fails" = 0 ]
