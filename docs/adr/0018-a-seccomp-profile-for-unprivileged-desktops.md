# 0018 — A seccomp profile for unprivileged desktops

- Status: Accepted
- Date: 2026-11-12

## Context

An unprivileged desktop runs under its runtime's default seccomp profile. Kubernetes' RuntimeDefault
(containerd's) refuses `pivot_root`, which bubblewrap (`buildFHSEnv` apps, Flatpak) and OCI runtimes
(Podman's crun) need. Workarounds per program (chroot instead of pivot_root) weaken each program's
isolation; seccomp `Unconfined` drops the filter entirely.

## Decision

- This flake ships `seccomp/desktop.json`: containerd's RuntimeDefault, resolved for the desktop's
  capabilities, plus `pivot_root`, nothing else. It is for any desktop, whatever the module's
  options; deployments install it (Docker `--security-opt seccomp=`, a Kubernetes `Localhost`
  profile on every node).
- A check pins it to a copy of RuntimeDefault plus `pivot_root`; a containerd update that changes
  RuntimeDefault is taken over by regenerating both.

## Consequences

- With the profile, bubblewrap and containers work unchanged, under a filter that differs from
  RuntimeDefault by one syscall. `pivot_root` needs `CAP_SYS_ADMIN` in a namespace the caller owns,
  so it adds no reach beyond the desktop's own namespaces.
- Without it, `buildFHSEnv` apps fail, and containers fail with a pointer to the profile
  (ADR 0017).
- A Kubernetes pod whose `Localhost` profile is missing on its node does not start, so the profile
  is rolled out to nodes before a deployment selects it.
