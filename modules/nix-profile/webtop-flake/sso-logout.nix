# Writes the consumer keys onLogout and onLock to ~/.config/webtop/session.conf: a consumer (a gateway)
# reads them when the session is signed out or locked. The desktop itself ignores them.
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
        `null` leaves the default to the deployment. Only has an effect where a
        consumer reads the key and has a logout URL configured; otherwise it is a no-op.
      '';
    };
    onLock = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Also sign the browser out at the login provider when Lock is used. The session itself is
        not locked or ended (the lock is cleared at once, ADR 0010). `null` leaves the default to
        the deployment. Only has an effect where a consumer reads the key and has a logout URL
        and lock sign-out enabled; otherwise it is a no-op. A consumer may treat `false` as "Lock does nothing".
      '';
    };
  };

  config = lib.mkIf (lines != [ ]) {
    xdg.configFile."webtop/session.conf".text =
      lib.concatStringsSep "\n" ([ "# Written by home-manager (webtop.ssoLogout)." ] ++ lines) + "\n";
  };
}
