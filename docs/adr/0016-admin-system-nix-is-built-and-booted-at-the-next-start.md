# 0016 — The admin's system.nix is built from the image's own configuration and booted at the next start

- Status: Accepted; extends ADR 0015
- Date: 2026-11-12

## Context

Some admin defaults are system settings (a unit, a file in `/etc`, a system package), which the
defaults directory could not carry without a derived image. A NixOS system cannot be changed piecewise:
copying files into `/etc` or units into `/run/systemd/system` would be a second, partial activation
beside NixOS's own. A switch on a running desktop restarts units under the user's session.

## Decision

- `system.nix` in the defaults directory is a NixOS module. With `services.webtop.defaults.system`
  (the image's flake and its `nixosConfigurations` name) the image carries the flake's source and its
  inputs', and `webtop-defaults-system.service` rebuilds that configuration with `extendModules` into
  a profile on the volume, only when the image's stamp or `system.nix`'s hash changed.
- The entrypoint execs the profile's `init` in place of `/sbin/init` when the profile was built for this
  image and the current `system.nix`; otherwise the image's system. Nothing is switched while it runs.
- The build runs in the booted system (daemon, memory limit, journal, the defaults notice on failure),
  not in the entrypoint: a failure there would leave no desktop.

## Consequences

- A change applies at the second start: the first runs the image's system and builds. The same after
  every image update.
- A rebuild evaluates the whole system and, because of the graft (ADR 0004), realises the system as
  nixpkgs builds it, which the image does not carry: it needs the network and about a GB of downloads,
  again after each nixpkgs update. The image carries the graft's replacements as built (the patched
  KWin's closure), which reading their references needs; else every desktop would compile KWin.
- A `system.nix` that does not build changes nothing; one that builds but breaks the system is undone
  by changing it, since the entrypoint then boots the image's system.
- Needs the store overlay, and a defaults source that is a mount (readable before systemd).
