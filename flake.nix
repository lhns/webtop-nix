{
  description = "Browser-streamed Plasma desktop on NixOS (Selkies + pixelflux + pcmflux)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; overlays = [ self.overlays.default ]; };
    in
    {
      overlays.default = import ./overlay.nix;

      packages.${system} = {
        inherit (pkgs) pixelflux pcmflux selkies;
        default = pkgs.selkies;
      };

      nixosModules = {
        webtop = import ./modules/webtop.nix;
        default = self.nixosModules.webtop;
      };

      checks.${system} = {
        # Evaluates a system using the module, without building it.
        module-eval =
          let
            sys = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.webtop
                {
                  nixpkgs.overlays = [ self.overlays.default ];
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
      };
    };
}
