final: prev: {
  pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ]) ++ [
    (pyFinal: pyPrev: {
      pixelflux = pyFinal.callPackage ./pkgs/pixelflux.nix { };
      pcmflux = pyFinal.callPackage ./pkgs/pcmflux.nix { };
      # inherit: python3Packages has its own (removed) `mesa` alias.
      selkies = pyFinal.callPackage ./pkgs/selkies.nix { inherit (final) mesa; };
    })
  ];

  # Pinned to 3.13: the wheels below are cp313.
  pixelflux = final.python313Packages.pixelflux;
  pcmflux = final.python313Packages.pcmflux;
  selkies = final.python313Packages.toPythonApplication final.python313Packages.selkies;
}
