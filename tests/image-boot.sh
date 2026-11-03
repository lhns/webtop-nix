#!/usr/bin/env bash
# Boots the standalone image under docker as the README runs it and checks: Selkies answers, KWin
# composites, and the image's Nix DB registers exactly the paths in its store.
#
# Usage: image-boot.sh <image> <timeout-seconds>
set -euo pipefail

image=$1
timeout=$2
c=webtop-image
fail() { echo "::error::$*"; docker logs "$c" 2>&1 | tail -n 80; exit 1; }
x() { docker exec "$c" "$@"; }
asuser() { x runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$@"; }

docker rm -f "$c" >/dev/null 2>&1 || true
docker run -d --name "$c" --privileged --cgroupns=private --shm-size=1g -p 127.0.0.1:8082:8082 "$image" >/dev/null

deadline=$(($(date +%s) + timeout))
wait_for() { # <what> <command...>
  local what=$1; shift
  until "$@" >/dev/null 2>&1; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || fail "the container exited"
    [ "$(date +%s)" -lt "$deadline" ] || fail "no $what within ${timeout}s"
    sleep 3
  done
  echo "$what: ok"
}
wait_for "Selkies page" sh -c 'curl -sf http://127.0.0.1:8082/ | grep -qi "<html"'
compositing() { asuser busctl --user get-property org.kde.KWin /Compositor org.kde.kwin.Compositing active | grep -qx 'b true'; }
wait_for "KWin compositing" compositing

db=$(x nix-store --dump-db | awk 'BEGIN{st=0} { if (st==0) {print; st=1} else if (st<4) st++; else if (st==4) { n=$0+0; st = n ? 5 : 0 } else if (--n == 0) st=0 }' | sort)
store=$(x ls -A /nix/store | grep -vx '\.links' | sed 's|^|/nix/store/|' | sort)
[ "$db" = "$store" ] || fail "DB and store differ: $(diff <(echo "$db") <(echo "$store") | head -n 20)"
echo "Nix DB: all $(wc -l <<<"$db") store paths, nothing else"
x nix-store --verify-path /run/current-system || fail "/run/current-system does not verify"

docker rm -f "$c" >/dev/null
echo "image boot: ok"
