# 0017 — An admin's system module is built into a derived image

- Status: Accepted; amends ADR 0005 (a second, builder, image per build)
- Date: 2026-11-12

## Context

An admin needs system-level changes on every desktop (a package for all users, a service, a setting
of a NixOS module) without forking this flake or a consumer's. ADR 0015's defaults directory reaches
the user's layers only. Rebuilding the system on the desktop at boot needs the network, gigabytes of
store and a second start per change, in every desktop.

## Decision

- **A builder image per image build.** `lib.buildImage { builder = { flake; source; name; }; }` adds
  `.builder`: the same image (the same split layers, so the same blobs) plus one layer with
  `webtop-system-build`, the flake's source (a filtered copy) and its inputs' sources, and the KWin
  graft's replacements as built (ADR 0004), without which the rebuild compiles KWin. Published as
  `<tag>-builder`. The image itself is unchanged.
- **Two commands, one Dockerfile.** `webtop-system-build <system.nix>` (in the builder, a `RUN`, as
  root without a daemon) builds `nixosConfigurations.<name>` extended with the module and writes
  the store paths the image lacks, their registration and an installer to `/webtop-system`. The
  installer (in the stock image, with its own static busybox) copies them in, registers them in the
  image's Nix DB, points `/sbin/init` at the new system and derives `/webtop-image-stamp` from the old
  stamp and the added paths. `image/system/Dockerfile` is the two stages; the result is the stock
  image's layers plus one.
- **The store overlay sees an image update** (ADR 0013): a new stamp, a lower store that only gained
  paths. A module that changes nothing leaves the image and its stamp as they are.

## Consequences

- A change of `system.nix` is a new image, applied like any update: at the next start, with nothing
  to build on the desktop. Building it needs the network (cache.nixos.org: the stock system the graft
  reads) and a few GB of disk in the builder.
- The entrypoint stays the stock image's: the store overlay's and a consumer's entrypoint options
  (paths, users it reserves) are not changed by the module.
- The builder and the image must come from one build; the installer checks the stamp.
- The added layer is not bit-reproducible (the DB's registration times); its stamp is.
- Rejected: rebuilding on the desktop at boot (a second start per change, every desktop pays the
  build); the builder content in the image itself (about 180 MiB more for every pull).
