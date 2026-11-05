# 0008 — One apply lock and an applied marker: commands cannot half-apply or interleave

- Status: Accepted
- Date: 2026-11-05

## Context

[ADR 0007](0007-nix-profile-commit-locks.md) serializes the commit of a `nix profile` command. What a
command declares must also be applied, by home-manager, and that can be started from a hook, a terminal,
the boot unit or a restore, in any mix, and any of them can be cancelled or killed.

## Decision

- `L_A`, `~/.local/state/webtop/home-manager.lock`, covers home-manager from evaluation through activation.
  Order: `L_D` → `L_A` → `L_P`. Everything takes it with `flock -o`, so the holder is the `flock` process,
  not the script, and what an activation leaves running does not hold it.
  `WEBTOP_HM_LOCK_HELD` marks the holder's own children.
- Who takes it: the profile hook; the `home-manager` wrapper (in the image and, with a higher priority than
  the real one, in the user's profile); every activation of a generation with the packages module (it
  runs itself again under `flock`, so the real binary is covered too); the boot, update and reinstall scripts.
- The `applied` marker, `~/.local/state/webtop/applied`, is the hash of the `packages.json` the active
  generation was built from, written by activation. The hook exits 0 only if it matches the file and the
  generation link is live. That is the one fact behind retry repair, boot repair (the boot unit switches if
  a marker exists and differs) and the refusal below.
- An activation of a generation built from an older `packages.json` exits 75 and puts the generation
  pointer back; the terminal command is run again. `WEBTOP_ACTIVATE_ANY=1` skips the check, for the hook
  re-activating the previous generation and for `--rollback`, which the next hook or boot re-applies forward:
  the declaration is the truth.
- The hook runs in a session of its own and holds `L_A` through a `flock` that is its child. A cancel makes
  Nix kill the hook process; what it started keeps running under the lock, and Nix runs the hook again
  instead of reverting, which waits for the lock and then finds the marker matching. A command that
  changes nothing still runs the hook, so a retry applies what a killed command left.
- A store path added to the profile takes `L_D` first, so it cannot interleave with a declaration command
  (this closes the window recorded in 0007). A hook or an activation adds store paths itself and runs inside
  those locks: it is told apart by `NIX_PROFILE_BACKEND`, which the `home-manager` wrapper also sets for any
  generation it runs, and takes no `L_D`.
- home-manager's install of its own generation drops and adds `home-manager-path` in one generation
  (`nix profile add --replace NAME`), under whatever name the profile has it. Without the patched Nix it
  removes and adds as before. The packages module replaces upstream's `installPackages` entry; a test fails
  if the upstream text changes.

## Consequences

- A terminal `home-manager switch` that races a package change fails with a message and is run again; the
  boot script does that itself. Activating an older generation directly is refused the same way, and the
  message names `WEBTOP_ACTIVATE_ANY=1`.
- Stock `nix profile` from a terminal still takes none of these locks, and a user flake that drops the
  packages module loses the activation side of this.
- Killing the `flock` process itself (not the script) releases the lock while the switch it started runs on.
- `flake.lock` is not written atomically by Nix; a direct call to the real binary can still tear it.
- Locks are `flock` files in the home and need the home's file system to support them. They release with their
  holder, so an OOM kill of the whole container leaves nothing held; the marker repairs at boot.
