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
              # The extension points (README, "Extension points").
              sessionEnvironmentFiles = [ "-/run/test/session.env" ];
              sessionStopCommands = [ "+/run/test/session-stop" ];
              sessionConfKeys = [ "testKey" "otherKey" ];
              nixProfile.templateEnvironmentFiles = [ "-/run/test/template.env" ];
              sleep.environmentFiles = [ "-/run/test/sleep.env" ];
              sleep.hooks = [ "/run/test/sleep-hook" ];
            };
            # Direct unit overrides of an older consumer, in the shapes it used; they must still merge.
            systemd.services.webtop-session.serviceConfig = {
              EnvironmentFile = [ "-/run/test/legacy.env" ];
              ExecStopPost = [ "+/run/test/legacy-stop" ];
            };
            systemd.services.webtop-home-manager-template.serviceConfig.EnvironmentFile = "-/run/test/legacy-template.env";
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
        inherit (pkgs) pixelflux pcmflux selkies webtop-app-screen webtop-power nix-software-center nix-software-center-pkgdb;
        kwin = pkgs.kwinSoftwarePresentation;
        kguiaddons = pkgs.kguiaddonsClipboardFix;
        # `nix profile` with backends (services.webtop.nixProfile); CI caches it like KWin.
        nix-profile-backends = nixpkgs.legacyPackages.${system}.callPackage ./modules/nix-profile/nix { };
        nixpkgs-unfree-flake = import ./modules/nix-profile/nixpkgs-unfree.nix { inherit (pkgs) runCommand; inherit nixpkgs; };
        default = pkgs.selkies;

        # docker run-able desktop (README, "Image"); its own closure is the layer reference.
        image =
          let
            sys = standalone.${system};
            toplevel = sys.config.system.build.toplevel;
            rootfs = pkgs.runCommand "rootfs" { } ''
              mkdir -p $out/sbin $out/etc $out/run $out/tmp $out/var $out/persist $out/home $out/proc $out/sys $out/dev
              chmod 1777 $out/tmp
              ln -s ${toplevel}/init $out/sbin/init
            '';
            # The shebang is a static busybox: it runs before /nix/store is overlaid.
            entrypoint = pkgs.runCommand "webtop-entrypoint" { } ''
              mkdir -p $out
              substitute ${./image/webtop-entrypoint} $out/webtop-entrypoint \
                --subst-var-by busybox ${pkgs.pkgsStatic.busybox} \
                --subst-var-by storeInit ${sys.config.services.webtop.storeOverlay.init} \
                --subst-var-by sysPower ${sys.config.services.webtop.sleep.init}
              chmod +x $out/webtop-entrypoint
            '';
            # Identifies the image's store (the overlay's lower): webtop-nix-lower compares it with the
            # stamp on the volume. It lives outside /nix so busybox can read it before the overlay is
            # mounted. Over paths and NAR hashes: a path rebuilt with other bytes is a change too.
            lowerClosure = pkgs.closureInfo { rootPaths = [ toplevel entrypoint rootfs ]; };
            stamp = pkgs.runCommand "webtop-image-stamp" { } ''
              mkdir -p $out
              sha256sum ${lowerClosure}/registration | cut -d' ' -f1 > $out/webtop-image-stamp
            '';
          in
          (imageLib system).buildImage {
            name = "ghcr.io/lhns/webtop-nix";
            tag = "dev";
            nixos = sys;
            copyToRoot = [ rootfs entrypoint stamp ];
            config = {
              Entrypoint = [ "/webtop-entrypoint" ];
              StopSignal = "SIGRTMIN+3";
              Env = [ "container=docker" "PATH=/run/current-system/sw/bin:/run/wrappers/bin" ];
              ExposedPorts."8082/tcp" = { };
              # The store overlay's upper layer and Nix state (README, "Store overlay"); docker makes an
              # anonymous volume when none is mounted.
              Volumes."/persist" = { };
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
          # Outside a container Sleep is systemd's and nothing saves the session (ADR 0012).
          assert (sys.config.services.webtop.sleep.mode == "systemd" && !sys.config.services.webtop.sessionSave.enable
            && !(sys.config.systemd.services ? webtop-session-save) && sys.config.services.webtop.nixProfile.fromImageStore) || throw "non-container defaults";
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
          # Extension points: the module's own stop first, then the consumer's; lists merge with older overrides.
          assert (let
            s = c.systemd.services.webtop-session.serviceConfig;
            own = nixpkgs.lib.remove "+/run/test/legacy-stop" s.ExecStopPost;
          in
            nixpkgs.lib.hasSuffix "/bin/webtop-stop-session" (builtins.head own)
            && builtins.tail own == [ "+/run/test/session-stop" ]
            && builtins.elem "+/run/test/legacy-stop" s.ExecStopPost
            && nixpkgs.lib.sort (a: b: a < b) s.EnvironmentFile == [ "-/run/test/legacy.env" "-/run/test/session.env" ]
            && nixpkgs.lib.hasInfix "'testKey otherKey'" (builtins.head s.ExecStartPre)) || throw "session extension points";
          assert (nixpkgs.lib.sort (a: b: a < b) c.systemd.services.webtop-home-manager-template.serviceConfig.EnvironmentFile
            == [ "-/run/test/legacy-template.env" "-/run/test/template.env" ]) || throw "templateEnvironmentFiles";
          # Sleep and the session save (ADR 0012): the container defaults, keyed on boot.isContainer in webtop.nix.
          assert (c.services.webtop.sleep.mode == "freeze" && c.services.webtop.sessionSave.enable) || throw "container power defaults";
          assert (let u = c.systemd.services.systemd-suspend; in
            nixpkgs.lib.hasSuffix "/bin/webtop-power suspend" (nixpkgs.lib.last u.serviceConfig.ExecStart)
            && builtins.head u.serviceConfig.ExecStart == ""
            && u.serviceConfig.EnvironmentFile == [ "-/run/test/sleep.env" ]
            && u.environment.WEBTOP_SUSPEND_MODE == "freeze" && u.environment.WEBTOP_HTTP_PORT == "8082"
            && u.serviceConfig.TimeoutStartSec == "infinity") || throw "sleep unit";
          assert (c.systemd.sleep.settings.Sleep.AllowHibernation == "no") || throw "hibernation off";
          assert (let s = c.systemd.services.webtop-session-save; in
            nixpkgs.lib.hasSuffix "/bin/webtop-power thaw" (builtins.head s.serviceConfig.ExecStop)
            && nixpkgs.lib.hasPrefix "+" (builtins.head s.serviceConfig.ExecStop)
            && nixpkgs.lib.hasSuffix "/bin/webtop-power save-session" (builtins.elemAt s.serviceConfig.ExecStop 1)
            && builtins.elem "webtop-session.service" s.after) || throw "session save unit";
          # The overlay's layout on the volume is what the former code made (tests/store-overlay-layout-test.sh).
          assert (c.services.webtop.storeOverlay.persistPath == "/persist/nix"
            && c.services.webtop.storeOverlay.upperLayer == "/persist/nix/upper"
            && c.services.webtop.storeOverlay.lowerRoot == "/.lower") || throw "overlay layout";
          assert (!c.services.webtop.nixProfile.fromImageStore
            && c.systemd.services.webtop-home-manager.unitConfig.ConditionPathExists == "!/persist/nix/reinstall/pending"
            && c.systemd.services.webtop-nix-restore.unitConfig.ConditionPathExists == "/persist/nix/reinstall/restore"
            && c.systemd.services.webtop-nix-trash.unitConfig.ConditionPathExistsGlob == "/persist/nix/trash-*"
            && builtins.elem "webtop-nix-reinstall.service" c.systemd.services.webtop-home-manager-template.before
            && nixpkgs.lib.hasSuffix " /persist/nix/reinstall/user.manifest.json" c.systemd.services.webtop-nix-reinstall.serviceConfig.ExecStart) || throw "restore units";
          pkgs.writeText "container-eval" (builtins.unsafeDiscardStringContext c.system.build.toplevel.drvPath);
        inherit (self.packages.${system}) pixelflux pcmflux selkies webtop-power nix-software-center nix-software-center-pkgdb;
        # The overlay's layout on the volume, run on the scripts as built (busybox alone on PATH).
        store-overlay-layout =
          let init = standalone.${system}.config.services.webtop.storeOverlay.init;
          in pkgs.runCommand "store-overlay-layout" { } ''
            bash ${./tests/store-overlay-layout-test.sh} ${init} ${pkgs.pkgsStatic.busybox}
            touch $out
          '';
        power = import ./tests/power.nix { inherit pkgs self; };
        included-manifest = import ./tests/included-manifest.nix { inherit pkgs; sys = moduleSystem system; pkgdb = pkgs.nix-software-center-pkgdb; };
        vm = import ./tests/vm.nix { inherit pkgs self; };
        defaults = import ./tests/defaults.nix { inherit pkgs self; };
        relogin = import ./tests/relogin.nix { inherit pkgs self; };
        lock = import ./tests/lock.nix { inherit pkgs self; };
        second-display = import ./tests/second-display.nix { inherit pkgs self; };
        app-screens = import ./tests/app-screens.nix { inherit pkgs self; };
        latest-owner = import ./tests/latest-owner.nix { inherit pkgs self; };
      });
    };
}
