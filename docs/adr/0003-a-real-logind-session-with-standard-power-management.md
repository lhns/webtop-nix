# 0003 — A real logind session, with standard power management

- Status: Accepted
- Date: 2026-10-28

## Context

Session restore (ksmserver), idle actions (PowerDevil) and the logout dialog's shut down, restart
and sleep all depend on a proper Plasma session under systemd and logind. Starting KWin and
plasmashell by hand, as some container images do, loses all of them. There is no display manager
on a headless machine.

## Decision

- The desktop user gets a **logind session** from a system unit (`PAMName=login`, seat0) that runs
  `startplasma-wayland`; Plasma then runs as systemd user units, so ksmserver and PowerDevil work.
- **Power stays standard**: the user may power off, reboot and suspend through logind (polkit rule
  for that user). The module adds no hook of its own. Whatever must happen around a shutdown in a
  given environment attaches to systemd's `poweroff`, `reboot`, `halt` and sleep targets, outside
  this module.
- Defaults the user can override in `~/.config`: PowerDevil takes no idle action, and the session
  is restored at login.

## Consequences

- The module behaves like a desktop machine and knows nothing about where it runs.
- Environments without real suspend (e.g. containers) must decide themselves what suspend means.
- The defaults never shut a session down on their own; users opt in to idle shutdown.
