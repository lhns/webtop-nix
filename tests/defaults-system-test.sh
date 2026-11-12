#!/usr/bin/env bash
# The admin's system.nix (ADR 0016) on the real image: webtop-defaults-system.service rebuilds the image's
# own configuration with it, and the entrypoint boots the result at the next start. Boots on one volume:
#   1. system.nix `{ }`: the rebuild from the image's shipped source is the image's own system.
#   2. a real module: the first start runs the image's system and builds; the next boots the build
#      (its file and unit there), and an unchanged system.nix is not rebuilt.
#   3. an image update, edited offline as tests/lower-swap-test.sh does (a second image would be another
#      multi-GB build): the built system's etc "was in the old image", so the partial invalidation
#      drops the build, and the key names the old image. The image's system boots and the unit rebuilds.
#   4. a module that does not evaluate: the image's system, no profile, and the defaults notice.
# Needs the network: the rebuild realises the system as nixpkgs builds it (the graft, README "KWin
# without a GPU").
#
# Usage: defaults-system-test.sh <image> <timeout-seconds-per-boot> <timeout-seconds-per-build>
set -euo pipefail

image=$1
timeout=$2
build_timeout=$3
dir=$(mktemp -d) # /persist, /home and the defaults directory
mkdir "$dir/persist" "$dir/home" "$dir/defaults"
c=webtop-defaults-system
profile=/nix/var/nix/profiles/webtop-defaults-system
fail() { echo "::error::$*"; x journalctl -u webtop-defaults-system --no-pager -o cat 2>/dev/null | tail -n 60 || true; exit 1; }
x() { docker exec "$c" "$@"; }

boot() {
  docker rm -f "$c" >/dev/null 2>&1 || true
  docker run -d --name "$c" --privileged --cgroupns=private --shm-size=1g -v "$dir/persist:/persist" -v "$dir/home:/home" \
    -v "$dir/defaults:/etc/webtop/defaults:ro" "$image" >/dev/null
  local deadline=$(($(date +%s) + timeout))
  until x systemctl show -P ActiveState webtop-defaults.service 2>/dev/null | grep -qx active; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = true ] || { docker logs "$c" 2>&1 | tail -n 50; fail "the container exited"; }
    [ "$(date +%s)" -lt "$deadline" ] || { docker logs "$c" 2>&1 | tail -n 50; fail "no defaults snapshot within ${timeout}s"; }
    sleep 2
  done
}
stop() { docker stop -t 15 "$c" >/dev/null; }
booted() { docker logs "$c" 2>&1 | sed -n 's/^webtop-defaults-boot: exec //p' | tail -n 1; }
current() { x readlink -f /run/current-system; }
built() { x readlink -f "$profile"; }
log() { x journalctl -u webtop-defaults-system --no-pager -o cat; }
# Until the unit's run of this boot ended. A rebuild must not compile the patched KWin (the image
# carries it as built: modules/defaults-system.nix).
wait_build() {
  local deadline=$(($(date +%s) + build_timeout))
  while [ "$(x systemctl show -P ExecMainExitTimestampMonotonic webtop-defaults-system)" = 0 ] ||
        [ "$(x systemctl show -P ActiveState webtop-defaults-system)" = active ]; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "webtop-defaults-system did not finish within ${build_timeout}s"
    sleep 5
  done
  ! log | grep -q "^building '/nix/store/[^']*-kwin-[0-9]" || fail "the rebuild compiled KWin"
}
result() { x systemctl show -P Result webtop-defaults-system; }
# What a build cost, for the log: time, evaluator memory, paths fetched, the upper's size.
cost() {
  local t0 t1
  t0=$(x systemctl show -P ExecMainStartTimestampMonotonic webtop-defaults-system)
  t1=$(x systemctl show -P ExecMainExitTimestampMonotonic webtop-defaults-system)
  echo "COST $1: $(((t1 - t0) / 1000000)) s, peak $(($(x systemctl show -P MemoryPeak webtop-defaults-system) / 1048576)) MiB," \
    "$(log | grep -c '^copying path') paths fetched, upper $(sudo du -sh "$dir/persist/nix/upper" | cut -f1)," \
    "$(x sh -c 'ls /persist/nix/upper | grep -c "\.drv$"') derivations in the upper"
  # Per minute of the boot: paths fetched, derivations built, other lines (evaluation is silent).
  x journalctl -u webtop-defaults-system -o short-monotonic --no-pager | awk '
    { t = $0; sub(/^\[ */, "", t); m = int(t / 60); n[m]++ }
    /copying path/ { c[m]++ } / building / { b[m]++ }
    END { for (m in n) printf "  min %d: %d fetched, %d built, %d lines\n", m, c[m], b[m], n[m] }' | sort -n -k2
}

echo "== 1: system.nix { }"
echo '{ }' >"$dir/defaults/system.nix"
boot
image_system=$(current)
[ "$(booted)" = /sbin/init ] || fail "booted $(booted) without a build"
wait_build
[ "$(result)" = success ] || fail "the build of { } failed"
cost "first build"
[ "$(built)" = "$image_system" ] || fail "rebuilt from the shipped source, the image's own system is $(built), not $image_system"
echo "the rebuild is the image's own system: ok"
stop

echo "== 2: a module"
cat >"$dir/defaults/system.nix" <<'EOF'
{ pkgs, ... }: {
  environment.etc."webtop-admin-test".text = "from system.nix\n";
  systemd.services.webtop-admin-test = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${pkgs.coreutils}/bin/true"; };
  };
}
EOF
boot
[ "$(booted)" = /sbin/init ] || fail "booted $(booted), built for the former system.nix"
[ "$(current)" = "$image_system" ] || fail "not the image's system"
wait_build
[ "$(result)" = success ] || fail "the build failed"
cost "a changed system.nix"
first=$(built)
[ "$first" != "$image_system" ] || fail "the module changed nothing"
! x test -e /etc/webtop-admin-test || fail "applied to the running system"
stop
boot
[ "$(booted)" = "$profile/init" ] || fail "did not boot the build: $(booted)"
[ "$(current)" = "$first" ] || fail "running $(current), not the build $first"
[ "$(x cat /etc/webtop-admin-test)" = "from system.nix" ] || fail "no /etc/webtop-admin-test"
[ "$(x systemctl is-active webtop-admin-test)" = active ] || fail "webtop-admin-test is not active"
wait_build
[ "$(result)" = success ] || fail "the unit failed on the built system"
log | grep -q 'up to date' || fail "rebuilt an unchanged system.nix"
[ "$(built)" = "$first" ] || fail "the profile changed"
x systemctl show -P ActiveState webtop-session | grep -qx active || fail "the session does not run on the built system"
echo "applied at the next start, not rebuilt when unchanged: ok"
etc=$(x nix-store -q --references "$first" | grep -- '-etc$') || fail "no etc in $first"
stop

echo "== 3: an image update"
sudo rm -rf "$dir/persist/nix/upper/${etc#/nix/store/}"
echo "$etc" | sudo tee -a "$dir/persist/nix/lower-paths" >/dev/null
sudo sed -i '1s/.*/stamp old-image/' "$dir/persist/nix/lower-paths"
echo old-image | sudo tee "$dir/persist/nix/lower-stamp" >/dev/null
sudo sed -i 's/^[^ ]* /old-image /' "$dir/persist/nix/var/profiles/webtop-defaults-system.key"
boot
docker logs "$c" 2>&1 | grep -q 'store overlay kept' || fail "the partial invalidation did not run or fell back"
! x nix-store --check-validity "$first" 2>/dev/null || fail "the build survived the invalidation of its etc"
[ "$(booted)" = /sbin/init ] || fail "booted $(booted), built for another image"
wait_build
[ "$(result)" = success ] || fail "the rebuild failed"
cost "after the image update"
log | grep -q '^webtop-defaults-system: building' || fail "did not rebuild"
[ "$(sudo cut -d' ' -f1 "$dir/persist/nix/var/profiles/webtop-defaults-system.key")" = "$(x cat /webtop-image-stamp)" ] || fail "the key does not name this image"
echo "rebuilt after an image update: ok"
stop

echo "== 4: a module that does not evaluate"
echo '{ config, ... }: { services.webtop.noSuchOption = true; }' >"$dir/defaults/system.nix"
boot
[ "$(booted)" = /sbin/init ] || fail "booted $(booted) for a changed system.nix"
wait_build
[ "$(result)" != success ] || fail "the broken module built"
! x test -e "$profile" || fail "a profile is left"
x head -n 1 /run/webtop/defaults-notice | grep -qx 'Admin defaults: system.nix not applied' || fail "no notice"
for _ in $(seq 1 30); do
  x journalctl -u webtop-defaults-notice --no-pager -o cat | grep -q 'notifying: Admin defaults: system.nix not applied' && break
  sleep 3
done
x journalctl -u webtop-defaults-notice --no-pager -o cat | grep -q 'notifying: Admin defaults: system.nix not applied' || fail "the notice unit did not run"
x systemctl show -P ActiveState webtop-session | grep -qx active || fail "the session does not run"
docker rm -f "$c" >/dev/null
sudo rm -rf "$dir"
echo "a broken system.nix keeps the image's system: ok"
