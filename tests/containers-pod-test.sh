#!/usr/bin/env bash
# Containers in the image when it runs the way a Kubernetes desktop pod runs it: not privileged, a
# 65,536-id user namespace, SYS_ADMIN and SYS_NICE added, an unmasked /proc, a seccomp profile that
# refuses pivot_root and keyctl as the RuntimeDefault profile does there, no /dev/fuse. Once without
# /dev/net/tun (the host network is the default), once with it (pasta, compose networks).
# Rootful podman runs the outer container: it gives a systemd container a writable cgroup unprivileged.
#
# Usage: containers-pod-test.sh <image> <timeout-seconds>
set -euo pipefail

image=$1
timeout=$2
c=webtop-pod
here=$(cd "$(dirname "$0")" && pwd)
P() { sudo podman "$@"; }
fail() { echo "::error::$*"; P logs "$c" 2>&1 | tail -n 60; P exec "$c" journalctl -b --no-pager 2>/dev/null | grep -iE 'podman|containers|conmon|pasta' | tail -n 60; exit 1; }
x() { P exec "$c" "$@"; }
xi() { P exec -i "$c" "$@"; }
# A login shell: DOCKER_HOST from the session environment, as in a terminal.
asuser() { x runuser -l user -c "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus; $1"; }

docker save "$image" | P load >/dev/null
caps=CHOWN,DAC_OVERRIDE,FOWNER,FSETID,KILL,NET_BIND_SERVICE,SETFCAP,SETGID,SETPCAP,SETUID,SYS_CHROOT,MKNOD,AUDIT_WRITE,NET_RAW,SYS_ADMIN,SYS_NICE

run() { # <scenario> [podman run args...]
  local scenario=$1; shift
  P rm -f "$c" >/dev/null 2>&1 || true
  P volume rm -f webtop-pod-home webtop-pod-persist >/dev/null 2>&1 || true
  P run -d --name "$c" --systemd=always --cap-drop=all --cap-add="$caps" \
    --uidmap 0:1000000:65536 --gidmap 0:1000000:65536 \
    --security-opt seccomp="$here/fixtures/pod-seccomp.json" --security-opt apparmor=unconfined \
    --security-opt unmask=ALL --shm-size=1g \
    -v webtop-pod-home:/home -v webtop-pod-persist:/persist "$@" "$image" >/dev/null
  local deadline=$(($(date +%s) + timeout))
  until x systemctl is-active -q user@1000.service 2>/dev/null && x systemctl is-active -q webtop-containers-runtime 2>/dev/null; do
    [ "$(P inspect -f '{{.State.Running}}' "$c")" = true ] || fail "$scenario: the container exited"
    [ "$(date +%s)" -lt "$deadline" ] || fail "$scenario: no user manager within ${timeout}s"
    sleep 3
  done
  echo "$scenario: booted"
  conf=$(x cat /run/webtop/containers-runtime.conf)
  grep -q 'no_pivot_root = true' <<<"$conf" && grep -q 'keyring = false' <<<"$conf" \
    || fail "$scenario: the refused syscalls were not detected: $conf"
  [ "$(asuser 'echo $DOCKER_HOST')" = unix:///run/user/1000/podman/podman.sock ] || fail "$scenario: DOCKER_HOST"
  asuser 'docker pull -q docker.io/library/alpine:3 >/dev/null' || fail "$scenario: docker pull"
  [ "$(asuser 'docker run --rm docker.io/library/alpine:3 echo ran')" = ran ] || fail "$scenario: docker run"
  asuser 'mkdir -p ~/bm && echo hi > ~/bm/in'
  [ "$(asuser 'docker run --rm -v ~/bm:/bm docker.io/library/alpine:3 sh -c "cat /bm/in; echo out > /bm/out"')" = hi ] \
    && [ "$(x stat -c %U /home/user/bm/out)" = user ] || fail "$scenario: bind mount"
  # RUN needs a network namespace for the build; the context's overlay must not sit on /var/tmp.
  asuser 'mkdir -p ~/proj && printf "FROM docker.io/library/alpine:3\nRUN echo built > /built\n" > ~/proj/Dockerfile'
  asuser 'docker build -q -t localhost/built ~/proj >/dev/null' || fail "$scenario: docker build"
  [ "$(asuser 'docker run --rm localhost/built cat /built')" = built ] || fail "$scenario: the built image"
  echo "$scenario: docker run, bind mount, docker build: ok"
}

# Compose through the API socket: a build, and a client reaching the server.
compose() { # <scenario> <network lines for both services>
  xi runuser -l user -c 'cat > ~/proj/compose.yaml' <<EOF
services:
  web:
    build: .
    command: ["sh", "-c", "mkdir -p /www && echo compose-ok > /www/index.html && httpd -f -p 18080 -h /www"]
$2
  client:
    image: docker.io/library/alpine:3
    depends_on: [web]
    command: ["sh", "-c", "for i in \$\$(seq 60); do wget -q -O- http://\$\${WEB_HOST}:18080/ && exit 0; sleep 1; done; exit 1"]
$2
EOF
  out=$(asuser 'cd ~/proj && docker compose up --build --abort-on-container-exit --exit-code-from client 2>&1') \
    || { echo "$out" | tail -n 40; fail "$1: docker compose up"; }
  grep -q compose-ok <<<"$out" || { echo "$out" | tail -n 40; fail "$1: compose client got no answer"; }
  asuser 'cd ~/proj && docker compose down >/dev/null 2>&1'
  echo "$1: docker compose: ok"
}

run no-tun
grep -q 'netns = "host"' <<<"$conf" || fail "no-tun: the host network is not the default: $conf"
compose no-tun $'    network_mode: host\n    environment: [WEB_HOST=127.0.0.1]'

run tun --device /dev/net/tun
! grep -q netns <<<"$conf" || fail "tun: the host network is the default although tun works: $conf"
[ "$(asuser 'docker run --rm docker.io/library/alpine:3 readlink /proc/self/ns/net')" != "$(x readlink /proc/1/ns/net)" ] \
  || fail "tun: the container is in the host's network namespace"
compose tun '    environment: [WEB_HOST=web]'

P rm -f "$c" >/dev/null
P volume rm -f webtop-pod-home webtop-pod-persist >/dev/null
