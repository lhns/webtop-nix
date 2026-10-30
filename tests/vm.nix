# Boots the module and checks that Selkies answers. Needs KVM to run; evaluates without.
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "webtop";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # Without it startplasma-wayland exits "Could not start D-Bus" and restarts forever. Belongs in the module.
    systemd.services.webtop-session.environment.DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_open_port(8082)
    machine.succeed("curl -sf http://localhost:8082/ | grep -qi '<html'")
    machine.wait_for_unit("webtop-session.service")

    # A gray screen is KWin up but not compositing (no render device); the session unit still looks healthy.
    machine.wait_until_succeeds(
        "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
        "busctl --user get-property org.kde.KWin /Compositor org.kde.kwin.Compositing active | grep -qx 'b true'",
        timeout=180,
    )
  '';
}
