# Boots the module and checks that Selkies answers. Needs KVM to run; evaluates without.
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "webtop";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_open_port(8082)
    machine.succeed("curl -sf http://localhost:8082/ | grep -qi '<html'")
    machine.wait_for_unit("webtop-session.service")
  '';
}
