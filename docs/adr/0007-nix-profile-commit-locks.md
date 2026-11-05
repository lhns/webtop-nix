# 0007 — `nix profile` commits serialize themselves, in one lock order

- Status: Accepted
- Date: 2026-11-04

## Context

Commands that change what is installed run from a terminal, the software center and activations, in any
mix. A lock taken before the build removes all parallelism and makes the next command wait for it; no lock
at all loses updates, because each command writes back the state it read when it started. The layer doing
the commit is the only one every path goes through.

## Decision

- A command evaluates and builds with no lock. Its commit takes the lock, reads the current state,
  re-applies only that command's change, and records the result.
- A remove or upgrade whose target has gone is a no-op, not an error. A change that alters nothing records
  nothing and runs no hook.
- Locks, always taken in this order; nothing waits for an earlier lock while holding a later one:

| Lock | File | Covers |
|---|---|---|
| `L_D` | `profiles/declaration.lock` | a command that changes the declaration: its profile commit, re-reading `packages.json`, the atomic rename, the hook |
| `L_A` | taken from a later step on | evaluation through activation of home-manager |
| `L_P` | `profiles/<profile>.lock` | re-reading the manifest, the change, the new generation; released before the hook |

- `L_P` is never held across a hook, because an activation inside the hook needs it.
- Adding a store path takes only `L_P`, not `L_D`: activations add store paths and will hold `L_A`. It reads
  the declaration unlocked, which is safe because the file is replaced atomically.
- Undo is a commit of its own under the lock: each name goes back only if it is still what the undone commit
  made it. Stepping back a generation or restoring a whole file would drop other commands' commits. A
  declaration's own hook failure restores the file, because `L_D` is still held.

## Consequences

- Formats and lock files are unchanged, so old and new Nix can share them. Nix without this patch still does
  not take these locks around its whole change.
- Undoing a profile commit adds a generation instead of removing one.
- A store path added at the moment its name is being declared can end up in both the profile and the
  declaration: the check under `L_P` can fall between the declaration command's profile commit and its
  rename. Different contents fail that command's switch, which reverts it; identical contents are harmless,
  and a remove clears both. This is accepted: closing it needs `L_D` around store-path adds from outside a
  hook, which makes them wait for a running switch, and they cannot be told apart from the add of a terminal
  `home-manager switch`, which will hold `L_A`, without marking that activation.

## Amendment 2026-11-05

`L_A` is defined by [ADR 0009](0009-one-apply-lock-and-an-applied-marker.md). Store-path adds now take `L_D`
unless a hook or an activation runs them, which closes the window above.
