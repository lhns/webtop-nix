# `webtop-app-screen place <app-id> <screen>` / `release <app-id>` / `focus <screen>|main` / `screens`:
# loads (or unloads) KWin scripts that keep an app's windows on a screen, fullscreen; `release` also sends
# them back. Run as the desktop user inside the session (needs DBUS_SESSION_BUS_ADDRESS and
# XDG_RUNTIME_DIR). See README, "One app per screen".
{ writeShellApplication, systemd, coreutils, diffutils, gnugrep }:

writeShellApplication {
  name = "webtop-app-screen";
  runtimeInputs = [ systemd coreutils diffutils gnugrep ];
  text = ''
    usage() {
      echo "usage: webtop-app-screen place <app-id> <screen> | release <app-id> | focus <screen>|main | screens" >&2
      exit 2
    }
    # Both end up inside a JavaScript string literal and a plugin name.
    valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

    kwin() { busctl --user call org.kde.KWin "$@"; }
    unload() { kwin /Scripting org.kde.kwin.Scripting unloadScript s "$1" >/dev/null; }
    # script file, script name: replaces a script of that name and runs it.
    start() {
      unload "$2"
      id=$(kwin /Scripting org.kde.kwin.Scripting loadScript ss "$1" "$2" | cut -d' ' -f2)
      [ "$id" -ge 0 ] || { echo "KWin refused the script" >&2; exit 1; }
      kwin "/Scripting/Script$id" org.kde.kwin.Script run
    }
    # output file, app id, screen, script: writes the script with its header.
    write() {
      { printf 'const APP_ID = "%s";\nconst SCREEN = "%s";\n' "$2" "$3"; cat ${./common.js} "$4"; } > "$1"
    }

    [ $# -ge 1 ] || usage
    cmd=$1
    dir="''${XDG_RUNTIME_DIR:?}/webtop-app-screen"
    mkdir -p "$dir"

    case "$cmd" in
      place)
        [ $# -eq 3 ] || usage
        app=$2 screen=$3
        valid "$app" || { echo "invalid app id: $app" >&2; exit 2; }
        valid "$screen" || { echo "invalid screen name: $screen" >&2; exit 2; }
        name="webtop-app-screen-$app"
        script="$dir/$app.js"
        write "$script.new" "$app" "$screen" ${./app-screen.js}
        # Already running for this screen: replacing it would lose the windows' prior state.
        if cmp -s "$script.new" "$script" \
          && [ "$(kwin /Scripting org.kde.kwin.Scripting isScriptLoaded s "$name")" = "b true" ]; then
          rm -f "$script.new"
          exit 0
        fi
        mv "$script.new" "$script"
        start "$script" "$name"
        ;;
      release)
        [ $# -eq 2 ] || usage
        app=$2
        valid "$app" || { echo "invalid app id: $app" >&2; exit 2; }
        unload "webtop-app-screen-$app"
        script="$dir/release-$app.js"
        write "$script" "$app" "" ${./release.js}
        name="webtop-app-screen-release-$app"
        start "$script" "$name"
        sleep 1
        unload "$name"
        ;;
      focus)
        [ $# -eq 2 ] || usage
        valid "$2" || { echo "invalid screen name: $2" >&2; exit 2; }
        script="$dir/focus.js"
        write "$script" "" "$2" ${./focus.js}
        start "$script" webtop-app-screen-focus
        ;;
      screens)
        [ $# -eq 1 ] || usage
        # KWin's report is the one answer D-Bus gives; no Wayland connection needed.
        kwin /KWin org.kde.KWin supportInformation | grep -oE 'Name: SELKIES-[0-9]+' | cut -d' ' -f2 | sort -u || true
        ;;
      *) usage ;;
    esac
  '';
}
