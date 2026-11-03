# Image builder (ADR 0005): nix2container, with layers split from the image's own closure by
# split-layers.py, stable at the bottom and volatile at the top.
{ nix2container }:

rec {
  # Groups in assignment order; a path joins the first whose candidates hold it. Anchors are out
  # paths of the system's own packages; an anchor not in the closure is reported, not an error.
  # Stack groups ("reference" scope) take only paths of the reference image, so a consumer's own
  # packages land in its own groups instead of reshuffling these.
  stackGroups = nixos:
    let
      c = nixos.config;
      p = nixos.pkgs;
      k = p.kdePackages;
      inherit (p.lib) getLib;
      # By name: the KWin graft rewrites system-path, so its out path is not in the closure.
      sp = [ "name:system-path" ];
    in
    [
      { name = "base"; anchors = [ p.glibc p.stdenv.cc.cc.lib c.systemd.package p.coreutils p.bashInteractive
          p.util-linux c.nix.package p.python3 p.perl p.openssl p.dbus ]; }
      { name = "toolkits"; buckets = 6; anchors = [ c.hardware.graphics.package k.qtbase k.qtdeclarative
          k.qtwebengine k.qtmultimedia (getLib p.libsForQt5.qtbase) p.gtk3 p.gtk4 (getLib p.ffmpeg)
          (getLib p.gst_all_1.gstreamer)
          p.gst_all_1.gst-plugins-base p.gst_all_1.gst-plugins-good p.gst_all_1.gst-plugins-bad
          c.services.pipewire.package c.services.pipewire.wireplumber.package ]; }
      { name = "data"; buckets = 2; anchors = c.fonts.packages ++ [ k.breeze-icons k.oxygen-icons
          p.hicolor-icon-theme p.adwaita-icon-theme k.plasma-workspace-wallpapers c.i18n.glibcLocales
          p.xkeyboard_config p.tzdata p.cacert p.isocodes p.shared-mime-info p.mobile-broadband-provider-info
          p.sound-theme-freedesktop k.ocean-sound-theme p.hwdata ]; }
      # The nixpkgs source NixOS registers for flakes (nixpkgs.flake.source).
      # The software center's index is rebuilt on each nixpkgs bump, so it goes here.
      { name = "nixpkgs"; anchors = p.lib.optional (c.nixpkgs.flake.source != null) c.nixpkgs.flake.source
          ++ [ p.nix-software-center-pkgdb ]; }
      { name = "firefox"; anchors = [ (c.programs.firefox.package.unwrapped or p.firefox-unwrapped) ]; }
      { name = "webtop"; anchors = [ c.services.webtop.package p.webtop-app-screen ]; }
      # The packages system.replaceDependencies rewrote (ADR 0004); their stock paths are not in the
      # closure. Any scope: a consumer with its own nix.package gets its own rewrites (reported).
      { name = "graft"; scope = "any"; refsOf = sp; dependentsOf = [ p.kwinSoftwarePresentation ]; sameAsReference = true; }
      { name = "kde"; buckets = 4; refsOf = sp; }
    ];

  # Stable to volatile. A consumer's groups follow; "packages" and "config" are always the last two.
  stackOrder = [ "base" "toolkits" "data" "nixpkgs" "kde" "firefox" "webtop" "graft" ];

  # nix2container layersFile for the closure of `nixos`'s toplevel, plus table.txt and groups.json.
  # extraGroups: the consumer's own groups ("own" scope by default), e.g. sources it bakes in.
  # reference: store-paths file of the reference image; null classifies by this closure alone.
  splitLayers = { nixos, extraGroups ? [ ], reference ? null, maxConfigMiB ? 128 }:
    let
      p = nixos.pkgs;
      # Strings only: an anchor must not become a build input.
      paths = map (d: builtins.unsafeDiscardStringContext (toString d));
      norm = g: g // p.lib.mapAttrs (_: paths) (p.lib.filterAttrs (n: _: builtins.elem n [ "anchors" "refsOf" "dependentsOf" ]) g);
      own = map (g: { scope = "own"; } // g) extraGroups;
      spec = {
        groups = map norm (stackGroups nixos ++ own ++ [ { name = "packages"; scope = "own"; refsOf = [ "name:system-path" ]; } ]);
        layerOrder = stackOrder ++ map (g: g.name) own ++ [ "packages" ];
        inherit maxConfigMiB;
      };
      closure = p.closureInfo { rootPaths = [ nixos.config.system.build.toplevel ]; };
    in
    p.runCommand "image-layers" {
      nativeBuildInputs = [ p.python3 ];
      spec = builtins.toJSON spec;
      passAsFile = [ "spec" ];
    } ''
      mkdir $out
      python3 ${./split-layers.py} ${closure}/registration "$specPath" $out \
        ${p.lib.optionalString (reference != null) "--reference ${reference}"}
    '';

  # Store paths of an image's system, for use as another image's reference.
  referencePaths = nixos: "${nixos.pkgs.closureInfo { rootPaths = [ nixos.config.system.build.toplevel ]; }}/store-paths";

  # A nix2container image of `nixos`'s toplevel: the split layers, then the image's own layer
  # (copyToRoot and the Nix DB). Every layer path is in the toplevel's closure (layersFile allows
  # nothing else), so the image's store is that closure plus what copyToRoot references.
  buildImage = { name, tag ? null, nixos, copyToRoot ? [ ], config ? { }, extraGroups ? [ ], reference ? null
    , maxConfigMiB ? 128, initializeNixDatabase ? true }:
    let
      layerSplit = splitLayers { inherit nixos extraGroups reference maxConfigMiB; };
      image = nix2container.buildImage {
        inherit name tag copyToRoot config initializeNixDatabase;
        layers = [ (nix2container.buildLayer {
          deps = [ nixos.config.system.build.toplevel ];
          layersFile = "${layerSplit}/layers.json";
        }) ];
      };
    in
    image // { inherit layerSplit; };
}
