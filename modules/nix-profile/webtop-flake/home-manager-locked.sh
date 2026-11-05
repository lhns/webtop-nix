# `home-manager` under the apply lock (ADR 0009): one command holds it from evaluation through
# activation. The caller sets WEBTOP_HM_REAL, the real binary, ahead of this text.
# --rollback activates an older generation, whose packages.json may differ: allowed.
for a in "$@"; do
  if [ "$a" = --rollback ]; then export WEBTOP_ACTIVATE_ANY=1; fi
done
# Whatever adds a store path under this lock must not wait for the declaration's, which comes first in
# the lock order: a generation without the packages module's install entry does not mark itself.
export NIX_PROFILE_BACKEND=${NIX_PROFILE_BACKEND:-activation}
if [ -n "${WEBTOP_HM_LOCK_HELD:-}" ]; then exec "$WEBTOP_HM_REAL" "$@"; fi
state=${XDG_STATE_HOME:-$HOME/.local/state}/webtop
mkdir -p "$state"
WEBTOP_HM_LOCK_HELD=1 exec flock -o "$state/home-manager.lock" "$WEBTOP_HM_REAL" "$@"
