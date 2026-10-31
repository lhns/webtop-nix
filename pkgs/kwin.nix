# KWin with LinuxServer's software-presentation patch: without a GPU, a nested KWin 6.8 renders
# with llvmpipe into memfd buffers and presents them to the host over wl_shm (6.8 dropped QPainter).
# Only adds functions to libkwin, so the module grafts this over the stock kwin
# (services.webtop.kwinSoftwarePresentation) instead of rebuilding its dependents.
{ lib, kdePackages }:

let
  stock = kdePackages.kwin;
in
assert lib.assertMsg (lib.versions.majorMinor (lib.getVersion stock) == "6.8")
  "pkgs/kwin.nix: the patch targets KWin 6.8.x, nixpkgs has ${lib.getVersion stock}; set services.webtop.kwinSoftwarePresentation = false on Plasma 6.7 or refresh the patch";
stock.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    ./kwin/kwin-6.8-software-shm-presentation.patch
    ./kwin/kwin-6.8-shm-presentation-finish.patch
  ];
})
