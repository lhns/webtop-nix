{ callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "27b1ee200b73043239cc8f580946e62c380c6366";
    hash = "sha256-ymWnytdZsQxD8YnpMklBSWhIvkOxzuPprAM72NvBt4E=";
  };
  # Evaluated from the image's nixpkgs, which the flake registry's `nixpkgs` resolves to too.
  pkgdb = callPackage "${src}/nix/pkgdb.nix" { };
in
{
  inherit pkgdb;
  # Nix reports a missing network itself, so the egress policy need not allow nmcheck.gnome.org.
  app = callPackage "${src}/default.nix" { inherit pkgdb; onlineCheckUrl = ""; };
}
