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

  # Pinned to 3.13, the Python these are built and tested with (the selkies wheel itself is pure Python).
  pixelflux = final.python313Packages.pixelflux;
  pcmflux = final.python313Packages.pcmflux;
  selkies = final.python313Packages.toPythonApplication final.python313Packages.selkies;
}
