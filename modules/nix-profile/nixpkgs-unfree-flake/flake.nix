# Registry entry `nixpkgs-unfree`: the image's nixpkgs with unfree packages allowed, so `nix profile add
# nixpkgs-unfree#pkg` needs no --impure. Deliberately no lock file and no other config.
{
  inputs.nixpkgs.url = "nixpkgs";

  outputs = { nixpkgs, ... }: {
    legacyPackages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
      import nixpkgs { inherit system; config.allowUnfree = true; });
  };
}
