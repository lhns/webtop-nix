# The `nixpkgs-unfree` registry flake (nixpkgs-unfree-flake/) with a lock file naming the image's nixpkgs:
# a store-path flake cannot be locked at use, and an unlocked one makes `nix profile add` fail.
{ runCommand, nixpkgs }:
let
  lock = builtins.toJSON {
    version = 7;
    root = "root";
    nodes = {
      root.inputs.nixpkgs = "nixpkgs";
      nixpkgs = {
        locked = { type = "path"; path = "${nixpkgs}"; inherit (nixpkgs) narHash lastModified; };
        original = { type = "indirect"; id = "nixpkgs"; };
      };
    };
  };
in
runCommand "nixpkgs-unfree-flake" { } ''
  mkdir $out
  cp ${./nixpkgs-unfree-flake/flake.nix} $out/flake.nix
  cp ${builtins.toFile "flake.lock" lock} $out/flake.lock
''
