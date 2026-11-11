# Brings the user's home-manager setup to the image's (ADR 0006), after
# webtop-home-manager-template.service: relocks the image-registry inputs an image update left
# stale, and switches when that or the template unit changed something, or the active generation
# did not survive the update. WEBTOP_FLAKE, the image's `webtop` flake, is set by the module.

# The apply lock (ADR 0009) for the whole script; flock stays its parent, and -o keeps the lock out of
# anything left running.
if [ -z "${WEBTOP_HM_LOCK_HELD:-}" ]; then
  mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/webtop"
  WEBTOP_HM_LOCK_HELD=1 exec flock -o "${XDG_STATE_HOME:-$HOME/.local/state}/webtop/home-manager.lock" "$0" "$@"
fi

hm=$HOME/.config/home-manager
state=${XDG_STATE_HOME:-$HOME/.local/state}
gen=$state/nix/profiles/home-manager
switch_marker=$state/webtop/home-manager-switch
switch=

# The notifications run in the background; the unit's cgroup ends with this script.
trap wait EXIT
# nixProfile.progress; a no-op by default.
progress() { webtop-restore-progress "$@" || true; }
notify() { webtop-notify "$1" "$2" "${3:-system-software-install}" & }

if [ -e "$switch_marker" ]; then switch=1; fi

# A package change that was declared but not applied (a command killed after writing the file, an OOM
# of the container, a full disk), or a generation that was not finished or never wrote this: the record
# has the packages.json a generation was built from and that generation. Without a record there is
# nothing to compare; the hook's first switch writes one.
if [ -f "$state/webtop/applied" ] && [ -f "$hm/packages.json" ]; then
  applied_hash=
  applied_gen=
  read -r applied_hash applied_gen < "$state/webtop/applied" || true
  if [ "$applied_hash" != "$(sha256sum < "$hm/packages.json" | cut -d' ' -f1)" ] || [ "$applied_gen" != "$(readlink -f "$gen" || true)" ]; then
    switch=1
  fi
fi

# Nix writes flake.lock in place: a full disk or a crash during that leaves it invalid, and every
# switch would fail on it. Set aside, the inputs relock from the registry.
if [ -f "$hm/flake.lock" ] && ! jq -e . "$hm/flake.lock" > /dev/null 2>&1; then
  echo "flake.lock is not valid: moved to flake.lock.bad, relocking"
  mv "$hm/flake.lock" "$hm/flake.lock.bad"
  switch=1
fi

# Root inputs resolved through the image's registry are locked to the old image's store paths;
# relock those that are no longer valid with the locked content (a path that merely exists may not be
# a valid store path, or hold other bytes), and `webtop` whenever it is not the image's current one:
# an old copy can survive in the store overlay and would keep the module behind.
# A path input of the user's own (the admin's `defaults`, a snapshot outside the store) is stale when
# the directory no longer hashes to its narHash, or is gone.
if [ -f "$hm/flake.lock" ]; then
  stale=()
  while IFS=$'\t' read -r name kind id path hash; do
    if [ "$kind" = indirect ]; then
      h=$(nix-store -q --hash "$path" 2>/dev/null) && h=$(nix hash convert --hash-algo sha256 --to sri "$h") || h=
      if [ "$h" != "$hash" ] || { [ "$id" = webtop ] && [ "$path" != "$WEBTOP_FLAKE" ]; }; then stale+=("$name"); fi
    else
      h=$(nix hash path --sri "$path" 2>/dev/null) || h=
      if [ "$h" != "$hash" ]; then stale+=("$name"); fi
    fi
  done < <(jq -r '. as $l | .nodes.root.inputs | to_entries[] | select(.value | type == "string")
                  | .key as $k | $l.nodes[.value]
                  | select(.locked.type == "path" and (.locked.path | startswith("/"))
                           and (.original.type == "indirect" or .original.type == "path"))
                  | [$k, .original.type, (.original.id // "-"), .locked.path, (.locked.narHash // "")] | @tsv' "$hm/flake.lock")
  if [ "${#stale[@]}" -gt 0 ]; then
    echo "relocking stale inputs: ${stale[*]}"
    if nix flake update --flake "$hm" "${stale[@]}"; then switch=1; else echo "relocking failed; flake.lock is as it was"; fi
  fi
fi

# Dangling generation links: an image update did not bring those generations back. None can be
# rolled back to; a dangling current one needs a switch.
old="$state/nix/profiles.old-$(date +%s)"
for l in "$gen" "$gen"-*-link; do
  if [ -L "$l" ] && [ ! -e "$l" ]; then
    mkdir -p "$old" && mv "$l" "$old/"
    if [ "$l" = "$gen" ]; then switch=1; fi
  fi
done

if [ -z "$switch" ] || [ ! -f "$hm/flake.nix" ]; then exit 0; fi
progress current "home-manager switch"
echo "home-manager switch --flake $hm"
# 75: a package change landed during the evaluation (ADR 0009). Its hook now waits for this lock and
# holds the declaration's, so the next attempt sees the final file. Nobody is here to run it again.
for _ in 1 2 3; do
  rc=0
  NIX_CONFIG=$(progress nixconfig) home-manager switch --flake "$hm" || rc=$?
  [ "$rc" = 75 ] || break
done
if [ "$rc" = 0 ]; then
  rm -f "$switch_marker"
  exit 0
fi
echo "home-manager switch failed (exit $rc)"
notify "home-manager switch failed" "See: journalctl -u webtop-home-manager"
exit "$rc"
