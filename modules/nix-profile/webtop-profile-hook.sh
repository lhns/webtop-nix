# profile-hook of the patched `nix profile` (ADR 0006): applies a changed packages.json with
# home-manager. Exits 0 only once it is applied; on failure the previous generation is active again.
# Idempotent and cheap when there is nothing to apply: nix runs it again after a cancel, and for a
# command that changed nothing (ADR 0009).

# Profile changes, home-manager's own install of its generation included: nothing to apply. Must
# stay cheap, it runs for every one of them.
[ "${NIX_PROFILE_BACKEND:-}" = declaration ] || exit 0

# Own session: a cancel's SIGINT to nix's group must not reach an activation. On a cancel nix kills
# only this process, so what it started has to survive without it.
if [ -z "${WEBTOP_HOOK_SESSION:-}" ]; then
  WEBTOP_HOOK_SESSION=1 exec setsid --wait "$0"
fi

state=${XDG_STATE_HOME:-$HOME/.local/state}/webtop
# The apply lock is held by a flock that stays a child of this script, so it outlives a killed
# script and the switch it started; -o keeps the lock out of the switch's own children.
if [ -z "${WEBTOP_HM_LOCK_HELD:-}" ]; then
  mkdir -p "$state"
  rc=0
  WEBTOP_HM_LOCK_HELD=1 flock -o "$state/home-manager.lock" "$0" || rc=$?
  # A signal took the holder or the switch, not a failed activation: once more, and the marker decides.
  if [ "$rc" -gt 128 ]; then
    rc=0
    WEBTOP_HM_LOCK_HELD=1 flock -o "$state/home-manager.lock" "$0" || rc=$?
  fi
  exit "$rc"
fi

gen="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager"
prev=$(readlink -f "$gen" || true)
# What the active generation was built from, and which it was (webtop-flake/packages.nix): nothing to do
# if that is this file and this generation.
hash=$(sha256sum < "$NIX_PROFILE_DECLARATION" | cut -d' ' -f1)
applied_hash=
applied_gen=
if [ -f "$state/applied" ]; then read -r applied_hash applied_gen < "$state/applied" || true; fi
if [ "$applied_hash" = "$hash" ] && [ "$applied_gen" = "$prev" ] && [ -e "$prev/activate" ]; then
  exit 0
fi

dir=$(dirname "$NIX_PROFILE_DECLARATION")
if [ ! -f "$dir/flake.nix" ]; then
  echo "webtop-profile-hook: no flake.nix in $dir: nix profile declares into that directory and switches its flake; keep your flake there" >&2
  exit 1
fi
# A flake in a git repo (its own, or a dotfiles repo around it) sees only files git knows.
if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$dir" check-ignore -q -- "$NIX_PROFILE_DECLARATION"; then
    echo "webtop-profile-hook: git ignores $NIX_PROFILE_DECLARATION, so the flake cannot read it; un-ignore it" >&2
    exit 1
  fi
  git -C "$dir" add --intent-to-add -- "$NIX_PROFILE_DECLARATION"
fi

rc=0
home-manager switch --flake "$dir" || rc=$?
[ "$rc" = 0 ] && exit 0
cur=$(readlink -f "$gen" || true)
if [ -n "$prev" ] && [ "$cur" != "$prev" ]; then
  echo "webtop-profile-hook: re-activating the previous home-manager generation" >&2
  # By hand: an activation that failed before linking leaves home-manager's record at the previous
  # generation, so activating that "changes nothing" and would leave the profile at the failed one.
  nix-env --profile "$gen" --set "$prev" || echo "webtop-profile-hook: pointing the profile at $prev failed" >&2
  WEBTOP_ACTIVATE_ANY=1 "$prev/activate" || echo "webtop-profile-hook: re-activating $prev failed" >&2
fi
exit "$rc"
