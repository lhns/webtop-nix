{ callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "41d5560cbc01af14c83fcc9accb10b20cd37e983";
    hash = "sha256-OX1E+GH6TuOzF1f6rC+XWyTamOMo5Tc4KtDkrpEk+is=";
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
