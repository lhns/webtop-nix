# 0004 — Patched KWin, grafted in, for GPU-less hosts

- Status: Accepted
- Date: 2026-10-29

## Context

KWin 6.8 removed QPainter compositing. Its nested Wayland backend needs the host compositor to offer
linux-dmabuf and a render device; pixelflux (ADR 0001) without a GPU offers only `wl_shm`, so KWin
reports "requires compositing" and the screen stays gray. Staying on Plasma 6.7 only postpones this.

## Decision

- Carry LinuxServer's `kwin-6.8-software-shm-presentation.patch` (vendored in `pkgs/kwin/`). Without
  `/dev/udmabuf` it renders with llvmpipe into memfd buffers, and when the host has no usable dmabuf
  it presents over `wl_shm`. With a GPU nothing changes.
- The patched KWin is a separate overlay attribute, **not** an override of `kdePackages.kwin`, and
  the module swaps it in with `system.replaceDependencies`, so plasma-workspace and other dependents
  are not rebuilt. The patch only adds functions to `libkwin`, which keeps that safe.
- Option `services.webtop.kwinSoftwarePresentation`, on by default. `pkgs/kwin.nix` accepts only
  KWin 6.8.x, so a Plasma bump fails evaluation instead of silently shipping a stale patch.
- `KWIN_COMPOSE=Q` is gone: from 6.8 any value other than OpenGL disables compositing.

## Consequences

- Plasma follows nixpkgs again; the cost is one KWin build (about an hour on a CI runner) per KWin or
  nixpkgs change, so consumers should cache it (`packages.<system>.kwin`).
- `replaceDependencies` reads the stock system's references, so evaluating a system builds the stock
  one first.
- The patch is third-party and the upstream repository declares no licence. It is a KWin derivative
  and carried under KWin's GPL. If KWin or LinuxServer fixes this upstream, drop the patch and the option.
