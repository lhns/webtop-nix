{ callPackage, fetchFromGitHub }:

let
  src = fetchFromGitHub {
    owner = "lhns";
    repo = "nix-software-center";
    rev = "2b00d9797fcd19c1c34eb5788b1fd892d44226e0";
    hash = "sha256-XRp+kUKj3YbK1z0BA2rXZ2MkswQ+pBi+klbLVJQsn34=";
  };
  # Evaluated from the image's nixpkgs, which the flake registry's `nixpkgs` resolves to too.
  pkgdb = callPackage "${src}/nix/pkgdb.nix" { };
in
{
  nix-software-center-pkgdb = pkgdb;
  # Nix reports a missing network itself, so the egress policy need not allow nmcheck.gnome.org.
  nix-software-center = callPackage "${src}/default.nix" { inherit pkgdb; onlineCheckUrl = ""; };
}
