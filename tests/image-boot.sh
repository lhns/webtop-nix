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
# A home and a store volume that outlive the container, as an update to a new image does; removed at the end.
vol=webtop-image-home pvol=webtop-image-persist
docker volume rm "$vol" "$pvol" >/dev/null 2>&1 || true
start() { docker run -d --name "$c" --privileged --cgroupns=private --shm-size=1g -p 127.0.0.1:8082:8082 -v "$vol:/home" -v "$pvol:/persist" "$image" >/dev/null; }
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
x test -s /etc/nsc/system-manifest.json || fail "no system manifest for the software center"
x systemctl show -P Environment webtop-session | grep -q 'NSC_SYSTEM_MANIFEST=/etc/nsc/system-manifest.json'   || fail "the session does not point the software center at the manifest"
echo "software center manifest: ok"

# The container module and the module defaults, as a standalone user gets them.
x sh -c 'command -v ps && command -v ip && command -v lsof' >/dev/null || fail "admin tools are missing"
[ "$(asuser systemctl --user show -P RuntimeMaxUSec drkonqi-coredump-pickup.service)" = infinity ] || fail "DrKonqi's pickup keeps a runtime limit"
pid=$(asuser systemctl --user show -P MainPID selkies.service)
env=$(x sh -c "xargs -0 -n1 < /proc/$pid/environ")
grep -qx 'SELKIES_FRAMERATE=30,8-240' <<<"$env" || fail "default framerate missing: $(grep FRAMERATE <<<"$env")"
grep -qx 'XCURSOR_THEME=breeze_cursors' <<<"$env" || fail "XCURSOR_THEME missing"
x id -nG user | grep -qw wheel && fail "the desktop user is in wheel without services.webtop.sudo"
echo "container module: ok"

# The image's store is the overlay's lower layer: its DB must register exactly the paths in it.
lower='local?root=/.lower&read-only=true'
db=$(x nix-store --store "$lower" --dump-db | awk 'BEGIN{st=0} { if (st==0) {print; st=1} else if (st<4) st++; else if (st==4) { n=$0+0; st = n ? 5 : 0 } else if (--n == 0) st=0 }' | sort)
store=$(x ls -A /.lower/nix/store | grep -vx '\.links' | sed 's|^|/nix/store/|' | sort)
[ "$db" = "$store" ] || fail "DB and store differ: $(diff <(echo "$db") <(echo "$store") | head -n 20)"
echo "Nix DB: all $(wc -l <<<"$db") store paths, nothing else"
x grep -q ' /nix/store overlay ' /proc/self/mounts || fail "/nix/store is not the store overlay"
x test -d /persist/nix/upper || fail "the overlay's upper layer is not on /persist"
x nix-store --verify-path /run/current-system || fail "/run/current-system does not verify"

# Sleep (ADR 0012): offered, freezes the session, and thaws when the unit stops.
[ "$(x busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend)" = 's "yes"' ] \
  || fail "Sleep is not offered (the /sys/power stand-in)"
x systemctl start --no-block systemd-suspend.service
wait_for "frozen session" x test -s /run/webtop/frozen-units
x systemctl stop systemd-suspend.service
thawed() { ! docker exec "$c" test -e /run/webtop/frozen-units; }
wait_for "thawed session" thawed
echo "sleep: ok"

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

# A new container on the same home and store volume (what an update to the same image looks like):
# the declared package and the profile package are still there.
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
touser cowsay ok >/dev/null || fail "the profile package did not survive the container"
touser nix profile add --profile-backend profile nixpkgs#tree || fail "the profile cannot be extended"
echo "same home and store volume: ok"

# A fresh store volume under the kept home (the store volume was lost): the first boot marks the
# reinstall due, it runs once, and the declared package is back.
docker rm -f "$c" >/dev/null
docker volume rm "$pvol" >/dev/null
start
deadline=$(($(date +%s) + timeout))
wait_for "KWin compositing on a fresh store volume" compositing
reinstall_done() { [ "$(x systemctl show -P ActiveState webtop-nix-reinstall)" != active ] && [ "$(x systemctl show -P ExecMainExitTimestampMonotonic webtop-nix-reinstall)" != 0 ]; }
wait_for "reinstall on a fresh store volume" reinstall_done
[ "$(x systemctl show -P Result webtop-nix-reinstall)" = success ] \
  || { x journalctl -u webtop-nix-reinstall --no-pager | tail -n 50; fail "webtop-nix-reinstall failed on a fresh store volume"; }
x test ! -e /persist/nix/reinstall/pending || fail "the reinstall marker is still set"
touser hello >/dev/null || fail "the declared package did not come back on a fresh store volume"
echo "fresh store volume, kept home: ok"

docker rm -f "$c" >/dev/null
docker volume rm "$vol" "$pvol" >/dev/null
echo "image boot: ok"
