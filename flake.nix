{
  description = "Browser-streamed Plasma desktop on NixOS (Selkies + pixelflux + pcmflux)";

  # Consumers follow this nixpkgs (kube-webtop-workspaces: one Qt tree, and the image builder's skopeo).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # The image builder's layersFile (image/default.nix) is new upstream; bump deliberately.
  inputs.nix2container = {
    url = "github:nlewo/nix2container/535166ecac3fcdff43787aa958dd7e954770581d";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # The nixProfile module (ADR 0006): the users' home-manager flakes resolve it from the image's registry.
  inputs.home-manager = {
    url = "github:nix-community/home-manager";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  # Upstream global flake registry, baked in with the image's own pins.
  inputs.flake-registry = {
    url = "github:NixOS/flake-registry";
    flake = false;
  };

  outputs = { self, nixpkgs, nix2container, home-manager, flake-registry }:
    let
      # Supported systems; CI builds each one natively, in a matrix.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f system (import nixpkgs { inherit system; overlays = [ self.overlays.default ]; }));

      # A system using the module with the software center, for the checks; never built whole by them.
      moduleSystem = system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.webtop
          {
            services.webtop.enable = true;
            services.webtop.softwareCenter.enable = true;
            services.webtop.nixProfile.enable = true;
            boot.loader.grub.enable = false;
            fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
            system.stateVersion = "25.11";
          }
        ];
      };

      # The container module with every option on, for the checks (the storeOverlay needs mounts only
      # an entrypoint makes, so no test boots it).
      containerSystem = system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.webtop
          self.nixosModules.container
          {
            services.webtop = {
              enable = true;
              nixProfile.enable = true;
              sudo.enable = true;
              storeOverlay.enable = true;
              journalRelay.enable = true;
              adminTools.enable = true;
            };
            system.stateVersion = "26.05";
          }
        ];
      };

      imageLib = system: import ./image { nix2container = nix2container.packages.${system}.nix2container; };
      # The standalone image's system; also the reference other images' layers are classified by.
      standalone = nixpkgs.lib.genAttrs systems (system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ self.nixosModules.webtop self.nixosModules.container ./image/container.nix ];
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
        inherit (pkgs) pixelflux pcmflux selkies webtop-app-screen nix-software-center nix-software-center-pkgdb;
        kwin = pkgs.kwinSoftwarePresentation;
        # `nix profile` with backends (services.webtop.nixProfile); CI caches it like KWin.
        nix-profile-backends = nixpkgs.legacyPackages.${system}.callPackage ./modules/nix-profile/nix { };
        nixpkgs-unfree-flake = import ./modules/nix-profile/nixpkgs-unfree.nix { inherit (pkgs) runCommand; inherit nixpkgs; };
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
        webtop.imports = [
          ./modules/webtop.nix
          ./modules/restore-progress.nix
          (import ./modules/nix-profile { inherit nixpkgs home-manager flake-registry; })
        ];
        # The desktop as a container (README, "Container module"); beside `webtop`.
        container = ./modules/container.nix;
        default = self.nixosModules.webtop;
      };

      checks = forAllSystems (system: pkgs: {
        # Evaluates a system using the module, without building it.
        module-eval =
          let sys = moduleSystem system; in
          pkgs.writeText "module-eval" (builtins.unsafeDiscardStringContext sys.config.system.build.toplevel.drvPath);
        # The container module's options, evaluated and asserted on: the overlay store reaches the daemon only.
        container-eval =
          let
            sys = containerSystem system;
            c = sys.config;
          in
          assert (nixpkgs.lib.hasPrefix "store = local-overlay://" c.systemd.services.nix-daemon.environment.NIX_CONFIG) || throw "storeOverlay: NIX_CONFIG";
          assert (c.nix.settings.store == "daemon") || throw "storeOverlay: store";
          assert (builtins.elem "wheel" c.users.users.user.extraGroups && !c.security.sudo.wheelNeedsPassword) || throw "sudo";
          assert (c.systemd.services.webtop-journal-relay.serviceConfig.ExecStart != "") || throw "journalRelay";
          assert (c.systemd.user.services.drkonqi-coredump-pickup.serviceConfig.RuntimeMaxSec == "infinity") || throw "drkonqi";
          pkgs.writeText "container-eval" (builtins.unsafeDiscardStringContext c.system.build.toplevel.drvPath);
        inherit (self.packages.${system}) pixelflux pcmflux selkies nix-software-center nix-software-center-pkgdb;
        included-manifest = import ./tests/included-manifest.nix { inherit pkgs; sys = moduleSystem system; pkgdb = pkgs.nix-software-center-pkgdb; };
        vm = import ./tests/vm.nix { inherit pkgs self; };
        relogin = import ./tests/relogin.nix { inherit pkgs self; };
        lock = import ./tests/lock.nix { inherit pkgs self; };
        second-display = import ./tests/second-display.nix { inherit pkgs self; };
        app-screens = import ./tests/app-screens.nix { inherit pkgs self; };
        latest-owner = import ./tests/latest-owner.nix { inherit pkgs self; };
      });
    };
}
