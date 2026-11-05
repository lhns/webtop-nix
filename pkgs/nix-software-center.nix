{ lib, callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "36128b11c151cad3d76468ea9eea4320a48e7fe1";
    hash = "sha256-UyBapnCOBZh/l3C22oxv3xkkOaiRzlC25f1tVTupsqM=";
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
