# Test-script snippet: wait until the session is whole (Plasma's units active, ksmserver owning its bus
# name, no start job left). Needs `ubus` in scope; interpolate it like wait-compositing.nix.
# is-active is read from its output: with several units its exit status is 0 if any one is active.
''
  machine.wait_until_succeeds(
      f"test \"$({ubus} systemctl --user is-active plasma-workspace.target plasma-ksmserver.service plasma-plasmashell.service | sort -u)\" = active"
      f" && {ubus} busctl --user status org.kde.ksmserver >/dev/null"
      f" && test -z \"$({ubus} systemctl --user list-jobs --no-legend)\"",
      timeout=180,
  )''
