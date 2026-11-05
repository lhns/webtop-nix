# Writes timeZone= / locale= to ~/.config/webtop/session.conf, the file the desktop reads before the
# session starts. The gateway's keys (sso-logout.nix) share it; the text merges line by line.
{ config, lib, ... }:

let
  cfg = config.webtop;
  line = key: value: lib.optional (value != null) "${key}=${value}";
  lines = line "timeZone" cfg.timeZone ++ line "locale" cfg.locale;
in
{
  options.webtop = {
    timeZone = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Europe/Berlin";
      description = ''
        Time zone of the desktop session (an IANA name from the image's zoneinfo). `null` leaves it to
        the deployment. Applied when the session starts: restart the desktop to change it. An invalid
        name is logged and ignored.
      '';
    };
    locale = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "de_DE.UTF-8";
      description = ''
        Locale (`LANG`) of the desktop session, one of those built into the image
        (`services.webtop.locales`). `null` leaves it to the deployment. Applied when the session starts.
      '';
    };
  };

  config = lib.mkIf (lines != [ ]) {
    xdg.configFile."webtop/session.conf".text =
      lib.concatStringsSep "\n" ([ "# Written by home-manager (webtop.timeZone, webtop.locale)." ] ++ lines) + "\n";
  };
}
