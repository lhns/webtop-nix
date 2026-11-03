final: prev: {
  pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
    (pyFinal: pyPrev: {
      # inherit: python3Packages has its own (removed) `mesa` alias.
      pixelflux = pyFinal.callPackage ./pkgs/pixelflux.nix { inherit (final) mesa; };
      pcmflux = pyFinal.callPackage ./pkgs/pcmflux.nix { };
      selkies = pyFinal.callPackage ./pkgs/selkies.nix { };
    })
  ];

  # Not kdePackages.kwin itself: overriding that would rebuild everything that depends on it.
  kwinSoftwarePresentation = final.callPackage ./pkgs/kwin.nix { };

  webtop-app-screen = final.callPackage ./pkgs/app-screen { };

  # The index is its own derivation so the image layering can group it with the nixpkgs paths.
  nix-software-center-pkgdb = (final.callPackage ./pkgs/nix-software-center.nix { }).pkgdb;
  nix-software-center = (final.callPackage ./pkgs/nix-software-center.nix { }).app;

  # Default Python of the nixpkgs in use.
  pixelflux = final.python3Packages.pixelflux;
  pcmflux = final.python3Packages.pcmflux;
  selkies = final.python3Packages.toPythonApplication final.python3Packages.selkies;
}
