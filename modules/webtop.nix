# A browser-streamed Plasma 6 desktop: Selkies (pixelflux compositor + pcmflux audio)
# hosts a Wayland socket, KWin nests in it, the Plasma session runs under real logind.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.webtop;
  uid = toString cfg.uid;
  runtimeDir = "/run/user/${uid}";
  # Selkies' compositor; KWin then takes the default wayland-0 for itself.
  selkiesSocket = "wayland-${toString cfg.waylandSocketIndex}";
  # Sink Selkies streams the monitor of; apps play to it as the default sink.
  sinkName = "output";

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
      description = "Account the desktop runs as.";
    };

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
        The patch targets KWin 6.8.x; on Plasma 6.7 set this to false.
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
      default = "~/Desktop";
      description = "Directory uploads land in and downloads are served from (SELKIES_FILE_MANAGER_PATH); created at start.";
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
      # User manager at boot, so selkies is up before the Plasma session starts.
      linger = true;
      extraGroups = [ "video" "render" "audio" ];
    };

    services.desktopManager.plasma6.enable = true;

    services.displayManager.enable = lib.mkForce false;

    # A graft: the rewritten system keeps plasma-workspace and the rest as built by nixpkgs. Note that
    # evaluating the system builds the stock one first (replaceDependencies reads its references).
    system.replaceDependencies.replacements = lib.mkIf cfg.kwinSoftwarePresentation [{
      oldDependency = pkgs.kdePackages.kwin;
      newDependency = pkgs.kwinSoftwarePresentation;
    }];

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

    systemd.tmpfiles.rules = [ "d /tmp/.X11-unix 1777 root root -" ];

    systemd.user.services.selkies = {
      description = "Selkies streaming server (pixelflux compositor, pcmflux audio)";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = cfg.user;
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
        SELKIES_USE_BROWSER_CURSORS = lib.boolToString cfg.browserCursors;
      } // cfg.extraEnvironment;
      serviceConfig = {
        # Stale sockets would make pixelflux auto-pick a later name than the session waits for.
        ExecStartPre = "${pkgs.runtimeShell} -c 'rm -f ${runtimeDir}/wayland-*'";
        ExecStart = lib.getExe cfg.package;
        Restart = "on-failure";
        RestartSec = 2;
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
        WAYLAND_DISPLAY = selkiesSocket;
        XDG_CURRENT_DESKTOP = "KDE";
        KDE_FULL_SESSION = "true";
        KDE_SESSION_VERSION = "6";
        QT_QPA_PLATFORM = "wayland";
        KWIN_WAYLAND_NO_PERMISSION_CHECKS = "1";
        MOZ_ENABLE_WAYLAND = "1";
      } // lib.optionalAttrs cfg.softwareRendering {
        LIBGL_ALWAYS_SOFTWARE = "1";
      };
      serviceConfig = {
        User = cfg.user;
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
        if (subject.user == "${cfg.user}" && [
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
    environment.systemPackages = [ cfg.package ];
  };
}
