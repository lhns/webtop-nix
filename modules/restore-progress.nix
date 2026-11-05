# The writer side of the software restore's progress (nixProfile.progress): a file under
# /run/webtop/restore that a reader turns into UI. Nothing here shows it; without a restore
# that calls `start`, every command is a no-op.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.webtop;
  progress = pkgs.writeShellApplication {
    name = "webtop-restore-progress";
    runtimeInputs = with pkgs; [ coreutils jq ];
    text = builtins.readFile ./restore-progress/webtop-restore-progress.sh;
  };
in
{
  config = lib.mkIf cfg.nixProfile.enable {
    services.webtop.nixProfile.progress = lib.mkDefault progress;
    # The restore scripts run as the user and replace the progress file atomically, so the directory is theirs.
    systemd.tmpfiles.rules = [ "d /run/webtop/restore 0755 ${toString cfg.uid} - -" ];
  };
}
