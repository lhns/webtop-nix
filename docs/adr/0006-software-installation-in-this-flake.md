# 0006 — Software installation from one declaration lives in this flake

- Status: Accepted
- Date: 2026-11-04

## Context

kube-webtop-workspaces built the patched `nix profile`, the `packages.json` declaration and the starter
home-manager flake for its image (its ADR 0013, which records the design). None of it is specific to
Kubernetes, and the standalone image should install software the same way.

## Decision

- **Principle:** webtop-nix holds what a single desktop needs without Kubernetes; kube-webtop-workspaces
  adds only multi-user orchestration (controller, gateway, agent, CRD).
- This flake owns them, as `services.webtop.nixProfile` (`modules/nix-profile`), and gains the inputs
  they need: `home-manager` and `flake-registry`. Consumers follow them, like `nixpkgs`.
- `nixProfile.enable` defaults to off: it builds Nix from source, changes what `nix profile` does for
  the user, and writes into the home, which needs a persistent home to be of use. The standalone
  image turns it on.
- `nixProfile.homeStoragePath` is the home's path on its storage, default `/home/<user>`.
  `templates.sha256` keys files by it, so a consumer keeps its value for as long as homes exist.
- The `webtop` flake keeps its registry name and directory name; with its bytes they decide the store
  path in users' `flake.lock`. The starter's rendered bytes are what recorded hashes compare to.
- What happens around an image update stays with the consumer: it extends the units by module merge,
  and `nixProfile.progress` (a no-op by default) reports a switch's progress to it.

## Consequences

- Module, patch and template changes reach kube-webtop-workspaces through its flake lock.
- A change to the starter is a template upgrade for every user: unmodified flakes follow it, edited
  ones get a notice.
- Nixpkgs bumps here must keep the Nix minor version the patch applies to, or rebase the patch.

## Amendment 2026-11-04

Without a persistent store the home outlives the image's store: `nixProfile.fromImageStore`, on by default, runs `webtop-nix-reinstall` (no manifest) ahead of the switch at each boot, so a new image brings back what is declared. A consumer with its own restore turns it off and runs the command after that.

Nix also carries `path-input-fingerprint.patch` on `nix-fetchers`, which rebuilds Nix's libraries and needs rebasing with a Nix bump too. It makes locked `path:` inputs use the fetcher cache, so evaluating a home flake no longer copies nixpkgs to the store each time.

## Amendment 2026-11-04 (2)

The patch takes its locks at commit and re-applies each command's change on current state: [ADR 0007](0007-nix-profile-commit-locks.md) has the lock order, [ADR 0009](0009-one-apply-lock-and-an-applied-marker.md) the apply lock.

## Amendment 2026-11-06

Nix also carries `daemon-eof-wait.patch` on `nix-store`, so the desktops run a patched daemon: a builder that closes its output before exiting is waited for, without blocking other builds, up to the new `builder-exit-timeout` setting (default 10 s), instead of killed on the log EOF. It needs rebasing with a Nix bump too.
