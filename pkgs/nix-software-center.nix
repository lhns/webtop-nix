{ callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "623edc3daa7229558a4f1cc62f94ca4a0572869c";
    hash = "sha256-rcLDYxNs8+KkKbNDK4QbcyQOG8kNTIM8dceSzdFF6gw=";
  };
  # Evaluated from the image's nixpkgs, which the flake registry's `nixpkgs` resolves to too.
  pkgdb = callPackage "${src}/nix/pkgdb.nix" { };
in
{
  nix-software-center-pkgdb = pkgdb;
  # Nix reports a missing network itself, so the egress policy need not allow nmcheck.gnome.org.
  nix-software-center = callPackage "${src}/default.nix" { inherit pkgdb; onlineCheckUrl = ""; };
}
