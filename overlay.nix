final: prev: {
  pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
    (pyFinal: pyPrev: {
      pixelflux = pyFinal.callPackage ./pkgs/pixelflux.nix { };
      pcmflux = pyFinal.callPackage ./pkgs/pcmflux.nix { };
      # inherit: python3Packages has its own (removed) `mesa` alias.
      selkies = pyFinal.callPackage ./pkgs/selkies.nix { inherit (final) mesa; };
    })
  ];

  # Not kdePackages.kwin itself: overriding that would rebuild everything that depends on it.
  kwinSoftwarePresentation = final.callPackage ./pkgs/kwin.nix { };

  webtop-app-screen = final.callPackage ./pkgs/app-screen { };

  # Default Python of the nixpkgs in use.
  pixelflux = final.python3Packages.pixelflux;
  pcmflux = final.python3Packages.pcmflux;
  selkies = final.python3Packages.toPythonApplication final.python3Packages.selkies;
}
