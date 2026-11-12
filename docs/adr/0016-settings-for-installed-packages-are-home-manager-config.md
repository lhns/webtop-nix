# 0016 — Settings for installed packages are home-manager config that reads the declaration

- Status: Accepted; extends ADR 0014
- Date: 2026-11-12

## Context

A package installed with `nix profile add` sometimes needs settings (a browser's policies, a
program's config file). [ADR 0014](0014-nix-profile-records-into-one-declaration.md) keeps
`packages.json` a list that the patched Nix rewrites on every change, so it cannot carry Nix code. A
home-manager module that installs the package itself (`programs.firefox`) builds its own wrapper,
which collides with the declared package at the same priority.

## Decision

- **`webtop.packages.installed`**, read-only, maps each declared package's flake ref and attribute as
  typed to `nix profile add` (`"nixpkgs#firefox"`) to its element name. It comes from `packages.json`
  alone, so `lib.mkIf (config.webtop.packages.installed ? "nixpkgs#firefox") { … }` cannot recurse.
  The element name is not the key: Nix may rename it.
- **Mappings are ordinary home-manager config**, in the user's `home.nix`/`local.nix` or the admin's
  `home.nix`. This flake ships the mechanism only: no curated mappings, no import of a package flake's
  modules.
- **`webtop.packages.replaced`** lists keys the configuration installs itself; the declared entry is
  left out of `home.packages`. On a collision the profile hook prints a hint naming it.

## Consequences

- Removing a package turns its mapping off, so a mapping whose values break does not block the remove.
  One that sets an option that no longer exists fails every switch, `mkIf` or not, like a broken
  `local.nix`; the error names the option and the file.
- `nixpkgs#x` and `nixpkgs-unfree#x` are different keys.
- Rejected: Nix code in `packages.json` (lost on the next rewrite); a lower priority for declared
  packages (changes what `--priority` means against `home.packages` and hides real collisions).
