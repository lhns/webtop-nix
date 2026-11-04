{ callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "00f295d98f0f903d7badc4a729ef4324bf860211";
    hash = "sha256-m21IEdn8k4T7vAW0UZhRY8afsbl6bPGhShj7JLmj3CI=";
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
