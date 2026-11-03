{
  description = "Browser-streamed Plasma desktop on NixOS (Selkies + pixelflux + pcmflux)";

  # Consumers follow this nixpkgs (kube-webtop-workspaces: one Qt tree, and the image builder's skopeo).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # The image builder's layersFile (image/default.nix) is new upstream; bump deliberately.
  inputs.nix2container = {
    url = "github:nlewo/nix2container/535166ecac3fcdff43787aa958dd7e954770581d";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nix2container }:
    let
      # Supported systems; CI builds each one natively, in a matrix.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f system (import nixpkgs { inherit system; overlays = [ self.overlays.default ]; }));

      imageLib = system: import ./image { nix2container = nix2container.packages.${system}.nix2container; };
      # The standalone image's system; also the reference other images' layers are classified by.
      standalone = nixpkgs.lib.genAttrs systems (system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.webtop ./image/container.nix ];
      });
    in
    {
      overlays.default = import ./overlay.nix;

      # Image builder (ADR 0005, image/default.nix). buildImage classifies by this flake's standalone
      # image unless given another `reference` (or null).
      lib = {
        buildImage = args:
          let system = args.nixos.pkgs.stdenv.hostPlatform.system;
          in (imageLib system).buildImage ({ reference = self.lib.referencePaths.${system}; } // args);
        referencePaths = nixpkgs.lib.genAttrs systems (system: (imageLib system).referencePaths standalone.${system});
      };

      packages = forAllSystems (system: pkgs: {
        inherit (pkgs) pixelflux pcmflux selkies webtop-app-screen;
        kwin = pkgs.kwinSoftwarePresentation;
        default = pkgs.selkies;

        # docker run-able desktop (README, "Image"); its own closure is the layer reference.
        image =
          let
            sys = standalone.${system};
            rootfs = pkgs.runCommand "rootfs" { } ''
              mkdir -p $out/sbin $out/etc $out/run $out/tmp $out/var $out/home $out/proc $out/sys $out/dev
              chmod 1777 $out/tmp
              ln -s ${sys.config.system.build.toplevel}/init $out/sbin/init
            '';
          in
          (imageLib system).buildImage {
            name = "ghcr.io/lhns/webtop-nix";
            tag = "dev";
            nixos = sys;
            copyToRoot = [ rootfs ];
            config = {
              Entrypoint = [ "/sbin/init" ];
              StopSignal = "SIGRTMIN+3";
              Env = [ "container=docker" "PATH=/run/current-system/sw/bin:/run/wrappers/bin" ];
              ExposedPorts."8082/tcp" = { };
              # Links the ghcr package to this repo, so the workflow's GITHUB_TOKEN may push it.
              Labels."org.opencontainers.image.source" = "https://github.com/lhns/webtop-nix";
            };
          };
        layer-report = pkgs.writeShellScriptBin "layer-report" ''
          exec ${pkgs.python3}/bin/python3 ${./image/layer-report.py} "$@"
        '';
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
