#!/usr/bin/env bash
# Builders that close their output before exiting keep their own exit status (daemon-eof-wait.patch).
# Runs the patched daemon as root on its own socket, against the host store, as the desktops run it:
# build users, no sandbox.
# Usage: nix-daemon-eof-test.sh <patched Nix out path>. Needs passwordless sudo.
set -uo pipefail

nix_out=$1
t=$(mktemp -d)
sock=$t/socket
sudo env NIX_DAEMON_SOCKET_PATH="$sock" NIX_CONFIG="sandbox = false" "$nix_out/bin/nix-daemon" > "$t/daemon.log" 2>&1 &
daemon=$!
trap 'sudo kill $daemon; wait $daemon; sudo rm -rf "$t"' EXIT
for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { echo "daemon did not start"; cat "$t/daemon.log"; exit 1; }

nonce=$(date +%s%N)
# build NAME SCRIPT: builds a derivation running SCRIPT with /bin/sh, prints its output path.
build() {
  "$nix_out/bin/nix" build --store "unix://$sock" --extra-experimental-features nix-command \
    --option substitute false --no-link --print-out-paths --impure --expr \
    "derivation { name = \"$1\"; system = builtins.currentSystem; builder = \"/bin/sh\"; args = [ \"-c\" ''$2'' ]; nonce = \"$nonce\"; }" \
    2> "$t/log"
}
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; tail -n 5 "$t/log"; fails=$((fails + 1)); }

out=$(build normal 'echo building; echo ok > $out') && [ "$(cat "$out")" = ok ] \
  && pass "normal build" || fail "normal build"

out=$(build closes-output 'exec >&- 2>&-; /bin/sleep 1; echo ok > $out') && [ "$(cat "$out")" = ok ] \
  && pass "builder closing its output, then exiting 0, succeeds" \
  || fail "builder closing its output, then exiting 0, succeeds"

if build closes-output-fails 'exec >&- 2>&-; /bin/sleep 1; exit 3' > /dev/null; then
  fail "builder closing its output, then exiting 3, fails"
elif grep -q 'exit code 3' "$t/log"; then
  pass "builder closing its output, then exiting 3, fails with exit code 3"
else
  fail "builder closing its output, then exiting 3, fails with exit code 3"
fi

# The builder exits; what it leaves behind is still killed.
out=$(build leaves-child 'exec >&- 2>&-; /bin/sleep 6173 & echo ok > $out') && [ "$(cat "$out")" = ok ] \
  && ! pgrep -f 'sleep 6173' > /dev/null \
  && pass "builder leaving a child succeeds, the child is killed" \
  || fail "builder leaving a child succeeds, the child is killed"

# The wait for a builder that outlives its output is bounded.
start=$SECONDS
if build outlives-output 'exec >&- 2>&-; /bin/sleep 120; echo ok > $out' > /dev/null; then
  fail "builder running on after closing its output is killed"
elif [ $((SECONDS - start)) -lt 60 ]; then
  pass "builder running on after closing its output is killed after $((SECONDS - start))s"
else
  fail "builder running on after closing its output is killed within 60s"
fi

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
