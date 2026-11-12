# 0017 — Rootless Podman for the desktop user, with the docker CLI

- Status: Accepted
- Date: 2026-11-12

## Context

Users want to run containers in their desktop, with `docker` and `docker compose` working as on a
workstation. The desktop itself often runs unprivileged: in Kubernetes as a pod with a user namespace of
65,536 ids, SYS_ADMIN and SYS_NICE, the runtime's default seccomp profile, and no `/dev/fuse` or
`/dev/net/tun`. That profile refuses `pivot_root` and `keyctl`. Rootless Docker needs 65,536
subordinate ids per user and its own daemon; Podman is daemonless, serves the docker API on demand and
works with fewer ids.

## Decision

- **`services.webtop.containers.enable`** (off in the module, on in the standalone image): rootless
  Podman for the desktop user. `docker` is Podman (`dockerCompat`), `docker compose` runs the
  docker-compose binary against the user's socket-activated Podman API, and the session sets
  `DOCKER_HOST` to that socket for other clients. No root daemon: the desktop user gets no privilege
  beyond its own namespaces.
- **Subordinate ids are explicit** (`containers.subIdRanges`), by default the ids of a 65,536-id
  namespace that no declared user or group, `nixbld` user or systemd dynamic user uses. A range that
  covers a declared id fails the evaluation: a container process would act as that user.
- **What the runtime refuses is detected at boot**, not configured: without a usable `/dev/net/tun`
  the host network is the default; a refused `keyctl` drops the session keyring. With nothing
  refused, Podman's defaults stay.
- **Containers keep `pivot_root`.** Where it is refused, the supported fix is the desktop's seccomp
  profile ([ADR 0018](0018-a-seccomp-profile-for-unprivileged-desktops.md)); until then containers
  fail with a message pointing to it. `containers.noPivotRoot` (off) starts them with `chroot`
  instead, for setups that cannot install the profile.
- Storage is native overlay below the user's home; temporary build data goes below the storage too.

## Consequences

- With `noPivotRoot`, a process that escapes a container's `chroot` lands in the user's own
  namespaces with the user's rights, which is weaker than stock; hence opt-in.
- Without `/dev/net/tun` only the host network works: `docker run -p` and compose networks fail,
  compose needs `network_mode: host`. A deployment that can mount the device gives full networking.
- An image file owned by an id outside the ranges (in the default, 57,416 and up, e.g. 65534) is
  unpacked as root, and a container cannot switch to such an id. A larger user namespace lifts this.
- The image grows by Podman and its helpers and docker-compose.
