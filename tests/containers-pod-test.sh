#!/usr/bin/env bash
# Containers and bubblewrap in the image when it runs the way a Kubernetes desktop pod runs it: not
# privileged, a 65,536-id user namespace, SYS_ADMIN and SYS_NICE added, an unmasked /proc, no /dev/fuse.
#   runtime-default: containerd's RuntimeDefault seccomp profile (fixtures/runtime-default-seccomp.json),
#     no /dev/net/tun. Containers fail with a pointer to the profile; with noPivotRoot (the detection
#     rerun with --no-pivot-root) they run on the host network.
#   desktop-profile: seccomp/desktop.json and /dev/net/tun. Containers with their own networks, and a
#     buildFHSEnv app (bubblewrap).
# Rootful podman runs the outer container: it gives a systemd container a writable cgroup unprivileged.
#
# Usage: containers-pod-test.sh <image> <timeout-seconds>
set -euo pipefail

image=$1
timeout=$2
c=webtop-pod
here=$(cd "$(dirname "$0")" && pwd)
P() { sudo podman "$@"; }
fail() { echo "::error::$*"; P logs "$c" 2>&1 | tail -n 60; P exec "$c" journalctl -b --no-pager 2>/dev/null | grep -iE 'podman|containers|conmon|pasta|bwrap' | tail -n 60; exit 1; }
x() { P exec "$c" "$@"; }
xi() { P exec -i "$c" "$@"; }
# A login shell: DOCKER_HOST from the session environment, as in a terminal.
asuser() { x runuser -l user -c "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; $1"; }

# Ubuntu's AppArmor refuses user namespaces to unprivileged processes of unconfined profiles; nodes
# without that restriction are what is tested.
sudo sysctl -q -w kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
docker save "$image" | P load >/dev/null
caps=CHOWN,DAC_OVERRIDE,FOWNER,FSETID,KILL,NET_BIND_SERVICE,SETFCAP,SETGID,SETPCAP,SETUID,SYS_CHROOT,MKNOD,AUDIT_WRITE,NET_RAW,SYS_ADMIN,SYS_NICE

boot() { # <scenario> <seccomp profile> [podman run args...]
  scenario=$1; local profile=$2; shift 2
  P rm -f "$c" >/dev/null 2>&1 || true
  P volume rm -f webtop-pod-home webtop-pod-persist >/dev/null 2>&1 || true
  P run -d --name "$c" --systemd=always --cap-drop=all --cap-add="$caps" \
    --uidmap 0:1000000:65536 --gidmap 0:1000000:65536 \
    --security-opt seccomp="$profile" --security-opt apparmor=unconfined \
    --security-opt unmask=ALL --shm-size=1g --tmpfs /run:rw,suid,dev,exec,mode=755 \
    -v webtop-pod-home:/home -v webtop-pod-persist:/persist "$@" "$image" >/dev/null
  local deadline=$(($(date +%s) + timeout))
  until x systemctl is-active -q user@1000.service 2>/dev/null && x systemctl is-active -q webtop-containers-runtime 2>/dev/null; do
    [ "$(P inspect -f '{{.State.Running}}' "$c")" = true ] || fail "$scenario: the container exited"
    [ "$(date +%s)" -lt "$deadline" ] || fail "$scenario: no user manager within ${timeout}s"
    sleep 3
  done
  echo "$scenario: booted"
  conf=$(x cat /run/webtop/containers-runtime.conf)
  grep -q 'keyring = false' <<<"$conf" || fail "$scenario: the refused keyctl was not detected: $conf"
  [ "$(asuser 'echo $DOCKER_HOST')" = unix:///run/user/1000/podman/podman.sock ] || fail "$scenario: DOCKER_HOST"
  out=$(asuser 'docker pull -q docker.io/library/alpine:3 2>&1') || { echo "$out"; x sh -c 'findmnt -o TARGET,FSTYPE,OPTIONS /run /run/wrappers; getcap /run/wrappers/bin/newuidmap; cat /etc/subuid'; fail "$scenario: docker pull"; }
}

# run, a bind mount, build
exercise() {
  [ "$(asuser 'docker run --rm docker.io/library/alpine:3 echo ran')" = ran ] || fail "$scenario: docker run"
  asuser 'mkdir -p ~/bm && echo hi > ~/bm/in'
  [ "$(asuser 'docker run --rm -v ~/bm:/bm docker.io/library/alpine:3 sh -c "cat /bm/in; echo out > /bm/out"')" = hi ] \
    && [ "$(x stat -c %U /home/user/bm/out)" = user ] || fail "$scenario: bind mount"
  # RUN needs a network namespace for the build; the context's overlay must not sit on /var/tmp.
  asuser 'mkdir -p ~/proj && printf "FROM docker.io/library/alpine:3\nRUN echo built > /built\n" > ~/proj/Dockerfile'
  out=$(asuser 'docker build -q -t localhost/built ~/proj 2>&1') || { echo "$out" | tail -n 30; fail "$scenario: docker build"; }
  [ "$(asuser 'docker run --rm localhost/built cat /built')" = built ] || fail "$scenario: the built image"
  echo "$scenario: docker run, bind mount, docker build: ok"
}

# Compose through the API socket: a build, and a client reaching the server.
compose() { # <network lines for both services>
  xi runuser -l user -c 'cat > ~/proj/compose.yaml' <<EOF
services:
  web:
    build: .
    command: ["sh", "-c", "mkdir -p /www && echo compose-ok > /www/index.html && httpd -f -p 18080 -h /www"]
$1
  client:
    image: docker.io/library/alpine:3
    depends_on: [web]
    command: ["sh", "-c", "for i in \$\$(seq 60); do wget -q -O- http://\$\${WEB_HOST}:18080/ && exit 0; sleep 1; done; exit 1"]
$1
EOF
  out=$(asuser 'cd ~/proj && docker compose up --build --abort-on-container-exit --exit-code-from client 2>&1') \
    || { echo "$out" | tail -n 40; fail "$scenario: docker compose up"; }
  grep -q compose-ok <<<"$out" || { echo "$out" | tail -n 40; fail "$scenario: compose client got no answer"; }
  asuser 'cd ~/proj && docker compose down >/dev/null 2>&1'
  echo "$scenario: docker compose: ok"
}

boot runtime-default "$here/fixtures/runtime-default-seccomp.json"
grep -q 'netns = "host"' <<<"$conf" || fail "$scenario: the host network is not the default: $conf"
grep -q 'runtime = "webtop-pivot-root-refused"' <<<"$conf" || fail "$scenario: the refused pivot_root was not detected: $conf"
! out=$(asuser 'docker run --rm docker.io/library/alpine:3 echo ran 2>&1') || fail "$scenario: a container started without pivot_root"
grep -q 'Seccomp profile' <<<"$out" || { echo "$out"; fail "$scenario: the failure does not point to the profile"; }
echo "$scenario: containers fail with a pointer to the profile: ok"
# noPivotRoot, as the module passes it.
detect=$(x systemctl show -P ExecStart webtop-containers-runtime | grep -o '/nix/store/[^ ]*-webtop-containers-detect' | head -n 1)
x "$detect" --no-pivot-root /run/webtop/containers-runtime.conf >/dev/null
conf=$(x cat /run/webtop/containers-runtime.conf)
grep -q 'no_pivot_root = true' <<<"$conf" || fail "$scenario: noPivotRoot: $conf"
exercise
compose $'    network_mode: host\n    environment: [WEB_HOST=127.0.0.1]'

boot desktop-profile "$here/../seccomp/desktop.json" --device /dev/net/tun
! grep -qE 'netns|pivot_root' <<<"$conf" || fail "$scenario: fallbacks although nothing is refused: $conf"
exercise
[ "$(asuser 'docker run --rm docker.io/library/alpine:3 readlink /proc/self/ns/net')" != "$(x readlink /proc/1/ns/net)" ] \
  || fail "$scenario: the container is in the host's network namespace"
compose '    environment: [WEB_HOST=web]'
# A buildFHSEnv app (what jetbrains-toolbox, Steam and appimage-run are): bubblewrap pivot_roots.
fhs=$(asuser 'nix build --no-link --print-out-paths --impure --expr "(builtins.getFlake \"nixpkgs\").legacyPackages.\${builtins.currentSystem}.buildFHSEnv { name = \"fhs-probe\"; runScript = \"echo fhs-ok\"; }" 2>&1 | tail -n 1') \
  || { echo "$fhs"; fail "$scenario: building the buildFHSEnv app"; }
out=$(asuser "$fhs/bin/fhs-probe 2>&1") || true
[ "$out" = fhs-ok ] || { echo "$out"; fail "$scenario: the buildFHSEnv app did not start"; }
echo "$scenario: buildFHSEnv app: ok"

P rm -f "$c" >/dev/null
P volume rm -f webtop-pod-home webtop-pod-persist >/dev/null
