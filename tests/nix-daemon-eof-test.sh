#!/usr/bin/env bash
# A builder that closes its output before exiting is waited for, not killed, without blocking other
# builds (daemon-eof-wait.patch). Runs the patched daemon as root on its own socket, against the
# host store, as the desktops run it: build users, no sandbox.
# Usage: nix-daemon-eof-test.sh <patched Nix out path>. Needs passwordless sudo.
set -uo pipefail

nix_out=$1
t=$(mktemp -d)
sock=$t/socket
sudo env NIX_DAEMON_SOCKET_PATH="$sock" NIX_CONFIG=$'sandbox = false\nmax-jobs = 4' \
  "$nix_out/bin/nix-daemon" > "$t/daemon.log" 2>&1 &
daemon=$!
trap 'sudo kill $daemon; wait $daemon; sudo rm -rf "$t"' EXIT
for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { echo "daemon did not start"; cat "$t/daemon.log"; exit 1; }

nonce=$(date +%s%N)
# drv NAME SCRIPT [ATTRS]: a derivation running SCRIPT with /bin/sh.
drv() {
  echo "derivation { name = \"$1\"; system = builtins.currentSystem; builder = \"/bin/sh\";" \
    "args = [ \"-c\" ''$2'' ]; nonce = \"$nonce\"; ${3:-} }"
}
# build EXPR [NIX ARGS]: builds EXPR through the daemon, prints its output path.
build() {
  local expr=$1
  shift
  "$nix_out/bin/nix" build --store "unix://$sock" --extra-experimental-features nix-command \
    --option substitute false --no-link --print-out-paths --impure --expr "$expr" "$@" 2> "$t/log"
}
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; tail -n 5 "$t/log"; fails=$((fails + 1)); }

out=$(build "$(drv normal 'echo building; echo ok > $out')") && [ "$(cat "$out")" = ok ] \
  && pass "normal build" || fail "normal build"

out=$(build "$(drv closes-output 'exec >&- 2>&-; /bin/sleep 1; echo ok > $out')") && [ "$(cat "$out")" = ok ] \
  && pass "builder closing its output, then exiting 0, succeeds" \
  || fail "builder closing its output, then exiting 0, succeeds"

if build "$(drv closes-output-fails 'exec >&- 2>&-; /bin/sleep 1; exit 3')" > /dev/null; then
  fail "builder closing its output, then exiting 3, fails"
elif grep -q 'exit code 3' "$t/log"; then
  pass "builder closing its output, then exiting 3, fails with exit code 3"
else
  fail "builder closing its output, then exiting 3, fails with exit code 3"
fi

# The builder exits; what it leaves behind is still killed.
out=$(build "$(drv leaves-child 'exec >&- 2>&-; /bin/sleep 6173 & echo ok > $out')") && [ "$(cat "$out")" = ok ] \
  && ! pgrep -f 'sleep 6173' > /dev/null \
  && pass "builder leaving a child succeeds, the child is killed" \
  || fail "builder leaving a child succeeds, the child is killed"

# builder-exit-timeout bounds the wait.
name="builder running on after closing its output is killed after builder-exit-timeout = 3"
start=$SECONDS
if build "$(drv outlives-output 'exec >&- 2>&-; /bin/sleep 120; echo ok > $out')" \
  --option builder-exit-timeout 3 > /dev/null; then
  fail "$name"
else
  elapsed=$((SECONDS - start))
  if [ "$elapsed" -ge 3 ] && [ "$elapsed" -lt 20 ] && grep -q 'signal 9' "$t/log"; then
    pass "$name (${elapsed}s)"
  else
    fail "$name (${elapsed}s)"
  fi
fi

# builder-exit-timeout = 0 is the old behavior: killed on the EOF.
name="builder closing its output is killed at once with builder-exit-timeout = 0"
if build "$(drv closes-output-no-wait 'exec >&- 2>&-; /bin/sleep 1; echo ok > $out')" \
  --option builder-exit-timeout 0 > /dev/null; then
  fail "$name"
elif grep -q 'signal 9' "$t/log"; then
  pass "$name"
else
  fail "$name"
fi

# The wait does not block the client's other builds: while one builder lingers 8 s after closing its
# output, another finishes and the build depending on it starts. Each records when it ran.
name="other builds run while a builder lingers after closing its output"
lingers=$(drv lingers 'exec >&- 2>&-; /bin/sleep 8; /bin/date +%s > $out')
quick=$(drv quick '/bin/sleep 1; echo > $out')
after=$(drv after-quick '/bin/date +%s > $out' "quick = $quick;")
if out=$(build "$(drv concurrent 'echo $(/bin/cat $lingers) $(/bin/cat $after) > $out' \
  "lingers = $lingers; after = $after;")" --option builder-exit-timeout 30) \
  && read -r lingers_done after_ran < "$out" && [ "$after_ran" -lt "$lingers_done" ]; then
  pass "$name (after-quick at $after_ran, lingers done at $lingers_done)"
else
  fail "$name (after-quick at ${after_ran:-?}, lingers done at ${lingers_done:-?})"
fi

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
