# A browser-streamed Plasma 6 desktop: Selkies (pixelflux compositor + pcmflux audio)
# hosts a Wayland socket, KWin nests in it, the Plasma session runs under real logind.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.webtop;
  uid = toString cfg.uid;
  runtimeDir = "/run/user/${uid}";
  # Selkies' compositor; KWin then takes the default wayland-0 for itself.
  selkiesSocket = "wayland-1";

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

  startSession = pkgs.writeShellScript "webtop-start-session" ''
    for _ in $(seq 1 600); do
      [ -S "${runtimeDir}/${selkiesSocket}" ] && break
      sleep 0.1
    done
    exec ${pkgs.kdePackages.plasma-workspace}/bin/startplasma-wayland
  '';
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
      default = "0.0.0.0";
      description = "Address Selkies listens on (its own default is loopback only).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the Selkies port in the firewall.";
    };

    softwareRendering = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Make KWin composite with QPainter (for hosts without a GPU).";
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

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    hardware.graphics.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
    security.rtkit.enable = lib.mkDefault true;
    services.pipewire = {
      enable = lib.mkDefault true;
      alsa.enable = lib.mkDefault true;
      pulse.enable = lib.mkDefault true;
    };

    systemd.tmpfiles.rules = [ "d /tmp/.X11-unix 1777 root root -" ];

    systemd.user.services.selkies = {
      description = "Selkies streaming server (pixelflux compositor, pcmflux audio)";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = cfg.user;
      path = [ pkgs.wl-clipboard pkgs.pulseaudio ];
      environment = {
        SELKIES_WAYLAND = "true";
        SELKIES_WAYLAND_SOCKET_INDEX = "1";
        SELKIES_ADDR = cfg.address;
        SELKIES_PORT = toString cfg.port;
        # Authentication is the job of whatever fronts this port.
        SELKIES_ENABLE_BASIC_AUTH = "false";
      } // cfg.extraEnvironment;
      serviceConfig = {
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
        XDG_SEAT = "seat0";
        XDG_RUNTIME_DIR = runtimeDir;
        WAYLAND_DISPLAY = selkiesSocket;
        XDG_CURRENT_DESKTOP = "KDE";
        KDE_FULL_SESSION = "true";
        KDE_SESSION_VERSION = "6";
        QT_QPA_PLATFORM = "wayland";
        KWIN_WAYLAND_NO_PERMISSION_CHECKS = "1";
        MOZ_ENABLE_WAYLAND = "1";
      } // lib.optionalAttrs cfg.softwareRendering { KWIN_COMPOSE = "Q"; };
      serviceConfig = {
        User = cfg.user;
        PAMName = "login";
        StandardInput = "null";
        ExecStart = startSession;
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

    fonts.packages = with pkgs; [ noto-fonts noto-fonts-color-emoji noto-fonts-cjk-sans liberation_ttf ];
    programs.firefox.enable = lib.mkDefault true;
    environment.systemPackages = [ cfg.package ];
  };
}
