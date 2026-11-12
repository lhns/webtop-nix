#!/usr/bin/env bash
# An admin's system.nix built into the image with image/system/Dockerfile (ADR 0020), on the real image
# and its builder (<image>-builder), with docker build:
#   1. `{ }` gives the image back unchanged: the same system and stamp.
#   2. a module adding an /etc file and a unit, booted on a volume the stock image used: the image update
#      (ADR 0013) keeps the store overlay, the system in the image's DB is the one booted, the module applies.
#   3. the stock image again on that volume: the update back is clean as well, and the module is gone.
# Every build asserts that KWin is not compiled. Needs the network (cache.nixos.org).
#
# Usage: system-image-test.sh <image> <timeout-seconds-per-boot>
set -euo pipefail

image=$1
timeout=$2
here=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d) # /persist, /home, the build context
mkdir "$dir/persist" "$dir/home" "$dir/ctx"
c=webtop-system
fail() { echo "::error::$*"; exit 1; }
x() { docker exec "$c" "$@"; }
# A command in an image without booting it (the image has no shell: its static busybox).
id=$(docker create "$image")
bb=$(docker cp "$id:/webtop-entrypoint" - | tar -xO | head -n 1 | sed 's/^#!//')
docker rm "$id" >/dev/null
peek() { local i=$1; shift; docker run --rm --entrypoint "$bb" "$i" -c "PATH=${bb%/sh}; $*"; }

# build <tag> <system.nix content>: the derived image, its log in $dir/<tag>.log.
build() {
  cp "$here/image/system/Dockerfile" "$dir/ctx/Dockerfile"
  printf '%s\n' "$2" >"$dir/ctx/system.nix"
  local t0=$SECONDS
  DOCKER_BUILDKIT=1 docker build --progress plain --build-arg "IMAGE=$image" --build-arg "BUILDER=$image-builder" \
    -t "$1" "$dir/ctx" >"$dir/$1.log" 2>&1 || { tail -n 80 "$dir/$1.log"; fail "docker build of $1 failed"; }
  ! grep -q "building '/nix/store/[^']*-kwin-[0-9]" "$dir/$1.log" || fail "the build of $1 compiled KWin"
  echo "COST $1: $((SECONDS - t0)) s, $(grep -c 'copying path' "$dir/$1.log" || true) paths fetched;" \
    "$(grep -o 'webtop-system-build: [0-9]* store paths for the image ([^)]*)' "$dir/$1.log" || true);" \
    "top layer $(docker history --format '{{.Size}}' "$1" | head -n 1)"
}

boot() {
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker run -d --name "$c" --privileged --cgroupns=private --shm-size=1g -v "$dir/persist:/persist" -v "$dir/home:/home" "$1" >/dev/null
  local deadline=$(($(date +%s) + timeout))
  until x systemctl is-active -q webtop-session 2>/dev/null; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || { docker logs "$c" 2>&1 | tail -n 50; fail "the container exited"; }
    [ "$(date +%s)" -lt "$deadline" ] || { docker logs "$c" 2>&1 | tail -n 50; fail "no webtop-session within ${timeout}s"; }
    sleep 2
  done
}
stop() { docker stop -t 15 "$c" >/dev/null; }
current() { x readlink -f /run/current-system; }

stock_init=$(peek "$image" readlink /sbin/init)
stock_stamp=$(peek "$image" cat /webtop-image-stamp)

echo "== 1: system.nix { }"
build webtop-system-empty '{ }'
[ "$(peek webtop-system-empty readlink /sbin/init)" = "$stock_init" ] || fail "{ } changed the system"
[ "$(peek webtop-system-empty cat /webtop-image-stamp)" = "$stock_stamp" ] || fail "{ } changed the stamp"
grep -q 'the module changes nothing' "$dir/webtop-system-empty.log" || fail "the installer did not report an unchanged image"
echo "{ } leaves the image as it is: ok"

echo "== 2: a module, on a volume the stock image used"
boot "$image"
x systemctl is-active -q webtop-session || fail "the stock image did not start"
stop
build webtop-system-module '{ pkgs, ... }: {
  environment.etc."webtop-admin-test".text = "from system.nix\n";
  systemd.services.webtop-admin-test = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${pkgs.coreutils}/bin/true"; };
  };
}'
init=$(peek webtop-system-module readlink /sbin/init)
[ "$init" != "$stock_init" ] || fail "the module did not change /sbin/init"
[ "$(peek webtop-system-module cat /webtop-image-stamp)" != "$stock_stamp" ] || fail "the module did not change the stamp"
boot webtop-system-module
docker logs "$c" 2>&1 | grep -q 'store overlay kept' || { docker logs "$c" 2>&1 | grep webtop- | tail -n 30; fail "the image update did not keep the store overlay"; }
[ "$(current)/init" = "$init" ] || fail "booted $(current), not ${init%/init}"
x nix-store --check-validity "$(current)" || fail "the system is not valid in the overlay store"
[ "$(x nix-store --store 'local?root=/.lower&read-only=true' -q --hash "$(current)")" = "$(x nix-store -q --hash "$(current)")" ] ||
  fail "the system is not registered in the image's DB"
# The image's DB is exactly its store (as tests/lower-swap-test.sh checks for the stock image).
heads='BEGIN{st=0} { if (st==0) {print; st=1} else if (st<4) st++; else if (st==4) { n=$0+0; st = n ? 5 : 0 } else if (--n == 0) st=0 }'
lower_db=$(x sh -c "nix-store --store 'local?root=/.lower&read-only=true' --dump-db | awk '$heads' | sort")
diff <(x sh -c 'ls -A /.lower/nix/store' | grep -vx '\.links' | sed 's|^|/nix/store/|' | sort) <(cat <<<"$lower_db") ||
  fail "the image's DB and its store differ"
[ "$(x cat /etc/webtop-admin-test)" = "from system.nix" ] || fail "no /etc/webtop-admin-test"
[ "$(x systemctl is-active webtop-admin-test)" = active ] || fail "webtop-admin-test is not active"
x systemctl --failed --no-legend | grep . && fail "failed units on the module's system"
echo "the module's system boots from the image and the store overlay is kept: ok"
stop

echo "== 3: the stock image again"
boot "$image"
docker logs "$c" 2>&1 | grep -q 'store overlay kept' || fail "the update back did not keep the store overlay"
[ "$(current)/init" = "$stock_init" ] || fail "booted $(current), not the stock system"
! x test -e /etc/webtop-admin-test || fail "/etc/webtop-admin-test is still there"
echo "back to the stock image: ok"
docker rm -f "$c" >/dev/null
docker image rm webtop-system-empty webtop-system-module >/dev/null
sudo rm -rf "$dir"
