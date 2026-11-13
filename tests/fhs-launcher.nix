# A launcher written by a buildFHSEnv app starts from the desktop (README, "Generic Linux binaries"): the app
# copies a binary built for generic Linux into the home and writes a desktop entry for it, as JetBrains
# Toolbox does for its IDEs. Started through KIO, as the menu starts it, outside the app's FHS environment,
# the binary needs nix-ld and a library from its set. Needs KVM to run; evaluates without.
{ pkgs, self }:

let
  # The generic loader path, as nixpkgs' ldso module computes it.
  ldso = "/${pkgs.stdenv.hostPlatform.libDir}/${baseNameOf pkgs.stdenv.cc.bintools.dynamicLinker}";
  # Links libxkbcommon, which is in the AppImage set but not in nix-ld's defaults. No rpath: the FHS loader
  # path and nothing else, like a binary from a vendor tarball.
  generic = pkgs.runCommandCC "generic-linux-app" { nativeBuildInputs = [ pkgs.patchelf ]; buildInputs = [ pkgs.libxkbcommon ]; } ''
    cat > app.c <<'EOF'
    #include <stdio.h>
    #include <xkbcommon/xkbcommon.h>
    int main(int argc, char **argv) {
      FILE *f;
      if (argc < 2 || !xkb_context_new(XKB_CONTEXT_NO_DEFAULT_INCLUDES) || !(f = fopen(argv[1], "w"))) return 1;
      fputs("ran\n", f);
      return fclose(f) != 0;
    }
    EOF
    mkdir -p $out/bin
    $CC app.c -o $out/bin/app -lxkbcommon
    patchelf --set-interpreter ${ldso} --remove-rpath $out/bin/app
    [ "$(patchelf --print-interpreter $out/bin/app)" = ${ldso} ] && [ -z "$(patchelf --print-rpath $out/bin/app)" ]
  '';
  # Inside its FHS environment the copy runs; the entry's Exec points at the copy, outside it.
  fhsApp = pkgs.buildFHSEnv {
    name = "fhs-demo";
    targetPkgs = p: [ p.libxkbcommon ];
    runScript = pkgs.writeShellScript "fhs-demo-install" ''
      set -eu
      d=$HOME/.local/share/fhs-demo
      mkdir -p "$d/bin" "$HOME/.local/share/applications"
      install -m 755 ${generic}/bin/app "$d/bin/app"
      "$d/bin/app" "$HOME/ran-fhs"
      printf '[Desktop Entry]\nType=Application\nName=FHS Demo\nExec="%s" %s\nTerminal=false\n' \
        "$d/bin/app" "$HOME/ran-menu" > "$HOME/.local/share/applications/fhs-demo.desktop"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "webtop-fhs-launcher";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    services.webtop.nixLd.enable = true;
    environment.systemPackages = [ fhsApp ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
  };
  testScript = ''
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    home = "/home/user"
    machine.wait_for_unit("webtop-session.service")
    ${import ./wait-session.nix}

    machine.succeed(f"{ubus} fhs-demo")
    machine.succeed(f"test -s {home}/ran-fhs")

    # Without the library set the binary must fail: the library comes from nix-ld, not from anywhere else.
    machine.fail(f"{ubus} env NIX_LD_LIBRARY_PATH=/var/empty {home}/.local/share/fhs-demo/bin/app {home}/ran-bare")

    # As the menu does: KIO's ApplicationLauncherJob, in a transient app unit of the user's manager.
    machine.succeed(f"{ubus} systemd-run --user --wait --pipe -E QT_QPA_PLATFORM=offscreen kstart --application fhs-demo")
    machine.wait_until_succeeds(f"test -s {home}/ran-menu", timeout=60)
    machine.succeed("journalctl _UID=1000 -b --no-pager -o cat | grep -qx 'Started FHS Demo.'")
  '';
}
