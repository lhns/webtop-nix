# 0010 — A screen lock is recorded and cleared at once; Lock is shown only on request

- Status: Accepted
- Date: 2026-11-05

## Context

The KDE lock greeter renders gray here and the user has no password, so a locked session cannot be used
again. Hiding Lock at build time (as before) left no way to let an environment offer it, for example
as "sign out at the identity provider".

## Decision

- `webtop-lock-guard` (user service) watches `org.freedesktop.ScreenSaver.ActiveChanged`, writes the time to
  `$XDG_RUNTIME_DIR/webtop/lock` and unlocks through logind. It runs whether Lock is shown or not, so there is
  never a greeter. The session and its processes are untouched.
- Whether Lock is shown is decided at each session start by `webtop-lock-config` (`/etc/xdg/kdeglobals`):
  `services.webtop.lockScreen` is the default, `WEBTOP_LOCK_SCREEN` in `lockEnvironmentFiles` overrides it.
  Autolock and lock on resume stay off in every case.

## Consequences

- Lock does not protect anything: it is a signal for the environment to act on, nothing more.
- Switching Lock needs a session restart, not an image rebuild.
- Detection relies on kscreenlocker's D-Bus signal; a different locker would need its own watcher.
