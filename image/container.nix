# The standalone image's system: the module as a container with systemd as PID 1. Run it with
# `docker run --privileged --cgroupns=private --shm-size=1g -p 127.0.0.1:8082:8082` (README).
{ lib, ... }:

{
  boot.isContainer = true;
  system.stateVersion = "26.05";

  services.webtop = {
    enable = true;
    # Reached through the container's published port; Selkies' auth is off (README, "Image").
    address = "0.0.0.0";
  };

  # The runtime owns these (bind-mounted files); NixOS replacing them would fail.
  networking.hostName = "";
  networking.useDHCP = false;
  networking.useHostResolvConf = false;
  networking.resolvconf.enable = false;
  services.resolved.enable = false;
  environment.etc."resolv.conf".enable = false;
  environment.etc."hosts".enable = false;
  networking.firewall.enable = false;

  # No virtual consoles in a container (they restart in a loop).
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@".enable = false;
  systemd.services."serial-getty@".enable = false;
  systemd.services."console-getty".enable = false;
  systemd.suppressedSystemUnits = [ "getty@.service" "autovt@.service" ];
  services.logind.settings.Login = { NAutoVTs = 0; ReserveVT = 0; };
  # rtkit-daemon cannot drop its capabilities in a container and stops answering; pixelflux asks it
  # for priority before binding its Wayland socket and would wait forever. Without it the call fails at once.
  security.rtkit.enable = lib.mkForce false;
  # Needs /dev/fuse; a failed unit would degrade the user manager.
  systemd.user.units."xdg-document-portal.service".enable = false;

  # The build sandbox needs namespaces a container may not grant.
  nix.settings.sandbox = lib.mkDefault false;
}
