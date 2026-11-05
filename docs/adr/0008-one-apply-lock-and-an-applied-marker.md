# 0008 — One apply lock and an applied marker: commands cannot half-apply or interleave

- Status: Accepted
- Date: 2026-11-05

## Context

[ADR 0007](0007-nix-profile-commit-locks.md) serializes the commit of a `nix profile` command. What a
command declares must also be applied, by home-manager, and that can be started from a hook, a terminal,
the boot unit or a restore, in any mix, and any of them can be cancelled or killed.

## Decision

- `L_A`, `~/.local/state/webtop/home-manager.lock`, covers home-manager from evaluation through activation.
  Order: `L_D` → `L_A` → `L_G` → `L_P`. Everything takes it with `flock -o`, so the holder is the `flock`
  process, not the script, and what an activation leaves running does not hold it (without `-o` the children
  would inherit the lock, and one left in the background would block every later command).
  `WEBTOP_HM_LOCK_HELD` marks the holder's own children.
- `L_G`, `~/.local/state/webtop/activation.lock`, is held by each activation, under `L_A`. Its holder is the
  activation's parent, and the activation has that as `pdeathsig`: killing the holder stops the activation.
  So killing `L_A`'s holder, which releases `L_A` while its switch runs on, is no worse than the real binary:
  evaluations may overlap, activations cannot, and the freshness check runs under `L_G`.
- A process with `NIX_PROFILE_BACKEND` set is inside a hook or a switch and holds a later lock than `L_D`:
  it does not take `L_D` for a store path, and a declaration change from there fails at once.
- Who takes it: the profile hook; the `home-manager` wrapper (in the image and, with a higher priority than
  the real one, in the user's profile); every activation of a generation with the packages module (it
  runs itself again under `flock`, so the real binary is covered too); the boot, update and reinstall scripts.
- The `applied` marker, `~/.local/state/webtop/applied`, is the hash of the `packages.json` a generation was
  built from and that generation, written as activation's last step. The hook exits 0 only if it matches the
  file and the live generation, so a half-finished switch or a generation that never wrote one (an older one)
  does not count. That is the one fact behind retry repair, boot repair (the boot unit switches if
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

- A flake outside `~/.config/home-manager` is not supported for `nix profile`; hook and activation say so. It
  still switches when that directory has no `packages.json`.
- A terminal `home-manager switch` that races a package change fails with a message and is run again; the
  boot script does that itself. Activating an older generation directly is refused the same way, and the
  message names `WEBTOP_ACTIVATE_ANY=1`.
- Stock `nix profile` from a terminal still takes none of these locks, and a user flake that drops the
  packages module loses the activation side of this.
- Killing `L_A`'s holder allows a second evaluation next to the first: see above.
- `flake.lock` is not written atomically by Nix: a full disk or a crash can leave it invalid. The boot script
  sets it aside and relocks.
- Locks are `flock` files in the home and need the home's file system to support them. They release with their
  holder, so an OOM kill of the whole container leaves nothing held; the marker repairs at boot.

## Appendix: cases

`tests/nix-profile-concurrency.sh`, scenario in the last column (`scenario_` left out); a nightly job
repeats the parallel ones with more rounds. "Next" is the next command touching the declaration or the boot,
either of which repairs: marker and file or generation differ, so they switch. "Converges": file, manifest,
what is on `PATH` and the marker agree.

| Actor | Failure | Expected | Test |
|---|---|---|---|
| add, remove, upgrade, install, 4 at once, both backends | none | all applied, none lost or resurrected | parallel_adds, parallel_removes, upgrades, commands |
| add and remove of one name; two removes | none | either order, consistent | add_remove_same |
| fast add during a slow one; remove during a slow add | none | both kept | slow_during_fast |
| store path and declaration add | none | serial through `L_D`; a store path moves out when the flake output lands | store_path_lock, two_backends |
| rollback and add | none | one order, converges | commands |
| wipe-history and adds | none | none lost, history readable | commands |
| software center, 4 slots | none | as the commands above; its queue is tested in nix-software-center | parallel_adds; other repo |
| switch, 4 at once, wrapper and real binary | none | activations serial | activations |
| everything at once | none | serial, none lost; a raced switch 75 | mixed (nightly: 20 rounds) |
| terminal switch, either binary, raced by an add | none | 75, pointer back, the add applied | activations |
| boot script raced by an add | none | runs the switch again, exit 0 | activations |
| `--rollback`, then forward | none | allowed; a later hook or boot goes forward | activations |
| older generation activated directly | none | 75 and how to do it anyway | activations (same path) |
| generation without a marker entry live | none | next switches | repairs |
| generation without the install entry, under the wrapper | concurrent add | no deadlock: no `L_D` | store_path_lock |
| new generation under stock Nix | none | fallback remove and add | hm_atomic |
| hand edit, valid | none | next applies it | repairs |
| hand edit, invalid | none | commands fail with the parse error, file kept, boot notifies; the user fixes it | repairs |
| flake elsewhere, other `packages.json` | none | 75 with what to do | flake_elsewhere |
| flake elsewhere, no `packages.json` | none | switches with a note; `nix profile` says it does not exist | flake_elsewhere |
| no flake beside the declaration | none | command fails with what to do, file reverted | flake_elsewhere |
| declaration change from a user's activation entry | none | fails at once with a message | store_path_lock |
| GC, old generations too | during adds and removes | none lost, live generation kept | commands |
| `nix profile`, before commit | SIGINT, SIGTERM, SIGKILL | state untouched, no lock left | interrupted |
| `nix profile`, during commit or hook | SIGINT, SIGTERM | waits, ends applied | cancel, signal_sweep |
| `nix profile`, after the write | SIGKILL | orphan finishes under `L_A`; a retry converges | kill9_stages, signal_sweep |
| hook script | SIGTERM, SIGKILL | command fails and reverts, or succeeds; next converges | process_kills |
| activation | SIGTERM, SIGKILL | hook runs once more; converges | process_kills |
| `L_A`'s `flock`, terminal switch | SIGKILL | activation goes on, others wait on `L_G` | lock_holders |
| `L_G`'s `flock`, terminal switch | SIGKILL | activation stops; next converges | lock_holders |
| either `flock`, during a hook | SIGKILL | hook runs once more, command succeeds | lock_holders |
| `flock` of the boot or reinstall unit | any | it is the unit's main process: systemd ends the rest, the unit's marker stays, next boot retries | not testable here: pod; reasoned |
| terminal switch, in activation | Ctrl-C | half-activated, marker differs; next converges | process_kills |
| what an activation leaves running | none | holds no lock | activations |
| `kill -9` during `--replace` | SIGKILL | one `home-manager-path` | hm_atomic |
| all of it, memory-limited cgroup | kernel OOM with `memory.oom.group=1`, at hook and in activation | valid file, no lock held, marker differs; boot converges | cgroup (systemd unit, not a container) |
| all of it | SIGKILL of the cgroup after 2..26 s | valid file; boot converges | cgroup |
| all of it | pod deletion: SIGTERM, then SIGKILL | valid file; boot converges | cgroup (`systemctl stop`) |
| lock files after a restart | any | `flock` files hold nothing; the kernel released them | cgroup |
| crash between marker and switch | any | cannot happen: the marker is the last step | hm_atomic (order); cgroup |
| leftover `applied.tmp`, empty or short marker | any | next switches | repairs |
| command | full disk at the declaration | fails, file unchanged | disk_full |
| command | full disk at the state | fails, or marker differs; boot converges | disk_full |
| `flake.lock` left invalid | full disk, crash | boot sets it aside and relocks | repairs |
| Store, daemon | full disk | a failed build: below | as a failed build |
| command | build or network failure | fails, nothing committed | repairs |
| switch in a hook | does not evaluate, activation fails | command fails, file reverted, previous generation active | repairs |
| reinstall and an install | none | wait for each other | reinstall |
| reinstall | SIGKILL half-way | next run finishes; marker kept | nix-profile-reinstall-test |
| image update | dangling generations, marker from before | moved aside, boot switches | reinstall; kube-webtop-workspaces lower-swap-test |
| image update | during an install | pod restart: as pod deletion | cgroup |
| terminal stock `nix profile` | none | no lock possible | accepted, ADR 0007 |
| user flake without the packages module | none | no activation lock or marker, by choice | accepted |
| direct real binary tearing `flake.lock` in a crash | crash | as `flake.lock` above | repairs |
| flock on the real home volume | | ext4 on RBD: exclusion and release on a real desktop checked by hand | by hand, pod |
