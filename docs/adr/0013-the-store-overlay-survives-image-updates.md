# 0013 — The store overlay survives image updates

- Status: Accepted; takes over the update handling of kube-webtop-workspaces ADR 0008
- Date: 2026-11-10

## Context

ADR 0008 let a consumer run the Nix store as a `local-overlay` store but left the mounts and the
handling of an image update to it. The overlay requires its lower layer never to lose paths, which
an image update does. A standalone image needs the same, and its users' installed software must
not be lost to an update.

## Decision

- `storeOverlay.init` is a package of static busybox scripts for an entrypoint to run before
  systemd: `webtop-store-init` mounts the overlay (`index=off,xino=off`, userxattr) and binds the
  Nix state; `webtop-nix-lower` compares the image's stamp with the one on the volume;
  `webtop-nix-partial` invalidates, with Nix's own GC, only the upper paths the new store breaks, and
  falls back to moving the whole overlay to `trash-*`. Static, because they run before `/nix/store`
  is overlaid.
- With `nixProfile`, units restore the users' paths from `trash-*`, delete the trash and run
  `webtop-nix-reinstall` for the rest; `webtop-home-manager` waits for the reinstall's marker, and
  `nixProfile.fromImageStore` defaults to off. This amends the 2026-11-04 amendment of ADR 0006.
- The layout under `storeOverlay.persistPath` (`/persist/nix`: `upper work var lower-stamp
  lower-paths reinstall/ trash-*`), the stamp format and the mount options are those of the code
  this replaces, so existing volumes need no migration. `tests/store-overlay-layout-test.sh` pins
  them and `tests/lower-swap-test.sh` runs an update end to end.
- The standalone image has the overlay always on and declares `VOLUME /persist`: the Nix settings,
  the daemon's `NIX_CONFIG` and the restore units' conditions stay evaluation-time, not runtime
  switches.

## Consequences

- A home that outlives its store (a fresh volume): the first boot sets `reinstall/pending` when a home
  has a Nix profile, so the reinstall runs once; undeclared profile packages are lost unless a manifest
  was recorded.
- The scripts take the volume, the lower root and the homes' directory as parameters (`persistPath`,
  `lowerRoot`, `WEBTOP_HOMES_ROOT`) with the former values as defaults.
- Existing volumes keep working only while the layout stays: a change needs a migration and a new ADR.
- `fsync-store-paths` is on by default with the overlay, which the partial invalidation relies on; this
  moves it from the consumer (ADR 0008) into the module as a default.
- Depends on the experimental `local-overlay-store` feature.
