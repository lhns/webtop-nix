# The software center's "Run without installing" (README, "Software"): its backend, the same functions
# the app calls, builds a package into the store and starts its app or program as the user, and leaves no
# trace: the profile, the home-manager declaration (packages.json) and the GC roots are unchanged, and the
# built paths are garbage. The packages are two offline fixtures (no dependencies, built by a static
# busybox) so the outputs are new store paths. Needs KVM to run; evaluates without.
{ pkgs, self }:

let
  system = pkgs.stdenv.hostPlatform.system;
  bb = "${pkgs.pkgsStatic.busybox}/bin/busybox";
  # Plain `echo` lines instead of heredocs: the script travels through two Nix string layers.
  fixture = pkgs.writeText "nsc-fixture-flake.nix" ''
    {
      outputs = { self }: let
        mk = name: lines: builtins.derivation {
          inherit name;
          system = "${system}";
          builder = "${bb}";
          args = [ "sh" "-c" (builtins.concatStringsSep "\n" lines) ];
        };
      in {
        packages.${system} = {
          # A desktop entry whose Exec is a bare name: it must be found on the outputs' bin.
          gui = mk "nsc-demo-gui" [
            "${bb} mkdir -p $out/bin $out/share/applications"
            "echo '#!/bin/sh' > $out/bin/nsc-demo-gui"
            "echo 'echo ran > $HOME/ran-gui' >> $out/bin/nsc-demo-gui"
            "${bb} chmod +x $out/bin/nsc-demo-gui"
            "echo '[Desktop Entry]' > $out/share/applications/nsc-demo.desktop"
            "echo 'Type=Application' >> $out/share/applications/nsc-demo.desktop"
            "echo 'Name=NSC Demo' >> $out/share/applications/nsc-demo.desktop"
            "echo 'Exec=nsc-demo-gui %U' >> $out/share/applications/nsc-demo.desktop"
          ];
          # No app: the program comes from meta.mainProgram.
          cli = (mk "nsc-demo-cli-1.0" [
            "${bb} mkdir -p $out/bin"
            "echo '#!/bin/sh' > $out/bin/nsc-demo-cli"
            "echo 'echo ran > $HOME/ran-cli' >> $out/bin/nsc-demo-cli"
            "${bb} chmod +x $out/bin/nsc-demo-cli"
          ]) // { meta.mainProgram = "nsc-demo-cli"; };
        };
      };
    }
  '';
  # What a run must not change, as the user.
  state = pkgs.writeShellScript "nsc-state" ''
    nix profile list --json
    echo "--- declaration"
    find "$HOME/.config/home-manager" -type f -exec sha256sum {} + 2>/dev/null | sort -k2
    echo "--- profile links"
    ls -l "$HOME/.local/state/nix/profiles" 2>&1
    ls -l "/nix/var/nix/profiles/per-user/$(id -un)" 2>&1
    true
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-software-center-run";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { lib, ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    services.webtop.nixProfile.enable = true;
    services.webtop.softwareCenter.enable = true;
    systemd.services.webtop-home-manager.wantedBy = lib.mkForce [ ];
    nix.settings.substituters = lib.mkForce [ ];
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    # The fixtures' builder lives outside the sandbox's closure.
    nix.settings.extra-sandbox-paths = [ "${pkgs.pkgsStatic.busybox}" ];
    # nixosSystem sets this registry entry; a test node does not.
    nix.registry.nixpkgs.to = { type = "path"; path = "${self.inputs.nixpkgs}"; };
    environment.etc."nsc-fixture-flake.nix".source = fixture;
    environment.etc."nsc-state.sh".source = state;
    virtualisation.memorySize = 6144;
    virtualisation.cores = 2;
  };
  testScript = ''
    import re
    home = "/home/user"

    def as_user(cmd):
        return f"runuser -u user -- env HOME={home} {cmd}"

    def smoke(args):
        return as_user(f"sh -c 'exec \"$(dirname \"$(dirname \"$(readlink -f \"$(command -v nix-software-center)\")\")\")\"/libexec/nix-software-center/nsc-backend-smoke {args}'")

    def snapshot():
        profile = machine.succeed(as_user("/etc/nsc-state.sh"))
        roots = machine.succeed("find /nix/var/nix/gcroots | sort")
        return profile, roots

    machine.wait_for_unit("multi-user.target")
    # The first login writes into the home: let it finish before the first snapshot.
    machine.wait_for_unit("webtop-session.service")
    machine.wait_until_succeeds("runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user is-active plasma-workspace.target", timeout=300)
    machine.succeed("install -d -o user /tmp/nsc-fixture && install -o user -m 644 /etc/nsc-fixture-flake.nix /tmp/nsc-fixture/flake.nix")

    before = snapshot()

    def run(target, args=""):
        out = machine.succeed(smoke(f"--run path:/tmp/nsc-fixture#{target} {args}"))
        print(out)
        paths = re.findall(r"^run: out (/nix/store/\S+)$", out, re.M)
        assert paths, f"no out path in the smoke output of {target}"
        return out, paths

    gui_out, gui_paths = run("gui", "--desktop-id nsc-demo.desktop")
    assert re.search(r"^run: target desktop \S+/share/applications/nsc-demo\.desktop$", gui_out, re.M), "the desktop entry was not the target"
    # A detached app: the smoke has already exited.
    machine.wait_until_succeeds(f"test -s {home}/ran-gui", timeout=60)

    cli_out, cli_paths = run("cli")
    assert re.search(r"^run: target program \S+/bin/nsc-demo-cli$", cli_out, re.M), "the main program was not the target"
    machine.succeed(f"test -s {home}/ran-cli")

    after = snapshot()
    assert before[0] == after[0], f"the profile or declaration changed:\n{before[0]}\n---\n{after[0]}"
    assert before[1] == after[1], f"the GC roots changed:\n{before[1]}\n---\n{after[1]}"

    # No root: both builds are garbage.
    dead = machine.succeed("nix-store --gc --print-dead").splitlines()
    for p in gui_paths + cli_paths:
        assert p in dead, f"{p} is not collectable"
  '';
}
