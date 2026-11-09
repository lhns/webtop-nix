# Test-script snippet: wait until KWin in the user session is compositing. Interpolate it at the
# start of a line, with no newline after it; continuation lines sit inside the parentheses.
''
  machine.wait_until_succeeds(
      "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
      "busctl --user get-property org.kde.KWin /Compositor org.kde.kwin.Compositing active | grep -qx 'b true'",
      timeout=180,
  )''
