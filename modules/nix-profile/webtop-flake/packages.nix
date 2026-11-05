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
  # The apply lock, the marker and the check below: ADR 0008.
  hash = builtins.hashFile "sha256" file;
  declared = "${config.xdg.configHome}/home-manager/packages.json";
  stateDir = "\${XDG_STATE_HOME:-$HOME/.local/state}/webtop";
  hmLocked = import ./home-manager-locked.nix { inherit pkgs; real = config.programs.home-manager.package; };
in
{
  # The webtop.* options live here too, so the starter flake needs no further import.
  imports = [ ./time-locale.nix ];

  # hiPrio: the locked home-manager replaces the real one in the profile.
  home.packages = lib.concatMap package (lib.attrValues (lib.importJSON file).elements)
    ++ [ (lib.hiPrio hmLocked) ];

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

  # Every activation holds the apply lock, however it was started, and its own lock, which a killed
  # holder of the apply lock does not release. The script runs again under flock (-o: nothing the
  # activation leaves running holds them); the pdeathsig stops it the moment its own holder is killed.
  home.activation.webtopLock = lib.hm.dag.entryBefore [ "writeBoundary" ] ''
    state="${stateDir}"
    if [ -z "''${WEBTOP_ACTIVATION_LOCKED:-}" ]; then
      mkdir -p "$state"
      holder=(${pkgs.util-linux}/bin/flock -o "$state/activation.lock" ${pkgs.util-linux}/bin/setpriv --pdeathsig KILL)
      if [ -z "''${WEBTOP_HM_LOCK_HELD:-}" ]; then
        holder=(${pkgs.util-linux}/bin/flock -o "$state/home-manager.lock" "''${holder[@]}")
      fi
      WEBTOP_HM_LOCK_HELD=1 WEBTOP_ACTIVATION_LOCKED=1 exec "''${holder[@]}" "$0" --driver-version "$hmDriverVersion"
    fi
    if [ ! -e "${declared}" ]; then
      echo "webtop: ${declared} does not exist: nix profile cannot change what this flake installs" >&2
    # Built from another packages.json than the file now: refuse, the next switch has the new one.
    # (The driver has already pointed the profile at this generation: put it back.)
    elif [ -z "''${WEBTOP_ACTIVATE_ANY:-}" ] \
      && [ "$(${pkgs.coreutils}/bin/sha256sum < "${declared}" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" != "${hash}" ]; then
      echo "webtop: this generation was built from another packages.json than ${declared}" >&2
      echo "webtop: if a package change raced it: run home-manager switch again" >&2
      echo "webtop: if this flake keeps its own packages.json: nix profile only works with the flake in ${dirOf declared}; move it there, or drop the packages module" >&2
      echo "webtop: to activate it anyway: home-manager switch --rollback, or WEBTOP_ACTIVATE_ANY=1 $0" >&2
      if (( hmDriverVersion >= 1 )) && [ -n "''${oldGenPath:-}" ] \
        && [ "$(readlink -f "$genProfilePath")" = "$(readlink -f "$newGenPath")" ]; then
        nix-env --profile "$genProfilePath" --set "$oldGenPath" > /dev/null 2>&1 || true
      fi
      exit 75
    fi
  '';

  # home-manager removes home-manager-path and then adds it again: for a moment the profile has no
  # home-manager and none of the declared packages. The patched Nix drops and adds it in one generation.
  # The rest is home-manager's own text; tests/nix-profile-concurrency.sh fails if that changes.
  home.activation.installPackages = lib.mkIf (!config.submoduleSupport.externalPackageInstall) (lib.mkForce (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      function nixReplaceProfile() {
        local oldNix="$(command -v nix)"

        if $oldNix config show profile-backend > /dev/null 2>&1; then
          # Under whatever name the profile has it (NIX_PROFILE_BACKEND: no declaration lock, ADR 0008).
          local name
          name=$(${pkgs.jq}/bin/jq -r '(.elements | if type == "array" then [] else to_entries end)[]
            | select(.value.storePaths // [] | any(test("-home-manager-path$"))) | .key' \
            ${config.home.profileDirectory}/manifest.json | head -n 1) || true
          run env NIX_PROFILE_BACKEND=activation $oldNix profile add --replace "''${name:-home-manager-path}" $1
        else
          nixProfileRemove 'home-manager-path'

          run $oldNix profile install $1
        fi
      }

      if [[ -e ${config.home.profileDirectory}/manifest.json ]] ; then
        INSTALL_CMD="nix profile install"
        INSTALL_CMD_ACTUAL="nixReplaceProfile"
        LIST_CMD="nix profile list"
        REMOVE_CMD_SYNTAX='nix profile remove {number | store path}'
      else
        INSTALL_CMD="nix-env -i"
        INSTALL_CMD_ACTUAL="run nix-env -i"
        LIST_CMD="nix-env -q"
        REMOVE_CMD_SYNTAX='nix-env -e {package name}'
      fi

      if ! $INSTALL_CMD_ACTUAL ${config.home.path} ; then
        echo
        _iError $'Oops, Nix failed to install your new Home Manager profile!\n\nPerhaps there is a conflict with a package that was installed using\n"%s"? Try running\n\n    %s\n\nand if there is a conflicting package you can remove it with\n\n    %s\n\nThen try activating your Home Manager configuration again.' "$INSTALL_CMD" "$LIST_CMD" "$REMOVE_CMD_SYNTAX"
        exit 1
      fi
      unset -f nixReplaceProfile
      unset INSTALL_CMD INSTALL_CMD_ACTUAL LIST_CMD REMOVE_CMD_SYNTAX
    ''));

  # What the active generation was built from, and which it is: the hook and the boot unit compare them
  # with the file and the profile, so a generation that never wrote this (an older one) does not match.
  # After every step that applies it: a kill before this must leave the retry something to do.
  home.activation.webtopApplied = lib.hm.dag.entryAfter [ "installPackages" "linkGeneration" "onFilesChange" "reloadSystemd" ] ''
    if [[ ! -v DRY_RUN ]]; then
      state="${stateDir}"
      mkdir -p "$state"
      echo "${hash} $newGenPath" > "$state/applied.tmp"
      mv "$state/applied.tmp" "$state/applied"
    fi
  '';
}
