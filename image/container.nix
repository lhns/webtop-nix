# The standalone image's system: the module as a container with systemd as PID 1. Run it with
# `docker run --privileged --cgroupns=private --shm-size=1g -p 127.0.0.1:8082:8082` (README).
# The container parts are `nixosModules.container` (modules/container.nix).
{ ... }:

{
  system.stateVersion = "26.05";

  services.webtop = {
    enable = true;
    softwareCenter.enable = true;
    nixProfile.enable = true;
    adminTools.enable = true;
    containers.enable = true;
    # The store survives container and image updates on the /persist volume (README, "Store overlay");
    # image/webtop-entrypoint mounts it.
    storeOverlay.enable = true;
    # Reached through the container's published port; Selkies' auth is off (README, "Image").
    address = "0.0.0.0";
  };
}
