# 0012 — Sleep freezes the session; an external stop saves it

- Status: Accepted; takes over kube-webtop-workspaces ADR 0009
- Date: 2026-11-10

## Context

A container cannot suspend, so Sleep would power the desktop off and the next visit cold-boot it.
The cgroup freezer (cgroup v2, systemd >= 255) stops a unit's processes without touching their
state. Separately, a stop from outside (`docker stop`, a pod deletion) takes the session down without
ksmserver saving it. Neither needs Kubernetes; both came with the first consumer's agent.

## Decision

- `services.webtop.sleep.mode` is `systemd`, `freeze` or `poweroff`. `systemd-suspend.service` runs
  `webtop-power suspend` for the last two: it freezes `plasma-*.service` in `session.slice` and
  everything in `app.slice`, blocks, and thaws on the next Selkies session, then exits 0 so logind
  and PowerDevil resume as on hardware. Selkies (the readiness probe and wake trigger), the session
  bus, audio and `background.slice` keep running.
- If freezing fails everything is thawed and Sleep falls back to `poweroff`: it writes
  `/run/webtop/sleep-poweroff` and starts `poweroff.target`. `WEBTOP_SUSPEND_MODE` (the name the
  first consumer already uses) switches between `freeze` and `poweroff` at runtime from
  `sleep.environmentFiles`. `sleep.hooks` tell a consumer `asleep` and `awake`.
- `webtop-session-save.service` (`sessionSave.enable`) saves the session when it is stopped before
  the session: on `halt.target` (SIGRTMIN+3) or after the marker above. It thaws first, because
  ksmserver must answer, and copies the "saved by user" group of `ksmserverrc` to the group Plasma
  restores. `systemctl poweroff` does not save, as on a real machine.
- The defaults for containers (`freeze`, save on) sit in `modules/webtop.nix`, keyed on
  `boot.isContainer`: ADR 0008 keeps the `container` module free of `services.webtop.*` values.
- The code is the first consumer's Go `freeze` and `session` packages with their tests, moved as they
  were into `pkgs/webtop-power` (`suspend`, `thaw`, `save-session`). The state is in `/run/webtop`.

## Consequences

- Waking is instant and loses nothing, but the container keeps its memory and CPU while asleep, and
  PowerDevil's idle shutdown cannot fire while frozen.
- Wake detection depends on Selkies' `/api/sessions`.
- Logind offers Sleep only if `/sys/power/state` is writable; a container's entrypoint must run
  `sleep.init`, or Sleep is never offered.
- Go becomes a build dependency of this flake. A shell rewrite was rejected: the retry per unit and
  the thaw on failure are where it would regress, and the tests move with the code.
