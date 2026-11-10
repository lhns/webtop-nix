# 0008 — A container module and the options a standalone desktop needs

- Status: Accepted
- Date: 2026-11-05

## Context

kube-webtop-workspaces (kww) built a container profile for its desktop image and several desktop
settings of its own. Apart from the controller, gateway, agent and pod contract, none of it needs
Kubernetes, and a standalone user of this flake wants the same desktop. ADR 0006 set the principle:
this flake holds what a single desktop needs; kww adds only multi-user orchestration.

## Decision

- `nixosModules.container` (`modules/container.nix`) is the desktop as a container with systemd as
  PID 1: runtime-owned networking and files, no consoles, no core dumps, no rtkit, no oomd. It sets
  neither `services.webtop.*` nor `system.stateVersion`. The standalone image is this module plus
  the desktop.
- Container-specific parts are options, off by default: `services.webtop.storeOverlay` (Nix daemon
  configuration for a `local-overlay` store; the mounts stay the entrypoint's job),
  `journalRelay` (journal to a fifo), `adminTools`.
- `services.webtop.sudo.enable` (off by default) puts the desktop user in `wheel` with an empty
  password. Defaults must not hand out privilege; a consumer that owns the container turns it on.
- Settings every desktop wants become module defaults: `XCURSOR_THEME`/`XCURSOR_SIZE`, a 30 fps start
  (`SELKIES_FRAMERATE`) and no runtime limit for DrKonqi's crash pickup, which otherwise reports the
  session degraded when no crash arrives. `extraEnvironment` still overrides them.
- The restore's progress writer (`webtop-restore-progress`, file contract under `/run/webtop/restore`)
  is the default of `nixProfile.progress`. The reader that shows it stays with its consumer.
- `storeOverlay` leaves `trusted-users`, `fsync-store-paths` and `sandbox` to the consumer: they
  depend on how the user is named and on what the runtime grants.

## Consequences

- A consumer needs `webtop` and `container` and sets what is its own; kww keeps only its pod wiring.
- The overlay store cannot be booted in the module's VM test (no overlay mount); `container-eval`
  evaluates it with every option on, and the standalone image test boots the module's other parts.
- Staying in kww: the entrypoint that mounts the overlay, the agent (power actions, boot progress,
  session save on an external stop), the restore scripts around an image update, the tray job.

## Amendment 2026-11-09

A consumer extends the desktop only through the options, env vars, files and commands listed in the
README's "Extension points"; the module's units are not an interface. Where a consumer needs a new
hook, it becomes an option here instead of a unit override there.

## Amendment 2026-11-10

Time zone and locale reach the desktop through the admin defaults directory
(`services.webtop.defaults.source`, ADR 0015), not environment files: `localeEnvironmentFiles` is removed.
