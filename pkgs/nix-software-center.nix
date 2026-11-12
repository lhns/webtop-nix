{ callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "d156edc733c54844ea226b5698dc163f04109c22";
    hash = "sha256-EC+WGET+59BjUuHuj6CBLVpGUmhWAxslbsT5wAZzmJg=";
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
