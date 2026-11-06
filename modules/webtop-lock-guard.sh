# Runs in the desktop user's manager. A lock (kscreenlocker's org.freedesktop.ScreenSaver
# ActiveChanged, which both `loginctl lock-session` and the D-Bus Lock call end in) is recorded and
# cleared at once through logind: the greeter cannot be unlocked here.
uid=$(id -u)
dir=$XDG_RUNTIME_DIR/webtop
mkdir -p "$dir"

active() {
  [ "$(busctl --user call org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver \
    org.freedesktop.ScreenSaver GetActive 2>/dev/null)" = "b true" ]
}

clear_lock() {
  local s
  for _ in $(seq 1 30); do
    for s in $(loginctl show-user "$uid" -p Sessions --value); do
      loginctl unlock-session "$s" || echo "webtop-lock-guard: unlock-session $s failed"
    done
    sleep 0.3
    active || return 0
  done
  echo "webtop-lock-guard: the lock is still active after 30 tries"
}

# The loop runs in this shell, not a pipeline subshell: when dbus-monitor ends, so does the script,
# and systemd restarts it.
while read -r line; do
  case $line in
    *"boolean true"*)
      date -u +%Y-%m-%dT%H:%M:%SZ >"$dir/lock.new" && mv -T "$dir/lock.new" "$dir/lock"
      echo "webtop-lock-guard: locked, clearing"
      clear_lock
      ;;
  esac
done < <(dbus-monitor --session "type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'")
echo "webtop-lock-guard: dbus-monitor ended"
exit 1
