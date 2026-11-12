# The admin's system.nix (ADR 0016): a NixOS module the image's own configuration is rebuilt with, booted
# at the next start by the entrypoint. Part of the `container` module; on with `defaults.system.flake`.
{ config, lib, pkgs, ... }:

let
  webtop = config.services.webtop;
  cfg = webtop.defaults.system;
  # A GC root on the volume (/nix/var/nix is the overlay's `var`); the key beside it names what it was built for.
  profile = "/nix/var/nix/profiles/webtop-defaults-system";
  notice = "/run/webtop/defaults-notice"; # shown by webtop-defaults-notice.service (nixProfile)

  # Every locked input's source, so the rebuild finds them in the image's store. Not the flake's
  # own outPath: evaluated from `source`, that is `source`, and the system must come out the same.
  inputSources = flake: lib.concatMap (i: [ i.outPath ] ++ inputSources i) (lib.attrValues (flake.inputs or { }));

  # The graft's replacements as built (ADR 0004): the image otherwise holds the patched KWin only
  # rewritten, and a rebuild reads the references of the original, which would compile it. A cutoff
  # keeps this list, and so their closures, out of the graft's rewrite (about 180 MiB).
  graftSources = pkgs.writeText "webtop-graft-sources"
    (lib.concatMapStrings (r: "${r.newDependency}\n") config.system.replaceDependencies.replacements);

  build = pkgs.writeShellApplication {
    name = "webtop-defaults-system";
    runtimeInputs = [ pkgs.coreutils config.nix.package config.systemd.package ];
    text = builtins.readFile ./defaults-system/webtop-defaults-system.sh;
  };

  boot = pkgs.runCommand "webtop-defaults-boot" { } ''
    mkdir -p $out/bin
    substitute ${./defaults-system/webtop-defaults-boot} $out/bin/webtop-defaults-boot \
      --subst-var-by busybox ${pkgs.pkgsStatic.busybox} \
      --subst-var-by profile ${profile} \
      --subst-var-by source ${lib.escapeShellArg webtop.defaults.source}
    chmod +x $out/bin/webtop-defaults-boot
  '';
in
{
  options.services.webtop.defaults.system = {
    flake = lib.mkOption {
      type = lib.types.nullOr lib.types.raw;
      default = null;
      example = lib.literalExpression "self";
      description = ''
        The flake whose `nixosConfigurations.<name>` is this system. Set, the admin's `system.nix` in the
        defaults directory is a NixOS module this configuration is rebuilt with (`extendModules`), and the
        entrypoint boots the result at the next start (README, "Admin defaults"). The flake's source and
        its inputs' sources go into the image, so the rebuild does not fetch them.
      '';
    };
    source = lib.mkOption {
      type = lib.types.str;
      default = cfg.flake.outPath;
      defaultText = lib.literalExpression "flake.outPath";
      description = ''
        The flake's source as kept in the image. A filtered copy (`lib.fileset.toSource`) keeps changes to
        files the configuration does not read (docs) from changing the image.
      '';
    };
    name = lib.mkOption {
      type = lib.types.str;
      description = "The attribute of `nixosConfigurations` that is this system.";
    };
    boot = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = boot;
      defaultText = "a static busybox script";
      description = ''
        `bin/webtop-defaults-boot`, for an entrypoint to exec in place of `/sbin/init`, after
        `storeOverlay.init`: execs the system built from `system.nix` if it was built for this image (its
        `/webtop-image-stamp`) and for the `system.nix` now in `defaults.source`, else `/sbin/init`. The
        source must be readable before systemd (a mount, not `environment.etc`).
      '';
    };
  };

  config = lib.mkIf (cfg.flake != null) {
    assertions = [{
      assertion = webtop.storeOverlay.enable;
      message = "services.webtop.defaults.system needs services.webtop.storeOverlay: the built system lives in the store on the volume";
    }];

    system.extraDependencies = lib.unique ([ cfg.source graftSources ] ++ inputSources cfg.flake);
    system.replaceDependencies.cutoffPackages = [ graftSources ];

    # Not oneshot: multi-user.target must not wait for a build. Applies at the next start only.
    systemd.services.webtop-defaults-system = {
      description = "Build the system with the admin's system.nix for the next start";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" "webtop-defaults.service" ];
      after = [ "network-online.target" "nix-daemon.socket" "webtop-defaults.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.escapeShellArgs [ (lib.getExe build) "/run/webtop/defaults" profile cfg.source cfg.name notice ];
        Nice = 19;
        IOSchedulingClass = "idle";
        # The evaluation takes about 1.5 GB; a module that needs far more must not take the desktop with it.
        MemoryMax = "4G";
        RuntimeMaxSec = "2h";
        TimeoutStopSec = 10;
      };
    };
  };
}
