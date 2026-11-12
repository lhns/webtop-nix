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

  # The splash only animates a loading screen and costs seconds per session start on this headless
  # desktop. [$i] makes the key immutable, so a user's ~/.config/ksplashrc cannot turn it back on.
  ksplashrc = ''
    [KSplash]
    Engine[$i]=none
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
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.util-linux pkgs.glibc.bin pkgs.getent pkgs.bash config.systemd.package ];
    text = builtins.readFile ./webtop-locale.sh;
  };
  applyLocaleCommand = lib.escapeShellArgs ([
    (lib.getExe applyLocale)
    uid
    "${config.i18n.glibcLocales}/lib/locale/locale-archive"
    (toString cfg.timeZone)
    (toString cfg.locale)
    (lib.concatStringsSep " " cfg.sessionConfKeys)
    defaultsSnapshot
    xdgSessionDir
  ]);

  # The admin's defaults (README, "Time zone and locale", "Admin defaults"): a root-owned snapshot, taken once per boot.
  defaultsSnapshot = "/run/webtop/defaults";
  # The layer of Plasma's config cascade that webtop-locale writes (plasma-localerc); the admin's xdg/ is below it.
  xdgSessionDir = "/run/webtop/xdg-session";
  snapshotDefaults = pkgs.writeShellApplication {
    name = "webtop-defaults";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils config.nix.package ];
    text = builtins.readFile ./webtop-defaults.sh;
  };
  followDefaults = pkgs.writeShellApplication {
    name = "webtop-follow-defaults";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk ];
    text = builtins.readFile ./webtop-follow-defaults.sh;
  };

  # Sleep and the session save (README, "Sleep and session save", ADR 0012).
  power = lib.getExe cfg.sessionSave.command;
  userBus = "unix:path=${runtimeDir}/bus";
  sleepHooks = pkgs.writeText "webtop-sleep-hooks" (lib.concatLines cfg.sleep.hooks);
  sysPower = pkgs.runCommand "webtop-sys-power" { } ''
    mkdir -p $out/bin
    substitute ${./power/webtop-sys-power} $out/bin/webtop-sys-power --subst-var-by busybox ${pkgs.pkgsStatic.busybox}
    chmod +x $out/bin/webtop-sys-power
  '';

  # Lock screen on or off for this start (README, "Lock screen"). Root, before the session starts.
  applyLockConfig = pkgs.writeShellApplication {
    name = "webtop-lock-config";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep ];
    text = builtins.readFile ./webtop-lock-config.sh;
  };
  applyLockConfigCommand = lib.escapeShellArgs ([
    (lib.getExe applyLockConfig)
    (lib.boolToString cfg.lockScreen)
  ] ++ cfg.lockEnvironmentFiles);

  # Clears a lock at once: its greeter cannot be used here. Leaves a marker for whoever fronts the
  # desktop; the time is all it holds.
  lockGuard = pkgs.writeShellApplication {
    name = "webtop-lock-guard";
    runtimeInputs = [ pkgs.coreutils pkgs.dbus config.systemd.package ];
    text = builtins.readFile ./webtop-lock-guard.sh;
  };

  # Shows the files of /run/webtop/notices as notifications (ADR 0019).
  notices = pkgs.writeShellApplication {
    name = "webtop-notices";
    runtimeInputs = [ pkgs.coreutils pkgs.dbus pkgs.gawk pkgs.inotify-tools pkgs.jq config.systemd.package ];
    text = "restart_cmd=${lib.escapeShellArg cfg.notices.restartCommand}
" + builtins.readFile ./webtop-notices.sh;
  };

  # Plasma down as Log Out takes it down, after every end of the session unit. startplasma's own stop
  # on SIGTERM covers only plasma-workspace.target, and Plasma's stops (mode "fail") are refused while
  # start jobs are queued; `systemctl stop` replaces them.
  stopSession = pkgs.writeShellApplication {
    name = "webtop-stop-session";
    runtimeInputs = [ pkgs.coreutils config.systemd.package ];
    text = ''
      # plasma-core.target is not bound to it: after a Log Out with start jobs queued it stays up, and
      # its stop at the next startplasma's daemon-reload races that start.
      systemctl --user stop graphical-session.target plasma-core.target
      # It returns once the target is down, before its PartOf units are; the next startplasma's start
      # (mode "fail") is refused while their stop jobs are queued. A shutdown keeps jobs queued: no wait.
      for _ in $(seq 1 300); do
        [ -z "$(systemctl --user list-jobs --no-legend)" ] && exit 0
        [ "$(systemctl is-system-running || true)" = stopping ] && exit 0
        sleep 0.1
      done
      echo "webtop-stop-session: user jobs still queued after 30 s" >&2
    '';
  };

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
      # The locale applied before this start; systemd's own copy predates it.
      if [ -r /etc/locale.conf ]; then
        set -a
        # shellcheck source=/dev/null
        . /etc/locale.conf
        set +a
      fi
      # Admin defaults for KConfig readers, below the user's files; startplasma prepends
      # ~/.config/kdedefaults. The default list is /etc/xdg when unset. The same dirs are in NixOS's
      # session variables (below), which PAM may already have applied.
      case ":''${XDG_CONFIG_DIRS:-}:" in
        *":${xdgSessionDir}:"*) ;;
        *) export XDG_CONFIG_DIRS="${xdgSessionDir}:${defaultsSnapshot}/xdg:''${XDG_CONFIG_DIRS:-/etc/xdg}" ;;
      esac
      # A user's entry equal to the admin's follows the admin again (ADR 0015).
      ${lib.getExe followDefaults} ${defaultsSnapshot}/xdg "''${XDG_CONFIG_HOME:-''${HOME:-/nonexistent}/.config}" || true
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
      default = "";
      description = ''
        logind seat of the session (XDG_SEAT). Empty for none: the nested KWin uses no
        physical devices, and a seat needs a VT (on seat0 without a VT number logind
        rejects the session).
      '';
    };

    lockScreen = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Show the KDE screen locker's Lock action. Off by default: access is gated by whatever fronts
        Selkies. The greeter renders gray here and cannot be unlocked without a user password, so a
        lock is cleared again right away (`webtop-lock-guard`, ADR 0010) whether this is on or not;
        on, it also leaves `$XDG_RUNTIME_DIR/webtop/lock` (the time) for the environment to act on.
        This is the default for each start: `WEBTOP_LOCK_SCREEN=true|false` in a file of
        `lockEnvironmentFiles` overrides it. Autolock and lock on resume stay off in every case.
      '';
    };

    notices.restartCommand = lib.mkOption {
      type = lib.types.str;
      internal = true;
      default = "busctl --user call org.kde.LogoutPrompt /LogoutPrompt org.kde.LogoutPrompt promptReboot";
      description = "What the `restart` action of a notice runs (ADR 0019): Plasma's Restart, with its confirmation. A test replaces it.";
    };

    lockEnvironmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-/run/webtop/env" ];
      description = ''
        Files (a `-` prefix makes one optional) with a `WEBTOP_LOCK_SCREEN=true|false` line, later
        ones winning; read at each session start, so no rebuild is needed to switch `lockScreen`.
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

    sessionEnvironmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-/run/webtop/session.env" ];
      description = ''
        `EnvironmentFile=` entries of `webtop-session.service`, so Plasma and the apps it starts see
        them (later wins; a `-` prefix makes a file optional).
      '';
    };

    sessionStopCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "+/run/current-system/sw/bin/my-report session-exit" ];
      description = ''
        `ExecStopPost=` lines of `webtop-session.service`, run after each end of the session (Log Out,
        crash, restart, shutdown) once Plasma is stopped. systemd's prefixes apply (`+` as root, `-`
        ignores failure); `$SERVICE_RESULT` and `$EXIT_CODE` tell how it ended.
      '';
    };

    sessionConfKeys = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z]+");
      default = [ ];
      example = [ "myKey" ];
      description = ''
        Keys of the user's `~/.config/webtop/session.conf` that belong to the consumer. The desktop
        skips them; any other unknown key is logged as ignored.
      '';
    };

    sessionSave = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.boot.isContainer;
        defaultText = lib.literalExpression "config.boot.isContainer";
        description = ''
          `webtop-session-save.service`: saves the Plasma session when the system is stopped from
          outside, where Plasma does not (a container stop, SIGRTMIN+3, queues `halt.target`), and
          when Sleep falls back to a poweroff. Stopped before the session, it first thaws what Sleep
          froze, since ksmserver must answer. A shutdown from inside the desktop saves by itself and
          `systemctl poweroff` does not save, as on a real machine. Writes the same
          `ksmserverrc` groups Plasma restores from. On in containers, off otherwise.
        '';
      };

      command = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = pkgs.webtop-power;
        defaultText = lib.literalExpression "pkgs.webtop-power";
        description = ''
          `bin/webtop-power save-session`, as the desktop user with the session bus in its
          environment: saves the session if one of the two conditions above holds. The unit above
          runs it; a consumer can run it for a stop of its own.
        '';
      };
    };

    sleep = {
      mode = lib.mkOption {
        type = lib.types.enum [ "systemd" "freeze" "poweroff" ];
        default = if config.boot.isContainer then "freeze" else "systemd";
        defaultText = lib.literalExpression ''if config.boot.isContainer then "freeze" else "systemd"'';
        description = ''
          What Sleep (`systemd-suspend.service`) does. `"systemd"`: systemd's own suspend. `"freeze"`:
          the session's processes are frozen through the cgroup freezer (`plasma-*` in `session.slice`
          and everything in `app.slice`; Selkies, the session bus and audio keep running), and
          `webtop-power suspend` waits until a new Selkies session connects, then thaws; hibernation
          variants are off. `"poweroff"`, or a freeze that failed: the session is saved, the marker
          `/run/webtop/stop-reason` (containing `suspend`) is written and the system powers off. Logind offers Sleep only
          if `/sys/power/state` is writable: in a container `sleep.init` provides a stand-in.
          `WEBTOP_SUSPEND_MODE=freeze|poweroff` in a file of `sleep.environmentFiles` overrides
          this at each Sleep; it does not turn `"systemd"` into a freeze.
        '';
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "-/run/webtop/env" ];
        description = ''
          `EnvironmentFile=` entries of `systemd-suspend.service`, read at each Sleep (later wins; a
          `-` prefix makes one optional): `WEBTOP_SUSPEND_MODE=freeze|poweroff`, and
          `WEBTOP_HTTP_PORT`, the port of Selkies when it is not `port`.
        '';
      };

      hooks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/run/current-system/sw/bin/my-report" ];
        description = ''
          Commands run as root with one more argument, `asleep` right after a freeze and `awake`
          right after the thaw, in order. Best effort: a failing or slow hook (10 s) is logged and
          skipped. Only `"freeze"` calls them.
        '';
      };

      init = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = ''
          `bin/webtop-sys-power`, a static busybox script for a container's entrypoint (needs `/run`
          mounted, root): binds a writable stand-in over `/sys/power/state` where `/sys` is read-only,
          so logind offers Sleep. Without it a container never offers Sleep. Does nothing elsewhere.
        '';
      };
    };

    timeZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Europe/Berlin";
      description = ''
        Default time zone of the session (an IANA name), for when neither the user's
        `webtop.timeZone` nor the admin's `timeZone` (`defaults.source`) gives a valid one.
        `null` leaves `/etc/localtime` as NixOS has it (`time.timeZone`).
      '';
    };

    locale = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "de_DE.UTF-8";
      description = ''
        Default locale (`LANG`) of the session (one of `locales`), with the same precedence as `timeZone`.
        `null` leaves `i18n.defaultLocale`.
      '';
    };

    locales = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "en_US.UTF-8" "en_GB.UTF-8" "de_DE.UTF-8" "fr_FR.UTF-8" "es_ES.UTF-8" "it_IT.UTF-8" "nl_NL.UTF-8" "pl_PL.UTF-8" "pt_PT.UTF-8" "sv_SE.UTF-8" "C.UTF-8" ];
      description = ''
        Locales built into the image, and so the ones `locale`, `webtop.locale` and the formats can
        select (`sv_SE` is there for ISO dates). Added to `i18n.supportedLocales`; an entry without `/charset` is UTF-8.
      '';
    };

    defaults.source = lib.mkOption {
      type = lib.types.str;
      default = "/etc/webtop/defaults";
      description = ''
        Directory with the admin's defaults for every desktop, read once per boot (a bind mount, a
        ConfigMap or `environment.etc`; it may be missing). `session.conf` gives `timeZone`, `locale`,
        `language` and the `LC_*` formats, `xdg/<file>` KDE/XDG config below the user's own, `home.nix`
        a home-manager module. All are defaults the user can override. Holds no secrets: every user can
        read it. See the README, "Time zone and locale".
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

    sudo.enable = lib.mkEnableOption ''
      sudo for the desktop user, without a password: the user joins `wheel` with an empty password and
      `security.sudo.wheelNeedsPassword` is off. Only where the container is the user's own (a user
      namespace, a personal VM); the desktop is otherwise unprivileged'';

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
      extraGroups = [ "video" "render" "audio" group ] ++ lib.optional cfg.sudo.enable "wheel";
      initialHashedPassword = lib.mkIf cfg.sudo.enable "";
    };
    security.sudo.wheelNeedsPassword = lib.mkIf cfg.sudo.enable false;
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
    system.replaceDependencies.replacements = [{
      oldDependency = pkgs.kdePackages.kguiaddons;
      newDependency = pkgs.kguiaddonsClipboardFix;
    } {
      oldDependency = pkgs.kdePackages.kded;
      newDependency = pkgs.kdedStartupSigterm;
    }] ++ lib.optional cfg.kwinSoftwarePresentation {
      oldDependency = pkgs.kdePackages.kwin;
      newDependency = pkgs.kwinSoftwarePresentation;
    };

    # NixOS otherwise points localed at the read-only /etc/static/locale.conf and sets LANG for every login
    # shell (set-environment), both ahead of what webtop-locale writes to /etc/locale.conf.
    i18n.imperativeLocale = lib.mkDefault true;
    i18n.extraLocales = map (l: if lib.hasInfix "/" l then l else "${l}/UTF-8") cfg.locales;

    # NixOS's set-environment (/etc/profile, /etc/bashrc) rebuilds XDG_CONFIG_DIRS from this list, so a
    # terminal's shell would drop the admin layers the session wrapper set; they go in front of /etc/xdg here too.
    environment.sessionVariables.XDG_CONFIG_DIRS = lib.mkBefore [ xdgSessionDir "${defaultsSnapshot}/xdg" ];

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
        # No SELKIES_SUBFOLDER: a reverse proxy strips a path prefix before it reaches us and the web client
        # derives it from the page URL; setting it would make Selkies expect it on every route.
        SELKIES_ENABLE_CLIPBOARD = cfg.clipboard;
        SELKIES_FILE_TRANSFERS = if cfg.fileTransfers == [ ] then "none" else lib.concatStringsSep "," cfg.fileTransfers;
        SELKIES_FILE_MANAGER_PATH = cfg.fileManagerPath;
      } // lib.optionalAttrs (cfg.uploadPath != null) {
        SELKIES_UPLOAD_PATH = cfg.uploadPath;
      } // {
        SELKIES_USE_BROWSER_CURSORS = lib.boolToString cfg.browserCursors;
        # Cursors for Qt apps and pixelflux's own cursor.
        XCURSOR_THEME = "breeze_cursors";
        XCURSOR_SIZE = "24";
        # 30 fps: software x264 on shared CPUs keeps up; the client may still raise it.
        SELKIES_FRAMERATE = "30,8-240";
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

    systemd.user.services.webtop-lock-guard = {
      description = "Clear the screen lock at once (its greeter is unusable)";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = uid;
      environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=%t/bus";
      serviceConfig = {
        ExecStart = lib.getExe lockGuard;
        Restart = "always";
        RestartSec = 2;
      };
    };

    # Notices (ADR 0019): root writes files, this shows them. Not for the user to write: /run/webtop/notices is root's.
    systemd.user.services.webtop-notices = {
      description = "Show the files of /run/webtop/notices as notifications";
      wantedBy = [ "plasma-workspace.target" ];
      partOf = [ "plasma-workspace.target" ];
      after = [ "plasma-plasmashell.service" ];
      unitConfig.ConditionUser = uid;
      environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=%t/bus";
      serviceConfig = {
        ExecStart = lib.getExe notices;
        Restart = "always";
        RestartSec = 2;
      };
    };

    # With no crashes to hand off, this unit only watches the journal, and its 30-minute runtime limit
    # then counts as a failure: the session would report degraded half an hour after login.
    systemd.user.services.drkonqi-coredump-pickup = {
      overrideStrategy = "asDropin";
      serviceConfig.RuntimeMaxSec = "infinity";
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

    # Once per boot (a restart takes a new snapshot). The session starts without it if it fails.
    systemd.services.webtop-defaults = {
      description = "Snapshot of the admin's desktop defaults";
      wantedBy = [ "multi-user.target" ];
      before = [ "webtop-session.service" "webtop-home-manager-template.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${lib.getExe snapshotDefaults} ${lib.escapeShellArg cfg.defaults.source} ${defaultsSnapshot}";
      };
    };

    systemd.services.webtop-session = {
      description = "Plasma Wayland session nested in Selkies";
      wantedBy = [ "multi-user.target" ];
      wants = [ "webtop-defaults.service" ];
      requires = [ "user@${uid}.service" ];
      after = [ "webtop-defaults.service" "user@${uid}.service" "systemd-logind.service" "systemd-user-sessions.service" ];
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
        ExecStartPre = [ "-+${applyLocaleCommand}" "-+${applyLockConfigCommand}" ];
        User = uid;
        PAMName = "login";
        StandardInput = "null";
        ExecStart = lib.getExe startSession;
        # Else KWin, ksmserver and plasmashell outlive the unit, bound to its removed logind session.
        # Post, not ExecStop: that is skipped when startplasma dies of a signal.
        ExecStopPost = [ "-${lib.getExe stopSession}" ] ++ cfg.sessionStopCommands;
        EnvironmentFile = cfg.sessionEnvironmentFiles;
        # "always": Log Out exits 0 and there is no greeter, so it must come back.
        Restart = "always";
        RestartSec = 2;
      };
      # Many logouts are fine; a crash loop (>= 2 s per cycle) hits the burst within a minute and stops.
      startLimitIntervalSec = 300;
      startLimitBurst = 20;
    };

    services.webtop.sleep.init = sysPower;

    # webtop-power's state (the frozen units, the poweroff marker) and the consumers' env files.
    systemd.tmpfiles.rules = [ "d /run/webtop 0755 root root -" "d /run/webtop/notices 0755 root root -" ];

    # Saves the Plasma session on an external stop, where ksmserver does not. Stopped before the
    # session and the user manager (plasma-ksmserver.service runs there). The thaw first ("+": as
    # root) is a no-op unless Sleep left units frozen, which would hang ksmserver.
    systemd.services.webtop-session-save = lib.mkIf cfg.sessionSave.enable {
      description = "Save the Plasma session before an external stop";
      wantedBy = [ "multi-user.target" ];
      after = [ "webtop-session.service" "user@${uid}.service" ];
      environment = {
        DBUS_SESSION_BUS_ADDRESS = userBus;
        XDG_RUNTIME_DIR = runtimeDir;
        WEBTOP_UID = uid;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = uid;
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = [ "+${power} thaw" "${power} save-session" ];
        TimeoutStopSec = 40;
      };
    };

    # Sleep (ADR 0012). webtop-power blocks until the next web client, so no start timeout. After=
    # webtop-session-save stops this first, so it thaws before ksmserver is asked to save.
    systemd.services.systemd-suspend = lib.mkIf (cfg.sleep.mode != "systemd") {
      path = [ config.systemd.package ];
      after = [ "webtop-session-save.service" ];
      environment = {
        WEBTOP_SUSPEND_MODE = cfg.sleep.mode;
        WEBTOP_HTTP_PORT = toString cfg.port;
        WEBTOP_UID = uid;
        WEBTOP_SLEEP_HOOKS = toString sleepHooks;
      };
      serviceConfig = {
        ExecStart = [ "" "${power} suspend" ];
        EnvironmentFile = cfg.sleep.environmentFiles;
        TimeoutStartSec = "infinity";
      };
    };
    systemd.sleep.settings.Sleep = lib.mkIf (cfg.sleep.mode != "systemd") {
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
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
    environment.etc."xdg/ksplashrc".text = ksplashrc;

    # /etc/xdg/kdeglobals and kscreenlockerrc are written at each session start (webtop-lock-config).
    # Autolock would start the (unusable) greeter before anyone connects, so it is off in every case.

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
