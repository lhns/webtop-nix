#!/usr/bin/env bash
# Concurrent `nix profile` commands (ADR 0007) and their cancels, kills and activations (ADR 0008) with the
# patched Nix, real builds and home-manager: every command ends with the declaration, the manifest, what
# is on PATH and the applied marker in agreement.
# Usage: nix-profile-concurrency.sh <patched Nix out path>. Needs network; home is a temporary one.
set -uo pipefail

nix_out=$1
stock_nix_dir=$(dirname "$(command -v nix)")
repo=$(cd "$(dirname "$0")/.." && pwd)
rev() { jq -r ".nodes[\"$1\"].locked.rev" "$repo/flake.lock"; }
np=$(rev nixpkgs)
hm=$(cd "$repo" && nix build --no-link --print-out-paths --inputs-from . home-manager#home-manager) || exit 1
system=$(nix eval --impure --raw --expr builtins.currentSystem) || exit 1

t=$(mktemp -d)
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export HOME=$t/home USER=$(id -un) PATH=$nix_out/bin:$PATH
unset XDG_STATE_HOME XDG_CONFIG_HOME
H=$HOME/.config/home-manager L=$t/flake D=$HOME/.local/state/nix/profiles
CTL=$HOME/ctl LOCK=$HOME/.local/state/webtop/home-manager.lock APPLIED=$HOME/.local/state/webtop/applied
# A git flake: every version stays fetchable, as a declared element's locked URL needs.
F=git+file://$L
mkdir -p "$H" "$L" "$t/pr" "$t/log" "$CTL" "$t/stubs" "$HOME/.local/state/nix/profiles"

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

# home-manager as the image has it, under the apply lock; $hm/bin is the real binary, for the paths around it.
hm_locked=$(nix build --no-link --print-out-paths --impure --expr   "import $repo/modules/nix-profile/webtop-flake/home-manager-locked.nix { pkgs = (builtins.getFlake \"nixpkgs\").legacyPackages.$system; real = $hm; }") || exit 1
export PATH=$hm_locked/bin:$PATH

for f in flake.nix home.nix packages.json; do
  sed -e "s|@user@|$USER|g" -e "s|@home@|$HOME|g" -e "s|@stateVersion@|25.11|g" -e "s|@system@|$system|g" \
    "$repo/modules/nix-profile/starter/$f" > "$H/$f"
done

# A test-only activation entry, switched on by files in $CTL: it records when activations run, can hold
# one, and can leave a child behind.
sed -i -e 's|^{ pkgs, \.\.\. }:|{ pkgs, lib, ... }:|' -e '$d' "$H/home.nix"
cat >> "$H/home.nix" <<'EOF'
  home.activation.testStage = lib.hm.dag.entryBetween [ "installPackages" ] [ "writeBoundary" ] ''
    webtop_ctl=@ctl@
    if [ -e $webtop_ctl/act-on ]; then
      echo "start $(date +%s.%N)" >> $webtop_ctl/act-log
      touch $webtop_ctl/act-started
      while [ -e $webtop_ctl/hold-act ]; do sleep 0.2; done
      if [ -e $webtop_ctl/act-sleep ]; then sleep 1.5; fi
      if [ -e $webtop_ctl/act-bg ]; then ( sleep 25 ) & fi
      echo "end $(date +%s.%N)" >> $webtop_ctl/act-log
    fi
  '';
}
EOF
sed -i "s|@ctl@|$CTL|" "$H/home.nix"

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
      hmpath = mk "0" "home-manager-path"; extra1 = mk "0" "extra1"; extra2 = mk "0" "extra2"; moved = mk "0" "moved";
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
why() {
  grep -av 'SQLite database' "$1" | grep -a -A3 '^error' | head -n 6 | cut -c1-200
  if builder_killed "$1"; then echo "--- kernel: $(sudo -n dmesg 2> /dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -n 5)"; free -m; fi
}
# The test cannot do this: builders run as nixbld users, and its kills reach only its own clients.
builder_killed() { grep -aq 'builder failed due to signal 9' "$1"; }
pass() { echo "PASS  $M: $*"; }
fail() { echo "FAIL  $M: $*"; fails=$((fails + 1)); }
sorted() { printf '%s\n' "$@" | sort -u | xargs; }

# Nothing holds the apply lock any more: orphaned hooks and switches have finished.
quiesce() {
  local i
  for i in $(seq 360); do pgrep -f "$LOCK" > /dev/null || return 0; sleep 0.5; done
  fail "something still holds the apply lock"
}
wait_for() { # <seconds> <command...>
  local n=$(($1 * 10)); shift
  until "$@" 2> /dev/null; do n=$((n - 1)); [ "$n" -gt 0 ] || return 1; sleep 0.1; done
}
has_file() { [ -e "$CTL/$1" ]; }
file_has() { jq -e ".elements | has(\"$1\")" "$H/packages.json" > /dev/null; }
running() { kill -0 "$1" 2> /dev/null; }
# nix profile add in the background, in a session of its own so that a test can signal it alone; sets c.
bg_add() { setsid nix profile add "$@" > "$t/log/bg" 2>&1 & c=$!; }
# No two activations overlapped: the log reads start, end, start, end.
serial_log() {
  awk '{ if ($1 == last) bad = 1; last = $1 } END { exit (bad || last == "start") }' "$CTL/act-log" 2> /dev/null
}

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
    got=$(cat "$APPLIED" 2>/dev/null); [ "$got" = "$(sha256sum < "$H/packages.json" | cut -d' ' -f1)" ] || bad="$bad applied marker is not the declaration's hash"
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
    [ "$rc" = 0 ] || { echo "--- command $i rc=$rc:"; why "$t/log/p$i"; }
    # A command that reports a killed builder failed honestly, before its commit, and the checks would
    # count it as lost. Its package must then land like any other; a command that exited 0 still has to.
    if [ "$rc" != 0 ] && builder_killed "$t/log/p$i"; then
      echo "NOTE  builder killed from outside, command $i runs again"
      line=${*:$i:1}
      rc=0
      # shellcheck disable=SC2086
      pn $line > "$t/log/p$i" 2>&1 || { rc=$?; why "$t/log/p$i"; }
    fi
    rcs="$rcs$rc"
  done
}
expect_ok() { case "$rcs" in *[!0]*) fail "$1: exit codes $rcs" ;; *) pass "$1: all exit 0" ;; esac; }

# Back to nothing added, and activated.
reset() {
  P=$t/pr/$1
  stamp
  quiesce
  rm -f "$CTL"/* "$H/local.nix"
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

# Declaration only. A command killed (SIGKILL) at a stage of its commit: the file stays valid, what it
# started carries on holding the apply lock, and the same command again completes it.
scenario_kill9_stages() {
  local stage rc second
  for stage in file activation; do
    reset "kill9$stage"
    if [ "$stage" = activation ]; then touch "$CTL/act-on" "$CTL/hold-act"; fi
    bg_add "$F#fast0"
    if [ "$stage" = file ]; then
      wait_for 120 file_has fast0 || fail "kill -9 at $stage: the file never changed"
    else
      wait_for 120 has_file act-started || fail "kill -9 at $stage: no activation started"
    fi
    kill -9 "$c"; wait "$c" 2> /dev/null
    if jq -e .elements "$H/packages.json" > /dev/null; then pass "kill -9 at $stage: the file is valid"; else fail "kill -9 at $stage: invalid file"; fi
    if [ "$stage" = activation ]; then
      # The orphaned activation still holds the lock, so a second command waits for it instead of overlapping.
      pn add "$F#fast1" > "$t/log/second" 2>&1 & second=$!
      sleep 4
      if running "$second"; then pass "kill -9 at $stage: a second add waits for the orphaned activation"
      else fail "kill -9 at $stage: a second add did not wait"; fi
      rm -f "$CTL/hold-act"
      rc=0; wait "$second" || rc=$?
      [ "$rc" = 0 ] || { fail "kill -9 at $stage: second add rc=$rc"; why "$t/log/second"; }
      if serial_log; then pass "kill -9 at $stage: activations did not overlap"
      else fail "kill -9 at $stage: activations overlapped: $(tr '\n' ' ' < "$CTL/act-log")"; fi
    fi
    quiesce
    # The same command again applies what the killed one left (the declaration already has it).
    pn add "$F#fast0" > "$t/log/retry" 2>&1 || { fail "kill -9 at $stage: retry failed"; why "$t/log/retry"; }
    if [ "$stage" = activation ]; then check "kill -9 at $stage, retried" fast0 fast1; else check "kill -9 at $stage, retried" fast0; fi
  done
}

# SIGINT at a stage of the commit: the change is applied, never left half-way.
scenario_cancel() {
  local stage rc
  for stage in file activation; do
    reset "cancel$stage"
    if [ "$stage" = activation ]; then touch "$CTL/act-on" "$CTL/hold-act"; fi
    bg_add "$F#fast0"
    if [ "$stage" = file ]; then
      wait_for 120 file_has fast0 || fail "cancel at $stage: the file never changed"
    else
      wait_for 120 has_file act-started || fail "cancel at $stage: no activation started"
    fi
    kill -INT "$c"
    if [ "$stage" = activation ]; then
      sleep 3
      if running "$c"; then pass "cancel at $stage: nix waits for the apply instead of leaving"
      else fail "cancel at $stage: nix left while the activation ran"; fi
      rm -f "$CTL/hold-act"
    fi
    rc=0; wait "$c" || rc=$?
    quiesce
    agree "cancel at $stage (nix rc=$rc)"
  done
}

# SIGINT and SIGKILL after a range of delays: never half-applied after a cancel, consistent after a retry.
scenario_signal_sweep() {
  local sig r d
  for sig in INT KILL; do
    for r in $(seq 8); do
      reset "sweep$sig$r"
      d=$(awk "BEGIN{printf \"%.1f\", 0.5 + $r * 1.3}")
      bg_add "$F#fast0"
      sleep "$d"
      kill -"$sig" "$c" 2> /dev/null; wait "$c" 2> /dev/null
      quiesce
      jq -e .elements "$H/packages.json" > /dev/null || fail "SIG$sig after $d s: invalid file"
      if [ "$sig" = INT ]; then agree "SIGINT after $d s, nothing half-applied"; fi
      pn add "$F#fast0" > "$t/log/retry" 2>&1 || { fail "retry after SIG$sig at $d s failed"; why "$t/log/retry"; }
      check "retry after SIG$sig at $d s" fast0
    done
  done
}

# home-manager from the CLI, the real binary and the wrapper, with package commands around it.
scenario_activations() {
  local i rc bin how sw k
  local rcs_hm=''
  local pids=()
  reset activations
  touch "$CTL/act-on" "$CTL/act-sleep"
  for i in 1 2; do timeout 300 home-manager switch --flake "$H" > "$t/log/hm$i" 2>&1 & pids+=($!); done
  for i in 3 4; do timeout 300 "$hm/bin/home-manager" switch --flake "$H" > "$t/log/hm$i" 2>&1 & pids+=($!); done
  for i in "${pids[@]}"; do rc=0; wait "$i" || rc=$?; rcs_hm="$rcs_hm$rc"; done
  if [ "$rcs_hm" = 0000 ]; then pass "4 parallel home-manager switches (wrapper and real binary) all exit 0"
  else fail "4 parallel switches: exit codes $rcs_hm"; tail -n 5 "$t/log"/hm[1-4]; fi
  if serial_log && [ "$(grep -c start "$CTL/act-log")" = 4 ]; then pass "the 4 activations ran one after the other"
  else fail "activations overlapped or are missing: $(tr '\n' ' ' < "$CTL/act-log")"; fi
  agree "after 4 parallel switches"

  # A switch built before a package change must not activate over it: it is refused and the change stays.
  for how in wrapper real; do
    reset activationsstale
    bin=home-manager; [ "$how" = real ] && bin=$hm/bin/home-manager
    cat > "$H/local.nix" <<EOF
{ pkgs, ... }: { home.packages = [ (pkgs.runCommand "slowhm-$RANDOM" { } "sleep 20; mkdir \$out") ]; }
EOF
    timeout 300 "$bin" switch --flake "$H" > "$t/log/stale" 2>&1 & sw=$!
    sleep 6
    pn add "$F#fast0" > "$t/log/add" 2>&1 || { fail "add during a stale switch failed"; why "$t/log/add"; }
    rc=0; wait "$sw" || rc=$?
    if [ "$rc" = 75 ]; then pass "stale switch via the $how binary: refused (75)"
    else fail "stale switch via the $how binary: rc=$rc"; tail -n 5 "$t/log/stale"; fi
    quiesce
    check "stale switch via the $how binary leaves the new package" fast0
  done

  # The boot script has nobody to run it again: it does so itself.
  reset activationsboot
  printf '#!/usr/bin/env bash\n[ "$1" != nixconfig ] || printf %%s "${NIX_CONFIG:-}"\n' > "$t/stubs/webtop-restore-progress"; cp "$t/stubs/webtop-restore-progress" "$t/stubs/webtop-notify"
  { printf '#!/usr/bin/env bash\nset -euo pipefail\nWEBTOP_FLAKE=%s\n' "$repo/modules/nix-profile/webtop-flake"
    cat "$repo/modules/nix-profile/webtop-home-manager.sh"; } > "$t/setup.sh"
  chmod +x "$t/stubs/webtop-restore-progress" "$t/stubs/webtop-notify" "$t/setup.sh"
  touch "$HOME/.local/state/webtop/home-manager-switch"
  cat > "$H/local.nix" <<EOF
{ pkgs, ... }: { home.packages = [ (pkgs.runCommand "slowhm-$RANDOM" { } "sleep 20; mkdir \$out") ]; }
EOF
  PATH=$t/stubs:$PATH timeout 300 "$t/setup.sh" > "$t/log/setup" 2>&1 & sw=$!
  sleep 6
  pn add "$F#fast0" > "$t/log/add" 2>&1 || { fail "add during the boot switch failed"; why "$t/log/add"; }
  rc=0; wait "$sw" || rc=$?
  if [ "$rc" = 0 ] && [ ! -e "$HOME/.local/state/webtop/home-manager-switch" ]; then pass "a package change during the boot switch: it switches again"
  else fail "boot switch with a package change: rc=$rc"; tail -n 5 "$t/log/setup"; fi
  quiesce
  check "after the boot switch" fast0
  rm -f "$H/local.nix"

  # Killed holder: the lock is released with it, the next switch is not blocked.
  reset activationskill
  touch "$CTL/act-on" "$CTL/hold-act"
  setsid home-manager switch --flake "$H" > "$t/log/k" 2>&1 & k=$!
  wait_for 120 has_file act-started || fail "no activation started"
  pkill -9 -f "flock -o $LOCK"; kill -9 "$k" 2> /dev/null
  rm -f "$CTL/hold-act"
  rc=0; timeout 120 home-manager switch --flake "$H" > "$t/log/k2" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then pass "kill -9 of the lock holder: the next switch runs"
  else fail "next switch after a killed holder: rc=$rc"; tail -n 5 "$t/log/k2"; fi
  quiesce

  # What an activation leaves running does not hold the lock.
  reset activationsbg
  touch "$CTL/act-on" "$CTL/act-bg"
  timeout 120 home-manager switch --flake "$H" > "$t/log/bg2" 2>&1 || fail "switch with a background child failed"
  if pgrep -f 'sleep 25' > /dev/null && flock -n "$LOCK" true; then pass "a background child of an activation does not hold the lock"
  else fail "the lock is held by a child of the activation, or the child is gone"; fi
  pkill -f 'sleep 25'; rm -f "$CTL/act-bg"

  # --rollback is not refused, and a forward switch returns to the declaration.
  reset activationsrollback
  pn add "$F#fast0" > /dev/null 2>&1
  rc=0; timeout 120 home-manager switch --rollback > "$t/log/rb" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then pass "home-manager switch --rollback works"; else fail "rollback rc=$rc"; tail -n 5 "$t/log/rb"; fi
  timeout 120 home-manager switch --flake "$H" > "$t/log/rb2" 2>&1 || fail "switch after rollback failed"
  check "forward again after a rollback" fast0
}

# A store path is added under the declaration's lock, unless a hook or an activation adds it.
scenario_store_path_lock() {
  reset storelock
  local e1 e2 s holder rc=0
  e1=$(path_of extra1); e2=$(path_of extra2)
  flock "$D/declaration.lock" sleep 12 & holder=$!
  sleep 1
  pn add "$e1" > "$t/log/e1" 2>&1 & s=$!
  sleep 3
  if running "$s"; then pass "a store path waits for a declaration command's lock"; else fail "a store path did not wait for the declaration lock"; fi
  NIX_PROFILE_BACKEND=activation timeout 60 nix profile add "$e2" > "$t/log/e2" 2>&1 || fail "marked store path add failed"
  if running "$holder"; then pass "an add from a hook or an activation does not wait for it"; else fail "the marked add waited"; fi
  wait "$s" || rc=$?
  [ "$rc" = 0 ] || { fail "store path add rc=$rc"; why "$t/log/e1"; }
  wait "$holder"
  check "both store paths added" -- extra1 extra2

  # The other order, a generation without the module's install entry (older, or the module dropped):
  # its plain store-path add under the wrapper's apply lock while a declaration add holds L_D and waits
  # for L_A. Neither may wait for the other.
  reset storeorder
  e1=$(path_of extra1)
  cat > "$t/stubs/old-hm" <<EOF
#!/usr/bin/env bash
touch "$CTL/old-hm"
# Committed, so it holds the declaration's lock and its hook waits for the apply lock.
until grep -q fast0 "$H/packages.json"; do sleep 0.2; done
exec nix profile add "$e1"
EOF
  { printf '#!/usr/bin/env bash\nset -euo pipefail\nWEBTOP_HM_REAL=%s\n' "$t/stubs/old-hm"
    cat "$repo/modules/nix-profile/webtop-flake/home-manager-locked.sh"; } > "$t/stubs/old-hm-locked"
  chmod +x "$t/stubs/old-hm" "$t/stubs/old-hm-locked"
  timeout 90 "$t/stubs/old-hm-locked" > "$t/log/old" 2>&1 & holder=$!
  wait_for 30 has_file old-hm || fail "the old generation's install never started"
  pn add "$F#fast0" > "$t/log/add" 2>&1 & s=$!
  rc=0; wait "$holder" || rc=$?
  if [ "$rc" = 0 ]; then pass "a plain store-path add under the apply lock does not wait for the declaration lock"
  else fail "store-path add under the apply lock: rc=$rc (124: deadlock)"; tail -n 5 "$t/log/old"; fi
  rc=0; wait "$s" || rc=$?; [ "$rc" = 0 ] || { fail "the declaration add: rc=$rc"; why "$t/log/add"; }
  quiesce
  check "both, in the other lock order" fast0 -- extra1
}

# home-manager's own install of its generation: no moment without it, and never none after a kill.
scenario_hm_atomic() {
  local p src r cnt d g
  reset hmatomic
  pn add "$F#fast0" > /dev/null 2>&1
  touch "$t/poll"
  ( missing=0; polls=0
    while [ -e "$t/poll" ]; do polls=$((polls + 1)); [ -x "$HOME/.nix-profile/bin/tb-fast0" ] || missing=$((missing + 1)); sleep 0.005; done
    echo "$missing/$polls" > "$t/pollres" ) &
  for p in fast1 fast2 fast3; do pn add "$F#$p" > /dev/null 2>&1; done
  rm -f "$t/poll"; sleep 0.5
  if [ "$(cut -d/ -f1 "$t/pollres")" = 0 ]; then pass "no moment without the declared packages over 3 switches ($(cat "$t/pollres") polls missing)"
  else fail "declared packages missing during switches: $(cat "$t/pollres")"; fi

  r=0
  for d in 0.02 0.05 0.08 0.1 0.15 0.2 0.3 0.4; do
    r=$((r + 1)); stamp
    p=$(path_of hmpath) || { fail "building a home-manager-path"; break; }
    setsid nix profile add --replace home-manager-path "$p" > /dev/null 2>&1 & c=$!
    sleep "$d"
    kill -9 "$c" 2> /dev/null; wait "$c" 2> /dev/null
    cnt=$(jq -r '.elements | keys[]' "$D/profile/manifest.json" | grep -c '^home-manager-path')
    if [ "$cnt" = 1 ]; then pass "kill -9 during --replace after $d s: one home-manager-path"
    else fail "kill -9 during --replace after $d s: $cnt home-manager-path elements"; fi
  done

  # The text of home-manager's installPackages that webtop-flake/packages.nix replaces.
  src=$(nix eval --raw --impure --expr '(builtins.getFlake "home-manager").outPath')
  if grep -qF "nixProfileRemove 'home-manager-path'" "$src/modules/home-environment.nix" \
    && grep -qF 'run $oldNix profile install $1' "$src/modules/home-environment.nix" \
    && grep -qF 'if ! $INSTALL_CMD_ACTUAL ${cfg.path} ; then' "$src/modules/home-environment.nix"; then
    pass "home-manager's installPackages is the text packages.nix replaces"
  else fail "home-manager's installPackages changed: update webtop-flake/packages.nix"; fi

  # The marker comes after every step that applies the generation.
  g=$(readlink -f "$D/home-manager")
  if grep -o '_iNote "Activating %s" "[a-zA-Z]*"' "$g/activate" | sed -n '/reloadSystemd/,$p' | grep -q webtopApplied; then
    pass "the applied marker is written after the generation is linked and reloaded"
  else fail "the applied marker is written before reloadSystemd"; fi

  # A generation with the new entries under an older image's Nix: the remove-and-add fallback. The shim
  # records how activation called Nix.
  reset hmstock
  pn add "$F#fast0" > /dev/null 2>&1
  g=$(readlink -f "$D/home-manager")
  if "$stock_nix_dir/nix" config show profile-backend > /dev/null 2>&1; then fail "$stock_nix_dir/nix has profile-backend: not stock"; fi
  mkdir "$t/stock"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s"\nexec "%s" "$@"\n' "$t/log/stock-calls" "$stock_nix_dir/nix" > "$t/stock/nix"
  chmod +x "$t/stock/nix"
  if ( export PATH=$t/stock:$stock_nix_dir:$PATH; "$g/activate" --driver-version 1 ) > "$t/log/stock" 2>&1; then pass "a new generation activates under stock Nix"
  else fail "activation under stock Nix"; tail -n 8 "$t/log/stock"; fi
  if grep -q '^profile install ' "$t/log/stock-calls" && ! grep -q -- --replace "$t/log/stock-calls"; then pass "under stock Nix it removes and adds"
  else fail "not the stock fallback: $(tr '\n' ';' < "$t/log/stock-calls" | cut -c1-300)"; fi
  check "after an activation under stock Nix" fast0
}

# A reinstall (the image-update restore) and an install take the same lock.
scenario_reinstall() {
  reset reinstall
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/stubs/webtop-restore-progress"; cp "$t/stubs/webtop-restore-progress" "$t/stubs/webtop-notify"
  cat > "$t/stubs/setup" <<EOF
#!/usr/bin/env bash
touch "$CTL/setup-started"
while [ -e "$CTL/hold-setup" ]; do sleep 0.2; done
home-manager switch --flake "$H"
EOF
  { printf '#!/usr/bin/env bash\nset -euo pipefail\nWEBTOP_SETUP=%s\n' "$t/stubs/setup"; cat "$repo/modules/nix-profile/webtop-nix-reinstall.sh"; } > "$t/reinstall.sh"
  chmod +x "$t/stubs"/* "$t/reinstall.sh"
  local r rc=0 aside

  # An install holds the lock: the reinstall moves nothing aside until it is done.
  touch "$CTL/act-on" "$CTL/hold-act"
  bg_add "$F#fast0"
  wait_for 120 has_file act-started || fail "no activation started"
  ln -s /nix/store/gone-hm "$D/home-manager-0-link"
  PATH=$t/stubs:$PATH "$t/reinstall.sh" /nonexistent > "$t/log/reinstall" 2>&1 & r=$!
  sleep 4
  aside=$(ls -d "$D".old-* 2> /dev/null | head -n 1)
  if running "$r" && [ -z "$aside" ] && [ -L "$D/home-manager-0-link" ]; then pass "a reinstall waits for a running install"
  else fail "the reinstall did not wait (running: $(running "$r" && echo yes), aside: ${aside:-none})"; fi
  rm -f "$CTL/hold-act"
  wait "$c" || true
  wait "$r" || rc=$?
  [ "$rc" = 0 ] || { fail "reinstall rc=$rc"; tail -n 8 "$t/log/reinstall"; }
  if [ ! -e "$D/home-manager-0-link" ]; then pass "the dangling generation moved aside after the install"; else fail "the dangling generation is still there"; fi
  quiesce
  agree "install and reinstall together"

  # A reinstall holds the lock: an install waits for it.
  touch "$CTL/hold-setup"; rm -f "$CTL/setup-started" "$CTL/hold-act" "$CTL/act-on"
  PATH=$t/stubs:$PATH "$t/reinstall.sh" /nonexistent > "$t/log/reinstall" 2>&1 & r=$!
  wait_for 60 has_file setup-started || fail "the reinstall never reached the switch"
  pn add "$F#fast1" > "$t/log/add" 2>&1 & c=$!
  sleep 5
  if running "$c"; then pass "an install waits for a running reinstall"; else fail "the install did not wait for the reinstall"; fi
  rm -f "$CTL/hold-setup"
  rc=0; wait "$r" || rc=$?; [ "$rc" = 0 ] || fail "reinstall rc=$rc"
  rc=0; wait "$c" || rc=$?; [ "$rc" = 0 ] || { fail "install rc=$rc"; why "$t/log/add"; }
  quiesce
  agree "reinstall and install together"
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
scenario_kill9_stages
scenario_cancel
scenario_signal_sweep
scenario_activations
scenario_store_path_lock
scenario_hm_atomic
scenario_reinstall

echo "$fails failed"
[ "$fails" = 0 ]
