{ callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "204ed518354aa53277d6786551b1579eebc8910b";
    hash = "sha256-Cd+VIJR83AZrYgEPfCnqzryTwxuU2wWhScLmVBO3n5Q=";
  };
  # Evaluated from the image's nixpkgs, which the flake registry's `nixpkgs` resolves to too.
  pkgdb = callPackage "${src}/nix/pkgdb.nix" { };
in
{
  nix-software-center-pkgdb = pkgdb;
  # Nix reports a missing network itself, so the egress policy need not allow nmcheck.gnome.org.
  # Image-based desktop: no system packages, and unfree apps install through the `nixpkgs-unfree` registry flake.
  nix-software-center = callPackage "${src}/default.nix" {
    inherit pkgdb;
    onlineCheckUrl = "";
    systemPackages = false;
    unfreeFlake = "nixpkgs-unfree";
  };
}
