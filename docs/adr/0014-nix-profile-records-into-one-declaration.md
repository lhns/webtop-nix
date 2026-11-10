# 0014 — `nix profile` records into one declaration

- Status: Accepted; the design of ADR 0006's software installation, taking over kube-webtop-workspaces ADR 0013
- Date: 2026-11-10

## Context

A desktop had three ways to install software that did not know about each other: KDE Discover (on
NixOS only Flatpak and KDE add-ons), `nix profile` (recorded only in the profile's manifest) and
home-manager's `home.nix`. An image update had to reinstall imperative profile entries separately
from home-manager, and nothing showed one list of what the user installed.

## Decision

- **One declaration.** `~/.config/home-manager/packages.json`, next to `home.nix`, lists the user's
  packages. The `webtop` flake's `packages.nix` module reads it into `home.packages`: `flake:nixpkgs`
  entries from the configuration's own nixpkgs (the image's), others from their locked flake
  (`builtins.getFlake`, pure). Format: `{"version": 1, "elements": {name: element}}`, an element being
  what `manifest.json` records per element (`originalUrl`, `url`, `attrPath`, `outputs`, `priority`),
  without the derived `storePaths` and `active`.
- **`nix profile` edits it.** Nix is patched (a fork of `src/nix/profile.cc`, kept generic): backends
  chosen by the client-side setting `profile-backend` (`profile` = stock, `profile:<path>`, or
  `declaration:<path>`; `--profile P` is short for `profile:P`). In the declaration backend `add`
  resolves and builds flake installables and records them in the file, `remove` and `upgrade` edit
  it, `list` shows it with the profile's undeclared elements (marked, stock format). Store paths and
  undeclared elements go to the profile as before, as home-manager's own activation does, so any
  home-manager version works. A command that changes both is reverted as a whole if either fails.
- **A hook applies changes.** `profile-hook` runs after every change, in either backend; if it
  fails, the change is reverted. It must exit 0 only once the change is fully applied, and is
  required for the declaration backend. The image's hook runs `home-manager switch` for
  declaration changes (re-activating the previous generation on failure) and does nothing for
  profile changes, which keeps home-manager's own installs cheap and avoids recursion.
- **History is the declaration's.** Each change keeps the file as a generation of the profile
  `declaration` next to the user's profile; `history`, `rollback` and `wipe-history` use Nix's
  generation code on it, and `rollback` runs the hook. It covers the package list only.
- **Scoped to the user.** `packages.nix` writes the two settings into the user's
  `~/.config/nix/nix.conf`, not `nix.settings`, which home-manager validates with an unpatched Nix.
  The system and root keep stock behaviour.

## Consequences

- One list (`nix profile list`, `packages.json`, git-trackable) and one apply step; an image update
  reinstates everything declared with `home-manager switch`.
- Nix is built from source, pinned to a minor version; a nixpkgs bump to another minor needs the
  patch rebased.
- The software center is the GUI over the same commands. Discover stays excluded; KDE add-ons from
  "Get New..." dialogs live in `~/.local/share`, outside the declaration.
