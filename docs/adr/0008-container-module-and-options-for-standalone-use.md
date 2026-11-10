# 0008 — A container module and the options a standalone desktop needs

- Status: Accepted
- Date: 2026-11-05

## Context

The first consumer built a container profile for its desktop image and several desktop
settings of its own. Apart from its orchestration, none of it needs
Kubernetes, and a standalone user of this flake wants the same desktop. ADR 0006 set the principle:
this flake holds what a single desktop needs; a consumer adds only its orchestration.

## Decision

- `nixosModules.container` (`modules/container.nix`) is the desktop as a container with systemd as
  PID 1: runtime-owned networking and files, no consoles, no core dumps, no rtkit, no oomd. It sets
  neither `services.webtop.*` nor `system.stateVersion`. The standalone image is this module plus
  the desktop.
- Container-specific parts are options, off by default: `services.webtop.storeOverlay` (Nix daemon
  configuration for a `local-overlay` store; the entrypoint runs the mount script),
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

- A consumer needs `webtop` and `container` and sets what is its own.
- The overlay store cannot be booted in the module's VM test (no overlay mount); `container-eval`
  evaluates it with every option on, and the standalone image test boots the module's other parts.
- Staying with a consumer: its entrypoint, its agent (reports to an orchestrator) and the display of
  the restore's progress.

## Amendment 2026-11-09

A consumer extends the desktop only through the options, env vars, files and commands listed in the
README's "Extension points"; the module's units are not an interface. Where a consumer needs a new
hook, it becomes an option here instead of a unit override there.

## Amendment 2026-11-10

The overlay entrypoint no longer stays with the consumer: this flake ships it (`storeOverlay.init`),
with the restore units and the Sleep and session-save handling (ADRs 0012, 0013). A consumer's
entrypoint calls it and keeps only its own parts.
