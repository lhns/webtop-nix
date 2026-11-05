# The desktop as a container with systemd as PID 1 (docker, podman, a Kubernetes pod): what the runtime
# owns is left alone, no consoles, and the options a container needs. Add it beside `nixosModules.webtop`.
# It sets neither `services.webtop.*` nor `system.stateVersion`; the consumer owns those.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.webtop;
  overlay = cfg.storeOverlay;
  # Lower: the image's /nix, bound read-only at lowerRoot by the entrypoint. Upper and DB: the volume.
  overlayStore = "local-overlay://?lower-store=${lib.escapeURL "local?root=${overlay.lowerRoot}&read-only=true"}"
    + "&upper-layer=${overlay.upperLayer}&check-mount=true&ignore-gc-delete-failure=true"
    + "&remount-hook=${remountHook}";
  # Called by nix after deleting upper paths (GC), so overlayfs drops its cached lookups.
  remountHook = pkgs.writeShellScript "webtop-remount-store" ''
    exec ${pkgs.util-linux}/bin/mount -o remount /nix/store
  '';
in
{
  options.services.webtop = {
    storeOverlay = {
      enable = lib.mkEnableOption ''
        the Nix store as a `local-overlay` store: the image's store is the read-only lower layer, a
        volume holds the upper layer, so a user's installs persist without copying the image's store.
        The mounts are the entrypoint's job (overlayfs on /nix/store before systemd runs, which
        itself lives in /nix/store); this option configures only the Nix daemon for them. The daemon
        alone opens the overlay store and every client, root included, goes through it'';
      lowerRoot = lib.mkOption {
        type = lib.types.str;
        default = "/.lower";
        description = "Where the image's /nix is bound read-only; the overlay's lower store.";
      };
      upperLayer = lib.mkOption {
        type = lib.types.str;
        default = "/persist/nix/upper";
        description = "The upper layer of /nix/store on the volume. The store's database and profiles sit beside it.";
      };
    };

    journalRelay = {
      enable = lib.mkEnableOption ''
        a unit that writes the journal to a fifo, for an entrypoint to relay to the container's log
        (`docker logs`, `kubectl logs`): systemd replaces PID 1's stdout, and journald's
        ForwardToConsole needs /dev/console. Nothing reads the fifo unless the entrypoint does'';
      path = lib.mkOption {
        type = lib.types.str;
        default = "/run/webtop/console";
        description = "The fifo, created by the entrypoint.";
      };
    };

    adminTools.enable = lib.mkEnableOption "shell tools for working in the container (ps, ip, lsof, git, jq, curl, ...)";
  };

  config = {
    boot.isContainer = true;

    # The runtime manages these; NixOS must not touch them.
    networking.hostName = lib.mkDefault "";
    networking.useDHCP = false;
    networking.useHostResolvConf = false;
    networking.resolvconf.enable = false;
    services.resolved.enable = false;
    environment.etc."resolv.conf".enable = false;
    environment.etc."hosts".enable = false;
    networking.firewall.enable = false;

    # core_pattern is a host sysctl: dumps would land in the user's home.
    systemd.settings.Manager.DefaultLimitCORE = "0";
    systemd.user.settings.Manager.DefaultLimitCORE = "0";

    # No virtual consoles in a container (they restart in a loop).
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@".enable = false;
    systemd.services."serial-getty@".enable = false;
    systemd.services."console-getty".enable = false;
    systemd.services.systemd-oomd.enable = false;
    systemd.suppressedSystemUnits = [ "getty@.service" "autovt@.service" ];
    services.logind.settings.Login = { NAutoVTs = 0; ReserveVT = 0; };
    # rtkit-daemon cannot drop its capabilities in a container and stops answering; pixelflux asks it
    # for priority before binding its Wayland socket and would wait forever. Without it the call fails at once.
    security.rtkit.enable = lib.mkForce false;
    # Needs /dev/fuse; a failed unit would degrade the user manager.
    systemd.user.units."xdg-document-portal.service".enable = false;

    # The build sandbox needs namespaces a container may not grant.
    nix.settings.sandbox = lib.mkDefault false;

    environment.systemPackages = lib.mkIf cfg.adminTools.enable (with pkgs; [
      util-linux procps iproute2 findutils gnugrep file lsof
      git jq curl wget htop libnotify
    ]);

    nix = lib.mkIf overlay.enable {
      settings = {
        experimental-features = [ "local-overlay-store" "read-only-local-store" ];
        store = "daemon";
      };
      checkConfig = false; # would try to open the store at build time
    };
    # %% : systemd would read the URL's %-escapes as unit specifiers.
    systemd.services.nix-daemon.environment.NIX_CONFIG =
      lib.mkIf overlay.enable "store = ${lib.replaceStrings [ "%" ] [ "%%" ] overlayStore}";

    systemd.services.webtop-journal-relay = lib.mkIf cfg.journalRelay.enable {
      description = "Relay the journal to the container log";
      wantedBy = [ "sysinit.target" ];
      after = [ "systemd-journald.service" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Restart = "always";
        ExecStart = "${pkgs.runtimeShell} -c 'exec ${pkgs.systemd}/bin/journalctl -b -f -n all -o short-precise > ${cfg.journalRelay.path}'";
      };
    };
  };
}
