# Software installation from one declaration (ADR 0006): the patched `nix profile` records packages in
# ~/.config/home-manager/packages.json, which the `webtop` flake's module installs with home-manager.
# A starter flake is created on first boot and its generation prebuilt into the image.
{ nixpkgs, home-manager, flake-registry }:
{ config, lib, pkgs, ... }:

let
  webtop = config.services.webtop;
  cfg = webtop.nixProfile;
  uid = toString webtop.uid;
  system = pkgs.stdenv.hostPlatform.system;
  # toFile, not replaceVars: home.nix is also imported below, which needs a plain path (no IFD).
  render = vars: name: builtins.toFile name (lib.replaceStrings
    (map (n: "@${n}@") (lib.attrNames vars)) (lib.attrValues vars)
    (builtins.readFile ./starter/${name}));
  # @user@ and @home@ are the login name, known only at runtime.
  runtimeFile = render { inherit system; inherit (config.system) stateVersion; };
  stateDir = "${cfg.homeStoragePath}/.local/state/webtop";
  notice = "${stateDir}/home-manager-notice";
  # What the scripts take from the module, ahead of their text.
  withHome = file: "home=${cfg.homeStoragePath}\n" + builtins.readFile file;
  templateTool = pkgs.writeShellApplication {
    name = "webtop-template";
    runtimeInputs = with pkgs; [ coreutils diffutils gnugrep gnused ];
    text = withHome ./webtop-template.sh;
  };
  # The `webtop` flake: a store path in the registry, like nixpkgs. Users' flake.lock files name it:
  # its directory name and bytes decide that path, and a change makes every home relock and switch.
  webtopFlake = ./webtop-flake;
  # Registry entry `nixpkgs-unfree`: like `webtop`, a store path whose name and bytes decide it.
  unfreeFlake = import ./nixpkgs-unfree.nix { inherit (nixpkgs.legacyPackages.${system}) runCommand; inherit nixpkgs; };
  pinned = [ "nixpkgs" "home-manager" "webtop" "nixpkgs-unfree" ];
  template = home-manager.lib.homeManagerConfiguration {
    pkgs = nixpkgs.legacyPackages.${system};
    modules = [
      (render { inherit system; inherit (config.system) stateVersion; user = webtop.user; home = "/home/${webtop.user}"; } "home.nix")
      (import ./webtop-flake/packages.nix ./starter/packages.json)
    ];
  };
  hmPackage = home-manager.packages.${system}.home-manager;
  notify = pkgs.writeShellApplication {
    name = "webtop-notify";
    runtimeInputs = with pkgs; [ coreutils util-linux libnotify ];
    text = "uid=${uid}\n" + builtins.readFile ./webtop-notify.sh;
  };
  # profile-hook (the packages module): applies a changed packages.json.
  profileHook = pkgs.writeShellApplication {
    name = "webtop-profile-hook";
    runtimeInputs = [ pkgs.coreutils pkgs.git config.nix.package hmPackage ];
    text = builtins.readFile ./webtop-profile-hook.sh;
  };
  setup = pkgs.writeShellApplication {
    name = "webtop-home-manager";
    runtimeInputs = with pkgs; [ coreutils jq git config.nix.package hmPackage notify cfg.progress ];
    # In the text, not the unit: a consumer's unit may run this script too.
    text = "WEBTOP_FLAKE=${webtopFlake}\n" + builtins.readFile ./webtop-home-manager.sh;
  };
  reinstall = pkgs.writeShellApplication {
    name = "webtop-nix-reinstall";
    runtimeInputs = with pkgs; [ coreutils gnused jq config.nix.package notify cfg.progress ];
    text = "WEBTOP_SETUP=${lib.getExe setup}\n" + builtins.readFile ./webtop-nix-reinstall.sh;
  };
  updateTool = pkgs.writeShellApplication {
    name = "webtop-home-manager-update";
    runtimeInputs = with pkgs; [ coreutils diffutils git config.nix.package templateTool hmPackage ];
    text = withHome ./webtop-home-manager-update.sh;
  };
  upstream = lib.importJSON "${flake-registry}/flake-registry.json";
in
{
  options.services.webtop.nixProfile = {
    enable = lib.mkEnableOption ''
      software installation from one declaration: `nix profile` (patched, built from source) records
      packages in home-manager's packages.json, and a starter flake is kept current in the user's home.
      Needs a persistent home to be of use'';

    homeStoragePath = lib.mkOption {
      type = lib.types.str;
      default = "/home/${webtop.user}";
      defaultText = lib.literalExpression ''"/home/''${config.services.webtop.user}"'';
      description = ''
        The home's path on its storage, when it is reached through other paths too. templates.sha256
        keys files by it: changing it on an existing home makes unmodified starter flakes look edited.
      '';
    };

    progress = lib.mkOption {
      type = lib.types.package;
      default = pkgs.writeShellScriptBin "webtop-restore-progress" ''
        if [ "''${1:-}" = nixconfig ]; then printf '%s' "''${NIX_CONFIG:-}"; fi
      '';
      defaultText = "a no-op";
      description = ''
        Provides `webtop-restore-progress current TEXT`, called before a switch, and
        `webtop-restore-progress nixconfig`, which prints the NIX_CONFIG for that switch.
      '';
    };

    reinstall = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = reinstall;
      description = ''
        `webtop-nix-reinstall MANIFEST`, as the user, for what an image update took from the store:
        dangling generations move aside, the old profile's flake packages come back from MANIFEST, then
        the setup script. Exit 0 only if all of it worked. Without a file at MANIFEST it reinstalls nothing.
      '';
    };

    fromImageStore = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        The store is the image's alone, so the home outlives it: every boot runs the reinstall without
        a manifest ahead of the switch. Off for a consumer that runs the reinstall after its own restore.
      '';
    };

    notify = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = notify;
      description = "`webtop-notify TITLE BODY [ICON]`: a notification in the session, for other units.";
    };
  };

  config = lib.mkIf (webtop.enable && cfg.enable) {
    # One way to install software: Discover has no Nix backend on NixOS. Plasma's "Get New…" dialogs stay.
    environment.plasma6.excludePackages = [ pkgs.kdePackages.discover ];
    # The starter is a flake; the patched `nix profile` needs both.
    nix.settings.experimental-features = [ "nix-command" "flakes" ];
    # CLI and modules from one source; the template's `home-manager` input resolves to it.
    nix.registry.home-manager.flake = home-manager;
    nix.registry.webtop.to = { type = "path"; path = "${webtopFlake}"; };
    nix.registry.nixpkgs-unfree.to = { type = "path"; path = "${unfreeFlake}"; };
    # Flake inputs resolve indirect refs through the global registry only, not nix.registry, so the
    # image's pins replace the upstream global registry's entries for them (offline, no download).
    nix.settings.flake-registry = pkgs.writeText "flake-registry.json" (builtins.toJSON {
      version = 2;
      flakes = map (id: { from = { type = "indirect"; inherit id; }; to = config.nix.registry.${id}.to; }) pinned
        ++ lib.filter (e: !lib.elem e.from.id pinned) upstream.flakes;
    });
    # webtop-template: also for other units that update files the image wrote into the home.
    environment.systemPackages = [ hmPackage templateTool updateTool profileHook ];
    # The starter template for webtop-template render and webtop-home-manager-update.
    environment.etc."webtop/home-manager/flake.nix".source = runtimeFile "flake.nix";
    environment.etc."webtop/home-manager/home.nix".source = runtimeFile "home.nix";
    environment.etc."webtop/home-manager/packages.json".source = ./starter/packages.json;

    # Not `pkgs`: this Nix must not depend on overlays of the consumer's system.
    nix.package = nixpkgs.legacyPackages.${system}.callPackage ./nix { };

    # The generation and news file of the unchanged template for the default account. Another login
    # name reuses their closure; only the few derivations carrying the name are built.
    system.extraDependencies = [ template.activationPackage template.config.news.json.output ];

    # Creates the starter flake once and keeps it on the current template and login name while it is
    # unmodified (webtop-home-manager-template.sh). When it writes, the setup unit below switches.
    systemd.services.webtop-home-manager-template = {
      description = "Create or rename the starter home-manager flake";
      wantedBy = [ "multi-user.target" ];
      before = [ "webtop-session.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = uid;
        # USER and HOME come from passwd: the login name and /home/<name>.
        ExecStart = lib.getExe (pkgs.writeShellApplication {
          name = "webtop-home-manager-template";
          runtimeInputs = with pkgs; [ coreutils diffutils gnugrep gnused templateTool ];
          text = withHome ./webtop-home-manager-template.sh;
        });
      };
    };

    # The notification for the above (title, then text), once Plasma (its notification server) is up.
    systemd.services.webtop-home-manager-notice = {
      description = "Tell the user what to do about their home-manager flake";
      wantedBy = [ "multi-user.target" ];
      after = [ "webtop-session.service" "webtop-home-manager-template.service" ];
      unitConfig.ConditionPathExists = notice;
      environment.WEBTOP_NOTIFY_TRIES = "24"; # Plasma may take a while after the session starts
      serviceConfig = {
        Type = "exec"; # not oneshot: multi-user.target must not wait for the session
        User = uid;
        ExecStart = lib.getExe (pkgs.writeShellApplication {
          name = "webtop-home-manager-notice";
          runtimeInputs = with pkgs; [ coreutils notify ];
          text = ''
            echo "notifying: $(head -n1 ${notice})"
            webtop-notify "$(head -n1 ${notice})" \
              "$(tail -n +2 ${notice}) See: journalctl -u webtop-home-manager-template" dialog-warning
          '';
        });
      };
    };

    # Relock and switch (webtop-home-manager.sh), after the template unit.
    systemd.services.webtop-home-manager = {
      description = "Bring the user's home-manager setup to the image's";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      # nix-daemon.service too: at shutdown the daemon must outlive a switch the stop waits for.
      after = [ "network-online.target" "nix-daemon.socket" "nix-daemon.service" "webtop-session.service" "webtop-home-manager-template.service" ];
      environment = {
        DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/${uid}/bus";
        XDG_RUNTIME_DIR = "/run/user/${uid}";
      };
      serviceConfig = {
        # Not oneshot: multi-user.target would wait for a switch.
        Type = "exec";
        User = uid;
        ExecStart = if cfg.fromImageStore then "${lib.getExe reinstall} /nonexistent" else lib.getExe setup;
        # Whatever stops the system must allow for this.
        TimeoutStopSec = "5min";
      };
    };
  };
}
