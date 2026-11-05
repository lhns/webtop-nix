# A browser-streamed Plasma 6 desktop: Selkies (pixelflux compositor + pcmflux audio)
# hosts a Wayland socket, KWin nests in it, the Plasma session runs under real logind.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.webtop;
  uid = toString cfg.uid;
  group = "webtop";
  runtimeDir = "/run/user/${uid}";
  # Selkies' compositor; KWin then takes the default wayland-0 for itself.
  selkiesSocket = "wayland-${toString cfg.waylandSocketIndex}";
  # Sink Selkies streams the monitor of; apps play to it as the default sink.
  sinkName = "output";

  # The image's apps for the software center's "Included with desktop". Pointed at by a literal path
  # in the session environment, so nothing the packages depend on references it.
  manifestPath = "/etc/nsc/system-manifest.json";
  systemManifest = builtins.toJSON {
    version = 1;
    packages = map (p: {
      pname = lib.getName p;
      version = lib.getVersion p;
      path = builtins.unsafeDiscardStringContext (toString p);
    }) (lib.filter (p: lib.isDerivation p && (p ? pname || p ? name)) config.environment.systemPackages);
  };

  powerdevilrc = ''
    [AC][SuspendAndShutdown]
    AutoSuspendAction=0

    [Battery][SuspendAndShutdown]
    AutoSuspendAction=0

    [LowBattery][SuspendAndShutdown]
    AutoSuspendAction=0
  '';

  # "Restore previous session" in System Settings > Startup and Shutdown.
  ksmserverrc = ''
    [General]
    loginMode=restorePreviousLogout
  '';

  # Start wrapper of Selkies: resolves the upload directory and applies the user's allowlisted
  # settings last, so they win over the unit environment and any EnvironmentFile.
  selkiesStart = pkgs.writeShellApplication {
    name = "webtop-selkies";
    runtimeInputs = [ pkgs.coreutils pkgs.xdg-user-dirs ];
    text = ''
      # Per-user settings: only allowlisted KEY=VALUE lines of a plain file of bounded size.
      allowed=" ${lib.concatStringsSep " " cfg.userSettings} "
      conf="''${XDG_CONFIG_HOME:-$HOME/.config}/webtop/selkies.env"
      if [ -f "$conf" ] && [ ! -L "$conf" ] && [ "$(stat -c %s "$conf")" -le 65536 ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in ""|"#"*) continue ;; esac
          key="''${line%%=*}"
          if [ "$key" != "$line" ] && [[ "$key" =~ ^SELKIES_[A-Z0-9_]+$ ]] && [[ "$allowed" == *" $key "* ]]; then
            val="''${line#*=}"
            case "$val" in
              \"*\"|\'*\') val="''${val:1:''${#val}-2}" ;;
            esac
            export "$key=$val"
          else
            echo "webtop: ignoring $conf line for ''${key:0:64}: not an allowed setting" >&2
          fi
        done < "$conf"
      elif [ -e "$conf" ] || [ -L "$conf" ]; then
        echo "webtop: ignoring $conf: not a regular file or over 64 KiB" >&2
      fi

      ${lib.optionalString (cfg.uploadPath == null) ''
      # The user's XDG download directory as of now; $HOME itself means "unset".
      if [ -z "''${SELKIES_UPLOAD_PATH:-}" ]; then
        dl="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
        if [ -z "$dl" ] || [ "$dl" = "$HOME" ]; then dl="$HOME/Downloads"; fi
        export SELKIES_UPLOAD_PATH="$dl"
        mkdir -p "$dl"
      fi
      ''}
      exec ${lib.getExe cfg.package}
    '';
  };

  # Session time zone and locale (README, "Time zone and locale"). Root, before the session starts.
  applyLocale = pkgs.writeShellApplication {
    name = "webtop-locale";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.util-linux pkgs.glibc.bin pkgs.bash ];
    text = builtins.readFile ./webtop-locale.sh;
  };
  applyLocaleCommand = lib.escapeShellArgs ([
    (lib.getExe applyLocale)
    uid
    "${config.i18n.glibcLocales}/lib/locale/locale-archive"
    (toString cfg.timeZone)
    (toString cfg.locale)
  ] ++ cfg.localeEnvironmentFiles);

  startSession = pkgs.writeShellApplication {
    name = "webtop-start-session";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux ];
    text = ''
      # Live = socket present and its .lock held by the compositor; a socket left over from a
      # previous run (kept /run/user) would otherwise pass and KWin could take the name itself.
      sock="${runtimeDir}/${selkiesSocket}"
      for _ in $(seq 1 600); do
        [ -S "$sock" ] && [ -e "$sock.lock" ] && ! flock -n "$sock.lock" true && break
        sleep 0.1
      done
      # The locale applied before this start (LANG only); systemd's own copy predates it.
      if [ -r /etc/locale.conf ]; then
        set -a
        # shellcheck source=/dev/null
        . /etc/locale.conf
        set +a
      fi
      exec ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland
    '';
  };
in
{
  options.services.webtop = {
    enable = lib.mkEnableOption "a browser-streamed Plasma desktop (Selkies)";

    user = lib.mkOption {
      type = lib.types.str;
      default = "user";
      description = ''
        Account the desktop runs as. Only its declaration uses the name; see ADR 0003 (amendment)
        for renaming it at runtime.
      '';
    };

    softwareCenter.enable = lib.mkEnableOption "the Nix Software Center, a GUI over `nix profile`";

    uid = lib.mkOption {
      type = lib.types.int;
      default = 1000;
      description = "UID of the desktop user (fixes /run/user/<uid>).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "TCP port Selkies serves the web client on.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address Selkies listens on. Its own authentication is disabled, so anything
        exposing it beyond loopback needs an authenticating proxy in front. Deployments
        set this explicitly.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the Selkies port in the firewall.";
    };

    softwareRendering = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        For hosts without a GPU: Mesa goes straight to llvmpipe (LIBGL_ALWAYS_SOFTWARE) instead
        of trying zink/dri2 first. KWin 6.8 also needs `kwinSoftwarePresentation`.
      '';
    };

    kwinSoftwarePresentation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Replace KWin by a build with LinuxServer's software-presentation patch, without rebuilding
        its dependents. Needed on GPU-less hosts (pods) with Plasma 6.8 or later: KWin 6.8 has no
        QPainter compositing, and nested under Selkies' CPU-only compositor it finds no render
        device ("requires compositing", gray screen). With a GPU the patch changes nothing.
        The same build carries the KWin patch Selkies' second display needs, so turning this off
        also loses that. The patch targets KWin 6.8.x; on Plasma 6.7 set this to false.
      '';
    };

    seat = lib.mkOption {
      type = lib.types.str;
      default = if config.boot.isContainer then "" else "seat0";
      defaultText = lib.literalExpression ''if config.boot.isContainer then "" else "seat0"'';
      description = ''
        logind seat of the session (XDG_SEAT). Empty for none: seat0 has no VTs in a
        container, so logind rejects a session on it.
      '';
    };

    lockScreen = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow the KDE screen locker. Off by default: access is gated by whatever fronts Selkies,
        and the locker greeter renders gray here and cannot be unlocked without a user password.
      '';
    };

    waylandSocketIndex = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1;
      description = ''
        Selkies' compositor socket is `wayland-<index>`, which the session waits for and
        nests in. Keep it above 0: KWin's own socket is auto-picked from wayland-0 up.
      '';
    };

    clipboard = lib.mkOption {
      type = lib.types.enum [ "true" "in" "out" "false" ];
      default = "true";
      description = ''
        Clipboard direction (SELKIES_ENABLE_CLIPBOARD): `"true"` both ways, `"in"` browser to
        desktop only, `"out"` desktop to browser only, `"false"` off.
      '';
    };

    fileTransfers = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "upload" "download" ]);
      default = [ "upload" "download" ];
      description = "Allowed file transfer directions (SELKIES_FILE_TRANSFERS); empty disables transfers.";
    };

    fileManagerPath = lib.mkOption {
      type = lib.types.str;
      default = "~";
      description = "Directory downloads are served from, the whole home by default (SELKIES_FILE_MANAGER_PATH); created at start. Uploads go to `uploadPath`.";
    };

    uploadPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "~/Inbox";
      description = ''
        Directory uploads land in (SELKIES_UPLOAD_PATH, a Selkies patch); created at start. `null`
        is the user's XDG download directory (`xdg-user-dir DOWNLOAD`, so `~/.config/user-dirs.dirs`
        and localized names count), resolved at each service start; `$HOME/Downloads` when that is
        unset. A value is used as is (`~` and absolute paths work).
      '';
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-/run/webtop/selkies.env" ];
      description = ''
        `EnvironmentFile=` entries of the Selkies unit, read in order after the module's own
        environment, so they override it (later wins; a `-` prefix makes a file optional).
      '';
    };

    timeZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Europe/Berlin";
      description = ''
        Default time zone of the session (an IANA name), for when neither the user's
        `webtop.timeZone` nor an environment file (`localeEnvironmentFiles`) gives a valid one.
        `null` leaves `/etc/localtime` as NixOS has it (`time.timeZone`).
      '';
    };

    locale = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "de_DE.UTF-8";
      description = ''
        Default locale of the session (one of `locales`), with the same precedence as `timeZone`.
        `null` leaves `i18n.defaultLocale`.
      '';
    };

    locales = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "en_US.UTF-8" "en_GB.UTF-8" "de_DE.UTF-8" "fr_FR.UTF-8" "es_ES.UTF-8" "it_IT.UTF-8" "nl_NL.UTF-8" "pl_PL.UTF-8" "pt_PT.UTF-8" "C.UTF-8" ];
      description = ''
        Locales built into the image, and so the ones `locale` and a user's `webtop.locale` can
        select. Added to `i18n.supportedLocales`; an entry without `/charset` is UTF-8.
      '';
    };

    localeEnvironmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-/run/webtop/env" ];
      description = ''
        Files (a `-` prefix makes one optional) with `WEBTOP_TIME_ZONE=` and `WEBTOP_LOCALE=` lines,
        later ones winning. Their values rank between the user's and `timeZone` / `locale`.
      '';
    };

    userSettings = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "SELKIES_ENCODER" "SELKIES_FRAMERATE" "SELKIES_VIDEO_BITRATE" "SELKIES_VIDEO_CRF"
        "SELKIES_JPEG_QUALITY" "SELKIES_RATE_CONTROL_MODE" "SELKIES_KEYFRAME_INTERVAL"
        "SELKIES_VIDEO_MIN_QP" "SELKIES_VIDEO_MAX_QP" "SELKIES_VIDEO_FULLCOLOR"
        "SELKIES_USE_PAINT_OVER_QUALITY" "SELKIES_PAINT_OVER_JPEG_QUALITY" "SELKIES_VIDEO_PAINTOVER_CRF"
        "SELKIES_AUDIO_BITRATE" "SELKIES_SCALING_DPI" "SELKIES_USE_BROWSER_CURSORS"
        "SELKIES_USE_CSS_SCALING" "SELKIES_RAW_POINTER_MOTION"
      ];
      description = ''
        Selkies settings the user may override in `~/.config/webtop/selkies.env` (`KEY=VALUE`
        lines), applied after everything else. Only the user's own stream quality and input feel;
        keep auth, transfers, paths, ports, clipboard and audit out.
      '';
    };

    browserCursors = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Draw the cursor in the browser (CSS cursors) instead of into the video (SELKIES_USE_BROWSER_CURSORS).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.selkies;
      defaultText = lib.literalExpression "pkgs.selkies";
      description = "The Selkies package (from this flake's overlay).";
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { SELKIES_ENCODER = "x264enc"; };
      description = "Extra environment for the Selkies user service (e.g. SELKIES_* settings).";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [ (import ../overlay.nix) ];

    users.users.${cfg.user} = {
      isNormalUser = true;
      uid = cfg.uid;
      extraGroups = [ "video" "render" "audio" group ];
    };
    users.groups.${group} = { };

    services.desktopManager.plasma6.enable = true;

    services.displayManager.enable = lib.mkForce false;

    # Optional parts a streamed desktop rarely uses, about 2 GiB of closure (README, "Left out").
    # Priority 900 beats plasma6's mkDefault and loses to any plain definition, so a deployment
    # turns each back on with an ordinary `= true`.
    programs.kde-pim.enable = lib.mkOverride 900 false; # akonadi, mariadb, kmail
    services.orca.enable = lib.mkOverride 900 false; # also speech-dispatcher and its voices
    services.fwupd.enable = lib.mkOverride 900 false; # and with it discover
    services.geoclue2.enable = lib.mkOverride 900 false;
    services.desktopManager.plasma6.enableQt5Integration = lib.mkOverride 900 false; # the KF5 stack
    documentation.doc.enable = lib.mkOverride 900 false;
    environment.plasma6.excludePackages = with pkgs.kdePackages; [ plasma-workspace-wallpapers elisa khelpcenter krdp ];

    # A graft: the rewritten system keeps plasma-workspace and the rest as built by nixpkgs. Note that
    # evaluating the system builds the stock one first (replaceDependencies reads its references).
    system.replaceDependencies.replacements = lib.mkIf cfg.kwinSoftwarePresentation [{
      oldDependency = pkgs.kdePackages.kwin;
      newDependency = pkgs.kwinSoftwarePresentation;
    }];

    i18n.extraLocales = map (l: if lib.hasInfix "/" l then l else "${l}/UTF-8") cfg.locales;

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    hardware.graphics.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
    security.rtkit.enable = lib.mkDefault true;
    services.pipewire = {
      enable = lib.mkDefault true;
      alsa.enable = lib.mkDefault true;
      pulse.enable = lib.mkDefault true;
    };

    # A pod or VM has no sound card: a virtual default sink for apps, whose monitor Selkies streams.
    services.pipewire.extraConfig.pipewire."90-webtop-output"."context.objects" = [{
      factory = "adapter";
      args = {
        "factory.name" = "support.null-audio-sink";
        "node.name" = sinkName;
        "node.description" = "Browser audio";
        "media.class" = "Audio/Sink";
        "audio.position" = "FL,FR";
        "priority.session" = 2000;
      };
    }];

    systemd.user.services.selkies = {
      description = "Selkies streaming server (pixelflux compositor, pcmflux audio)";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = uid;
      path = [ pkgs.wl-clipboard pkgs.pulseaudio ];
      environment = {
        SELKIES_WAYLAND = "true";
        # pixelflux auto-picks the first free wayland-N from the index up; see startSession.
        SELKIES_WAYLAND_SOCKET_INDEX = toString cfg.waylandSocketIndex;
        # The monitor of the null sink defined above.
        SELKIES_AUDIO_DEVICE_NAME = "${sinkName}.monitor";
        # pixelflux's cursor loader reads only XCURSOR_PATH (else a placeholder cursor).
        XCURSOR_PATH = "/run/current-system/sw/share/icons:/run/current-system/sw/share/pixmaps";
        SELKIES_ADDR = cfg.address;
        SELKIES_PORT = toString cfg.port;
        # Authentication is the job of whatever fronts this port.
        SELKIES_ENABLE_BASIC_AUTH = "false";
        # No SELKIES_SUBFOLDER: a gateway prefix is stripped before it reaches us and the web client
        # derives it from the page URL; setting it would make Selkies expect it on every route.
        SELKIES_ENABLE_CLIPBOARD = cfg.clipboard;
        SELKIES_FILE_TRANSFERS = if cfg.fileTransfers == [ ] then "none" else lib.concatStringsSep "," cfg.fileTransfers;
        SELKIES_FILE_MANAGER_PATH = cfg.fileManagerPath;
      } // lib.optionalAttrs (cfg.uploadPath != null) {
        SELKIES_UPLOAD_PATH = cfg.uploadPath;
      } // {
        SELKIES_USE_BROWSER_CURSORS = lib.boolToString cfg.browserCursors;
      } // cfg.extraEnvironment;
      serviceConfig = {
        # A stale socket would make pixelflux auto-pick a later name than the session waits for.
        # Only our own: KWin's live socket sits next to it.
        ExecStartPre = "${pkgs.runtimeShell} -c 'rm -f ${runtimeDir}/${selkiesSocket} ${runtimeDir}/${selkiesSocket}.lock'";
        ExecStart = lib.getExe selkiesStart;
        EnvironmentFile = cfg.environmentFiles;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # Lingering, so the user manager (and selkies) outlives a restart of the session. By uid:
    # `users.users.<name>.linger` would enable it by name at every boot.
    systemd.services.webtop-linger = {
      description = "Let the desktop user linger";
      wantedBy = [ "multi-user.target" ];
      requires = [ "systemd-logind.service" ];
      after = [ "systemd-logind.service" ];
      before = [ "webtop-session.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${config.systemd.package}/bin/loginctl enable-linger ${uid}";
      };
    };

    systemd.services.webtop-session = {
      description = "Plasma Wayland session nested in Selkies";
      wantedBy = [ "multi-user.target" ];
      requires = [ "user@${uid}.service" ];
      after = [ "user@${uid}.service" "systemd-logind.service" "systemd-user-sessions.service" ];
      environment = {
        XDG_SESSION_TYPE = "wayland";
        XDG_SESSION_CLASS = "user";
        XDG_SEAT = cfg.seat;
        XDG_RUNTIME_DIR = runtimeDir;
        # pam_systemd does not always export it; without it startplasma fails with "Could not start D-Bus".
        DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtimeDir}/bus";
        WAYLAND_DISPLAY = selkiesSocket;
        XDG_CURRENT_DESKTOP = "KDE";
        KDE_FULL_SESSION = "true";
        KDE_SESSION_VERSION = "6";
        QT_QPA_PLATFORM = "wayland";
        MOZ_ENABLE_WAYLAND = "1";
      } // lib.optionalAttrs cfg.softwareRendering {
        LIBGL_ALWAYS_SOFTWARE = "1";
      } // lib.optionalAttrs cfg.softwareCenter.enable {
        NSC_SYSTEM_MANIFEST = manifestPath;
      };
      serviceConfig = {
        # "-": a failure never blocks the session; "+": root, whatever User= says.
        ExecStartPre = "-+${applyLocaleCommand}";
        User = uid;
        PAMName = "login";
        StandardInput = "null";
        ExecStart = lib.getExe startSession;
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # Power actions from inside the desktop, as on a real machine.
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (subject.isInGroup("${group}") && [
          "org.freedesktop.login1.power-off",
          "org.freedesktop.login1.power-off-multiple-sessions",
          "org.freedesktop.login1.reboot",
          "org.freedesktop.login1.reboot-multiple-sessions",
          "org.freedesktop.login1.suspend",
          "org.freedesktop.login1.suspend-multiple-sessions"
        ].indexOf(action.id) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';

    # System-wide defaults; a user's own ~/.config overrides them.
    environment.etc."xdg/powerdevilrc".text = powerdevilrc;
    environment.etc."xdg/ksmserverrc".text = ksmserverrc;

    # Autolock would start the (unusable) greeter before anyone connects; also block manual locking.
    environment.etc."xdg/kscreenlockerrc" = lib.mkIf (!cfg.lockScreen) {
      text = ''
        [Daemon]
        Autolock=false
        LockOnResume=false
      '';
    };
    environment.etc."xdg/kdeglobals" = lib.mkIf (!cfg.lockScreen) {
      text = ''
        [KDE Action Restrictions]
        action/lock_screen=false
      '';
    };

    fonts.packages = with pkgs; [ noto-fonts noto-fonts-color-emoji noto-fonts-cjk-sans liberation_ttf ];
    programs.firefox.enable = lib.mkDefault true;
    # Nix's default search path names a channels directory NixOS without channels lacks, and warns on every
    # impure evaluation. The registry's nixpkgs also keeps `<nixpkgs>` and `nix-shell -p` working.
    nix.settings.nix-path = lib.mkDefault "nixpkgs=flake:nixpkgs";

    environment.systemPackages = [ cfg.package pkgs.webtop-app-screen ]
      ++ lib.optional cfg.softwareCenter.enable pkgs.nix-software-center;
    # nix-data's fallback when the user has no config: all fields unset, so no welcome dialog.
    environment.etc."nix-data/config.json" = lib.mkIf cfg.softwareCenter.enable { text = "{}"; };
    # Read-only; the software center reads it at startup, so an image update changes it.
    environment.etc."nsc/system-manifest.json" = lib.mkIf cfg.softwareCenter.enable { text = systemManifest; };
  };
}
