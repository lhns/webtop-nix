{
  description = "Browser-streamed Plasma desktop on NixOS (Selkies + pixelflux + pcmflux)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Supported systems; CI builds each one natively, in a matrix.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f system (import nixpkgs { inherit system; overlays = [ self.overlays.default ]; }));
    in
    {
      overlays.default = import ./overlay.nix;

      packages = forAllSystems (system: pkgs: {
        inherit (pkgs) pixelflux pcmflux selkies webtop-app-screen;
        kwin = pkgs.kwinSoftwarePresentation;
        default = pkgs.selkies;
      });

      nixosModules = {
        webtop = import ./modules/webtop.nix;
        default = self.nixosModules.webtop;
      };

      checks = forAllSystems (system: pkgs: {
        # Evaluates a system using the module, without building it.
        module-eval =
          let
            sys = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.webtop
                {
                  services.webtop.enable = true;
                  boot.loader.grub.enable = false;
                  fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
                  system.stateVersion = "25.11";
                }
              ];
            };
          in
          pkgs.writeText "module-eval" (builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath);
        inherit (self.packages.${system}) pixelflux pcmflux selkies;
        vm = import ./tests/vm.nix { inherit pkgs self; };
        second-display = import ./tests/second-display.nix { inherit pkgs self; };
      });
    };
}
