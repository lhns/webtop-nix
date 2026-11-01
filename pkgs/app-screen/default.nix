# `webtop-app-screen place <app-id> <screen>` / `release <app-id>`: loads (or unloads) a KWin script
# that keeps an app's windows on a screen, fullscreen. Run as the desktop user inside the session
# (needs DBUS_SESSION_BUS_ADDRESS and XDG_RUNTIME_DIR). See README, "One app per screen".
{ writeShellApplication, systemd, coreutils }:

writeShellApplication {
  name = "webtop-app-screen";
  runtimeInputs = [ systemd coreutils ];
  text = ''
    usage() { echo "usage: webtop-app-screen place <app-id> <screen> | release <app-id>" >&2; exit 2; }
    # Both end up inside a JavaScript string literal and a plugin name.
    valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

    kwin() { busctl --user call org.kde.KWin "$@"; }
    unload() { kwin /Scripting org.kde.kwin.Scripting unloadScript s "webtop-app-screen-$1" >/dev/null; }

    [ $# -ge 2 ] || usage
    cmd=$1 app=$2
    valid "$app" || { echo "invalid app id: $app" >&2; exit 2; }

    case "$cmd" in
      place)
        [ $# -eq 3 ] || usage
        screen=$3
        valid "$screen" || { echo "invalid screen name: $screen" >&2; exit 2; }
        dir="''${XDG_RUNTIME_DIR:?}/webtop-app-screen"
        mkdir -p "$dir"
        script="$dir/$app.js"
        { printf 'const APP_ID = "%s";\nconst SCREEN = "%s";\n' "$app" "$screen"; cat ${./app-screen.js}; } > "$script"
        unload "$app"
        id=$(kwin /Scripting org.kde.kwin.Scripting loadScript ss "$script" "webtop-app-screen-$app" | cut -d' ' -f2)
        [ "$id" -ge 0 ] || { echo "KWin refused the script" >&2; exit 1; }
        kwin "/Scripting/Script$id" org.kde.kwin.Script run
        ;;
      release)
        [ $# -eq 2 ] || usage
        unload "$app"
        ;;
      *) usage ;;
    esac
  '';
}
