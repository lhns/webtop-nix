#!/usr/bin/env bash
# Boots the standalone image under docker as the README runs it and checks: Selkies answers, KWin
# composites, `nix profile` installs into the declaration, and the image's Nix DB registers exactly the
# paths in its store.
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
# A home that outlives the container, as an update to a new image does; removed at the end.
vol=webtop-image-home
docker volume rm "$vol" >/dev/null 2>&1 || true
start() { docker run -d --name "$c" --privileged --cgroupns=private --shm-size=1g -p 127.0.0.1:8082:8082 -v "$vol:/home" "$image" >/dev/null; }
start

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
wait_for "Selkies page" sh -c 'curl -sf http://127.0.0.1:8082/ | grep -i "<html" >/dev/null'
compositing() { asuser busctl --user get-property org.kde.KWin /Compositor org.kde.kwin.Compositing active | grep -qx 'b true'; }
wait_for "KWin compositing" compositing

# The setup unit may still be building, and an unfinished path is in the store but not in the DB.
setup_done() { [ "$(x systemctl show -P ActiveState webtop-home-manager)" != active ] && [ "$(x systemctl show -P ExecMainExitTimestampMonotonic webtop-home-manager)" != 0 ]; }
wait_for "home-manager setup" setup_done
[ "$(x systemctl show -P Result webtop-home-manager)" = success ] \
  || { x journalctl -u webtop-home-manager --no-pager | tail -n 50; fail "webtop-home-manager failed"; }
decl=/home/user/.config/home-manager/packages.json
hm=$(dirname "$decl")
touser() { x runuser -u user -- env HOME=/home/user PATH=/home/user/.nix-profile/bin:/home/user/.local/state/nix/profiles/profile/bin:/run/current-system/sw/bin "$@"; }
[ "$(touser nix config show profile-backend)" = "declaration:$decl" ] || fail "profile-backend is not the declaration"
touser test -e /home/user/.local/state/nix/profiles/home-manager || fail "the setup unit did not switch"
echo "starter flake: ok"

db=$(x nix-store --dump-db | awk 'BEGIN{st=0} { if (st==0) {print; st=1} else if (st<4) st++; else if (st==4) { n=$0+0; st = n ? 5 : 0 } else if (--n == 0) st=0 }' | sort)
store=$(x ls -A /nix/store | grep -vx '\.links' | sed 's|^|/nix/store/|' | sort)
[ "$db" = "$store" ] || fail "DB and store differ: $(diff <(echo "$db") <(echo "$store") | head -n 20)"
echo "Nix DB: all $(wc -l <<<"$db") store paths, nothing else"
x nix-store --verify-path /run/current-system || fail "/run/current-system does not verify"

touser nix profile add nixpkgs#hello || fail "nix profile add failed"
touser grep -q '"originalUrl": *"flake:nixpkgs"' "$decl" || fail "hello is not in packages.json"
touser hello >/dev/null || fail "hello is not on PATH after the switch"
touser nix profile remove hello || fail "nix profile remove failed"
touser sh -c "echo '{ home.file.\".ci-local-nix\".text = \"ok\"; }' > $hm/local.nix"
touser home-manager switch --flake "$hm" >/dev/null || fail "a switch with local.nix failed"
touser test -e /home/user/.ci-local-nix || fail "local.nix was not picked up"
out=$(touser webtop-home-manager-update) || fail "webtop-home-manager-update failed"
[ "$out" = "already the current template" ] || fail "webtop-home-manager-update: $out"
echo "nix profile, local.nix: ok"

# A new container on the same home: its store has nothing the user installed, so the declared package
# and the generation come back with the switch; dangling links move aside.
touser nix profile add nixpkgs#hello || fail "nix profile add failed"
touser nix profile add --profile-backend profile nixpkgs#cowsay || fail "nix profile add to the profile failed"
docker rm -f "$c" >/dev/null
start
deadline=$(($(date +%s) + timeout))
wait_for "KWin compositing on the same home" compositing
wait_for "home-manager setup on the same home" setup_done
[ "$(x systemctl show -P Result webtop-home-manager)" = success ] \
  || { x journalctl -u webtop-home-manager --no-pager | tail -n 50; fail "webtop-home-manager failed on the same home"; }
touser hello >/dev/null || { x journalctl -u webtop-home-manager --no-pager | tail -n 50; fail "the declared package did not come back"; }
touser sh -c 'ls -d /home/user/.local/state/nix/profiles.old-*' >/dev/null || fail "dangling generations were not moved aside"
touser nix profile add --profile-backend profile nixpkgs#tree || fail "the profile cannot be extended after the move aside"
echo "same home on a new store: ok"

docker rm -f "$c" >/dev/null
docker volume rm "$vol" >/dev/null
echo "image boot: ok"
