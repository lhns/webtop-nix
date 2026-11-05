# Installs what the given packages.json declares and points `nix profile` at ~/.config/home-manager's
# copy, so `nix profile add`, `remove`, `upgrade` and `rollback` edit it and switch. Without this
# module, `nix profile` is stock.
file:
{ config, lib, pkgs, ... }:

let
  system = pkgs.stdenv.hostPlatform.system;
  # "a.b.\"c.d\"" -> [ "a" "b" "c.d" ]: quoted segments may contain dots.
  attrPath = e: map (m: lib.removePrefix "\"" (lib.removeSuffix "\"" (lib.head m)))
    (lib.filter lib.isList (builtins.split ''("[^"]*"|[^."]+)'' e.attrPath));
  # Nix records names with dots unquoted: at each level, take the shortest name that exists.
  getPath = set: segs:
    if segs == [ ] then set
    else
      let
        name = n: lib.concatStringsSep "." (lib.take n segs);
        n = lib.findFirst (k: set ? ${name k}) null (lib.range 1 (lib.length segs));
      in
      if n == null then throw "packages.json: no attribute '${lib.concatStringsSep "." segs}'"
      else getPath set.${name n} (lib.drop n segs);
  # The packages of a nixpkgs set, from the attr path of the flake's `legacyPackages.<system>.` outputs.
  fromSet = set: e:
    let p = attrPath e;
    in getPath set (if lib.length p > 2 && lib.elemAt p 1 == system then lib.drop 2 p else p);
  # flake:nixpkgs entries use this configuration's nixpkgs (the image's); flake:nixpkgs-unfree the same
  # with unfree allowed, rebuilt here: its locked store path may be gone after an image update.
  fromNixpkgs = fromSet pkgs;
  unfree = import pkgs.path { inherit system; config.allowUnfree = true; };
  fromUnfree = fromSet unfree;
  # Others use their locked flake.
  package = e:
    let
      original = e.originalUrl or "";
      drv = if original == "flake:nixpkgs" then fromNixpkgs e
        else if original == "flake:nixpkgs-unfree" then fromUnfree e
        else getPath (builtins.getFlake e.url) (attrPath e);
      outputs = e.outputs or null;
      selected = if outputs == null then [ drv ]
        else map (o: drv.${o}) (if lib.elem "*" outputs then drv.outputs else outputs);
    in map (lib.setPrio (e.priority or 5)) selected;
in
{
  home.packages = lib.concatMap package (lib.attrValues (lib.importJSON file).elements);

  # Every install switches, and home-manager would notify about all its unread news on the desktop.
  news.display = lib.mkDefault "silent";

  # Not nix.settings: home-manager validates those with nix.package, which would have to be the
  # image's patched Nix, and its nix.conf would replace this one.
  assertions = [{
    assertion = config.nix.settings == { } && config.nix.extraOptions == "";
    message = "the webtop packages module writes ~/.config/nix/nix.conf: put further Nix settings into its text, or drop the module.";
  }];
  xdg.configFile."nix/nix.conf".text = ''
    profile-backend = declaration:${config.xdg.configHome}/home-manager/packages.json
    profile-hook = /run/current-system/sw/bin/webtop-profile-hook
  '';
}
