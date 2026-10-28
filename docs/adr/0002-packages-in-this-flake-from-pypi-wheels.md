# 0002 — Selkies packaged in this flake, from the PyPI wheels first

- Status: Accepted
- Date: 2026-10-28

## Context

Selkies, pixelflux and pcmflux are not in nixpkgs. pixelflux is Rust with PyO3 bindings and native
dependencies (EGL, gbm, VA-API, x264); all three publish manylinux wheels on PyPI, and the selkies
wheel already contains the built web client.

## Decision

- The packages live in this flake's overlay, not in nixpkgs. Upstreaming is optional and later.
- They are built from the **PyPI wheels** with `autoPatchelfHook`, pinned to the versions selkies
  requires. Building pixelflux and pcmflux from source replaces this later.

## Consequences

- Fast to get working; the compiled code is upstream's, not built by Nix.
- The wheels are cp313, so the overlay pins Python 3.13; a nixpkgs Python bump needs new wheel
  hashes.
- Runtime libraries pixelflux loads with `dlopen` must be listed explicitly; a missing one fails at
  runtime, not at build time.
