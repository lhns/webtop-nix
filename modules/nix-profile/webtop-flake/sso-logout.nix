# Writes ~/.config/webtop/session.conf, the only interface to the kube-webtop-workspaces gateway:
# it reads the file when the session is signed out or locked and accepts just these two booleans.
{ config, lib, ... }:

let
  cfg = config.webtop.ssoLogout;
  line = key: value: lib.optional (value != null) "${key}=${lib.boolToString value}";
  lines = line "onLogout" cfg.onLogout ++ line "onLock" cfg.onLock;
in
{
  options.webtop.ssoLogout = {
    onLogout = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Also sign the browser out at the login provider when the desktop's session is signed out.
        `null` leaves the default to the deployment. Only has an effect behind a
        kube-webtop-workspaces gateway with a logout URL configured; otherwise it is a no-op.
      '';
    };
    onLock = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Also sign the browser out at the login provider when the desktop's session is locked.
        `null` leaves the default to the deployment. Only has an effect behind a
        kube-webtop-workspaces gateway with a logout URL configured; otherwise it is a no-op.
      '';
    };
  };

  config = lib.mkIf (lines != [ ]) {
    xdg.configFile."webtop/session.conf".text =
      lib.concatStringsSep "\n" ([ "# Written by home-manager (webtop.ssoLogout)." ] ++ lines) + "\n";
  };
}
