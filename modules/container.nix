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
  # The users' homes sit beside the home storage path (for example /persist/home, standalone: /home).
  homesRoot = dirOf (cfg.nixProfile.homeStoragePath or "/home/user");
  # Static busybox shebangs: the scripts run before /nix/store is overlaid. nix-store is the image's
  # own, which is what /nix/store is until then.
  init = pkgs.runCommand "webtop-store-init" { } ''
    mkdir -p $out/bin
    sub() {
      substitute ${./store-overlay}/$1 $out/bin/$1 \
        --subst-var-by busybox ${pkgs.pkgsStatic.busybox} \
        --subst-var-by persistPath ${lib.escapeShellArg overlay.persistPath} \
        --subst-var-by lowerRoot ${lib.escapeShellArg overlay.lowerRoot} \
        --subst-var-by homesRoot ${lib.escapeShellArg homesRoot} \
        --subst-var-by bin $out/bin \
        --subst-var-by nixStore ${config.nix.package}/bin/nix-store
      chmod +x $out/bin/$1
    }
    sub webtop-store-init
    sub webtop-nix-lower
    sub webtop-nix-partial
  '';
in
{
  imports = [ ./store-overlay.nix ];

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
      persistPath = lib.mkOption {
        type = lib.types.str;
        default = "/persist/nix";
        description = ''
          Where the overlay's state lives on the volume: `upper`, `work`, `var` (the store's database,
          GC roots and profiles), `lower-stamp`, `lower-paths`, `reinstall/` and `trash-*` (README,
          "Store overlay"). Existing volumes carry this layout and the default path; do not change either.
        '';
      };
      upperLayer = lib.mkOption {
        type = lib.types.str;
        default = "${overlay.persistPath}/upper";
        defaultText = lib.literalExpression ''"''${config.services.webtop.storeOverlay.persistPath}/upper"'';
        description = "The upper layer of /nix/store on the volume. The store's database and profiles sit beside it.";
      };
      init = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = init;
        defaultText = "a package of static busybox scripts";
        description = ''
          `bin/webtop-store-init` for an entrypoint to run as root before `exec /sbin/init` (needs `/run`
          mounted, private mounts and the volume in place): binds the image's `/nix` at `lowerRoot`,
          handles an image update (invalidates what the new store breaks, or resets the overlay and
          leaves the restore markers; `webtop-nix-lower`, `webtop-nix-partial`), mounts the overlay on
          `/nix/store` and `var` on `/nix/var/nix`. Reads `/webtop-image-stamp`, a hash identifying the
          image's store. `WEBTOP_HOMES_ROOT` (default: the directory of `nixProfile.homeStoragePath`) names the directory
          of the users' homes, whose Nix profile manifests an update records. Under
          `nixProfile` (required with the overlay) it also sets the restore, reinstall and trash units up.
        '';
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

    environment.systemPackages = lib.mkIf cfg.adminTools.enable (with pkgs; [
      util-linux procps iproute2 findutils gnugrep file lsof
      git jq curl wget htop libnotify
    ]);

    nix.settings = lib.mkMerge [
      # The build sandbox needs namespaces a container may not grant.
      { sandbox = lib.mkDefault false; }
      (lib.mkIf overlay.enable {
        experimental-features = [ "local-overlay-store" "read-only-local-store" ];
        store = "daemon";
        # A registered path's bytes are on disk before its row: the image-update invalidation
        # (webtop-nix-partial) keeps upper paths by their rows. Costs an fsync per installed path.
        fsync-store-paths = lib.mkDefault true;
      })
    ];
    assertions = lib.optionals overlay.enable [
      {
        assertion = overlay.upperLayer == "${overlay.persistPath}/upper";
        message = "services.webtop.storeOverlay.upperLayer must be persistPath/upper: webtop-nix-lower and the restore expect the layout there";
      }
      {
        assertion = cfg.nixProfile.enable or false;
        message = "services.webtop.storeOverlay needs services.webtop.nixProfile.enable: after a full reset of the overlay only the restore unit clears reinstall/restore, and webtop-nix-trash waits for that";
      }
    ];
    nix.checkConfig = lib.mkIf overlay.enable false; # would try to open the store at build time
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
