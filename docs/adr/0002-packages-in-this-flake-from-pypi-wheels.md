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

## Amendment 2026-11-01

pixelflux and pcmflux are built from source at the commits that released their wheels; only selkies
is still a wheel, and it is pure Python. The overlay keeps Python 3.13 as the tested interpreter.

## Amendment 2026-11-01 (Python)

The Python 3.13 pin is lifted: the overlay uses the default `python3Packages`. The selkies wheel is
`py3-none-any` (Python >= 3.9) and pixelflux and pcmflux build from source.

## Amendment 2026-11-13

selkies is built from source too, at the commit that released 2.1.0, web client included; the wheel is
gone, and changes to the web client are patches against its source.
