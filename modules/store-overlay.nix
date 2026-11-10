# What an image update needs around the store overlay (ADR 0013): the old overlay is kept in
# trash-* by webtop-nix-lower; these units copy the users' paths from it into the new store, reinstall
# what did not come back, and delete the trash. Part of the `container` module, active with
# `storeOverlay.enable`; the restore and reinstall units also need `nixProfile.enable`.
{ config, lib, pkgs, ... }:

let
  webtop = config.services.webtop;
  overlay = webtop.storeOverlay;
  uid = toString webtop.uid;
  persist = overlay.persistPath;
  inherit (webtop.nixProfile) reinstall;
  homesRoot = dirOf (webtop.nixProfile.homeStoragePath or "/home/user");

  restore = pkgs.writeShellApplication {
    name = "webtop-nix-restore";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep config.nix.package ];
    text = builtins.readFile ./store-overlay/webtop-nix-restore.sh;
  };

  # Root. Any restore exit code is fine: what did not come back is left to the reinstall.
  restoreUnit = pkgs.writeShellApplication {
    name = "webtop-nix-restore-unit";
    runtimeInputs = with pkgs; [ coreutils systemd restore ];
    text = ''
      export WEBTOP_NIX_PERSIST=${lib.escapeShellArg persist} WEBTOP_HOMES_ROOT=${lib.escapeShellArg homesRoot}
      webtop-nix-restore || echo "webtop-nix-restore exit $?"
      # Not reached when the unit is stopped: the marker stays and the restore resumes next boot.
      rm -f ${lib.escapeShellArg persist}/reinstall/restore
      systemctl start --no-block webtop-nix-trash.service webtop-nix-reinstall.service
      wait
    '';
  };
in
{
  config = lib.mkIf overlay.enable (lib.mkMerge [
    {
      systemd.services.webtop-nix-trash = {
        description = "Delete store overlays left by an image update";
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          ConditionPathExistsGlob = "${persist}/trash-*";
          ConditionPathExists = "!${persist}/reinstall/restore"; # the restore reads from them
        };
        serviceConfig = {
          Type = "exec"; # see webtop-nix-restore
          ExecStart = "${pkgs.runtimeShell} -c '${pkgs.coreutils}/bin/rm -rf ${persist}/trash-*'";
          Nice = 19;
          IOSchedulingClass = "idle";
        };
      };
    }
    (lib.mkIf (webtop.nixProfile.enable or false) {
    # The restore's work is the reinstall's first half: the switch waits for both.
    systemd.services.webtop-home-manager-template.before = [ "webtop-nix-reinstall.service" ];
    # After an image update the reinstall unit runs the setup instead, once the store paths are back.
    systemd.services.webtop-home-manager.unitConfig.ConditionPathExists = "!${persist}/reinstall/pending";

    # Image updates (webtop-nix-lower keeps the old store overlay in trash-*): the restore unit copies
    # the users' paths from it into the new store, then removes the marker and starts the trash
    # cleanup and the reinstall, which covers what did not come back. All three wait for the marker.
    systemd.services.webtop-nix-restore = {
      description = "Restore the user's Nix store paths after an image update";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "nix-daemon.socket" ];
      unitConfig.ConditionPathExists = "${persist}/reinstall/restore";
      serviceConfig = {
        # Not oneshot: multi-user.target would wait for it.
        Type = "exec";
        ExecStart = lib.getExe restoreUnit;
        Nice = 10;
        # A stopped restore must not eat the termination grace period; it resumes next boot.
        TimeoutStopSec = 10;
      };
    };
    systemd.services.webtop-nix-reinstall = {
      description = "Reinstall the user's Nix packages after an image update";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "nix-daemon.socket" "nix-daemon.service" "webtop-session.service" ];
      unitConfig.ConditionPathExists = [
        "${persist}/reinstall/pending"
        "!${persist}/reinstall/restore"
      ];
      environment = {
        DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${uid}/bus";
        XDG_RUNTIME_DIR = "/run/user/${uid}";
      };
      serviceConfig = {
        Type = "exec"; # see webtop-nix-restore
        User = uid;
        # The manifest is named after the home's directory on the volume (webtop-nix-lower records it).
        ExecStart = "${lib.getExe reinstall} ${persist}/reinstall/${baseNameOf webtop.nixProfile.homeStoragePath}.manifest.json";
        # As webtop-home-manager.service, whose setup script it runs.
        TimeoutStopSec = "5min";
        # "+": as root, the records belong to root. Only after the script ran to the end: a failure or a
        # stop retries next boot (systemd counts a SIGTERM death as success, hence EXIT_CODE).
        ExecStopPost = "+${pkgs.runtimeShell} -c '[ \"$$SERVICE_RESULT\" = success ] && [ \"$$EXIT_CODE\" = exited ] && ${pkgs.coreutils}/bin/rm -f ${persist}/reinstall/pending || true'";
      };
    };
    })
  ]);
}
