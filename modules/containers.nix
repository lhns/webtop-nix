# Rootless Podman for the desktop user, with the docker CLI and compose (README, "Containers";
# ADR 0017). Works in an unprivileged container: what the runtime refuses is detected at boot.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.webtop;
  ccfg = cfg.containers;
  runtimeConf = "/run/webtop/containers-runtime.conf";

  # Stands in for crun where pivot_root is refused: containers fail with a pointer to the fix
  # instead of crun's bare EPERM. Everything but starting a container goes to crun.
  refusedRuntime = pkgs.writeShellScript "webtop-pivot-root-refused" ''
    for a in "$@"; do
      case $a in
        create|run)
          echo "webtop: this desktop's seccomp profile refuses pivot_root, which containers need. Run the desktop with seccomp/desktop.json from webtop-nix (README, \"Seccomp profile\"), or set services.webtop.containers.noPivotRoot (weaker isolation)." >&2
          exit 1 ;;
      esac
    done
    exec ${pkgs.crun}/bin/crun "$@"
  '';

  # Writes the containers.conf settings that depend on what the runtime grants. Each probe runs in a
  # fresh user namespace, as rootless Podman does; a seccomp filter answers EPERM.
  # Usage: webtop-containers-detect [--no-pivot-root] <out>
  detect = pkgs.writeShellScript "webtop-containers-detect" ''
    set -u
    PATH=${lib.makeBinPath [ pkgs.util-linux pkgs.keyutils pkgs.coreutils pkgs.gnugrep ]}
    noPivotRoot=
    [ "$1" != --no-pivot-root ] || { noPivotRoot=1; shift; }
    out=$1
    containers=() engine=() runtimes=()
    # pasta needs the tun device; without it only the host's network works, which is then the default.
    # -c first: <> would create a missing file.
    if ! { [ -c /dev/net/tun ] && : <> /dev/net/tun; } 2>/dev/null; then
      echo "webtop-containers: no usable /dev/net/tun: containers default to the host network"
      containers+=('netns = "host"')
    fi
    # Kubernetes' RuntimeDefault seccomp profile refuses pivot_root (seccomp/desktop.json allows it) and keyctl.
    if unshare -Urm pivot_root /nonexistent /nonexistent 2>&1 | grep -q 'Operation not permitted'; then
      if [ -n "$noPivotRoot" ]; then
        echo "webtop-containers: pivot_root is refused: containers start with chroot (noPivotRoot)"
        engine+=('no_pivot_root = true')
      else
        echo "webtop-containers: pivot_root is refused: containers cannot start; see README, \"Seccomp profile\""
        engine+=('runtime = "webtop-pivot-root-refused"')
        runtimes+=('webtop-pivot-root-refused = ["${refusedRuntime}"]')
      fi
    fi
    if ! unshare -Ur keyctl session - true >/dev/null 2>&1; then
      echo "webtop-containers: keyctl is refused: containers get no session keyring"
      containers+=('keyring = false')
    fi
    section() { [ $# -eq 1 ] || printf '%s\n' "$@"; }
    { section '[containers]' "''${containers[@]}"
      section '[engine]' "''${engine[@]}"
      section '[engine.runtimes]' "''${runtimes[@]}"; } > "$out.tmp"
    mv "$out.tmp" "$out"
  '';

  rangeType = lib.types.submodule {
    options = {
      start = lib.mkOption { type = lib.types.ints.positive; description = "First id."; };
      count = lib.mkOption { type = lib.types.ints.positive; description = "Number of ids."; };
    };
  };
  inRange = id: r: id >= r.start && id < r.start + r.count;
  declaredIds =
    lib.filter (x: x != null) (lib.mapAttrsToList (_: u: u.uid) config.users.users)
    ++ lib.filter (x: x != null) (lib.mapAttrsToList (_: g: g.gid) config.users.groups);
  clashes = lib.filter (id: lib.any (inRange id) ccfg.subIdRanges) declaredIds;
in
{
  options.services.webtop.containers = {
    enable = lib.mkEnableOption ''
      rootless Podman for the desktop user, with `docker` (Podman's docker-compatible CLI), `docker compose`
      (the docker-compose binary through Podman's API socket) and `DOCKER_HOST` set for the session'';

    noPivotRoot = lib.mkEnableOption ''
      starting containers with chroot where the desktop's seccomp profile refuses pivot_root (Kubernetes'
      RuntimeDefault). A fallback for where seccomp/desktop.json cannot be installed: a process that
      escapes a container's chroot has the desktop user's view and rights. Without it, containers fail
      there with a pointer to the profile'';

    subIdRanges = lib.mkOption {
      type = lib.types.listOf rangeType;
      default = [
        { start = cfg.uid + 1; count = 30000 - cfg.uid - 1; }
        { start = 32768; count = 61184 - 32768; }
      ];
      defaultText = lib.literalExpression ''
        [ { start = uid + 1; count = 30000 - uid - 1; } { start = 32768; count = 61184 - 32768; } ]'';
      description = ''
        The desktop user's subordinate uid and gid ranges: the ids its containers' users map to.
        The default fits a 65,536-id user namespace (a Kubernetes pod with `hostUsers: false`) and
        leaves out the ids in use there: system users, `nixbld` (30000 up), systemd's dynamic users
        (61184 up) and `nobody`. That is 57,415 ids, so an image file owned by a higher id (e.g.
        65534) is unpacked as root, and a container cannot switch to such an id. With a larger
        namespace (a VM, a host) one range of 65,536 above the system's ids is the usual choice.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && ccfg.enable) {
    assertions = [{
      assertion = clashes == [ ];
      message = "services.webtop.containers.subIdRanges include declared uids or gids: ${toString clashes}";
    }];

    virtualisation.podman = {
      enable = true;
      dockerCompat = true; # `docker` is Podman
    };

    users.users.${cfg.user} = {
      autoSubUidGidRange = false;
      subUidRanges = map (r: { startUid = r.start; inherit (r) count; }) ccfg.subIdRanges;
      subGidRanges = map (r: { startGid = r.start; inherit (r) count; }) ccfg.subIdRanges;
    };

    virtualisation.containers = {
      # The driver NixOS sets (overlay) keeps rootless Podman on native overlay in the home; left
      # unset, Podman falls back to fuse-overlayfs, and a pod has no /dev/fuse.
      # ignore_chown_errors: an image file owned by an id outside subIdRanges is unpacked as root
      # instead of failing the pull.
      storage.settings.storage.options.overlay.ignore_chown_errors = "true";
      containersConf.settings = {
        engine = {
          # Build contexts and image copies go below the storage (the home), not /var/tmp: an overlay
          # cannot use a container's own overlayfs root as its upper layer.
          image_copy_tmp_dir = "storage";
          compose_providers = [ "${pkgs.docker-compose}/bin/docker-compose" ];
          compose_warning_logs = false;
        };
      };
    };

    # image_copy_tmp_dir = "storage" is used as is: Podman does not create it.
    systemd.user.tmpfiles.rules = [ "d %h/.local/share/containers/storage/tmp 0700 - - -" ];

    environment.etc."containers/containers.conf.d/90-webtop-runtime.conf".source = runtimeConf;
    systemd.tmpfiles.rules = [ "d /run/webtop 0755 root root -" "f ${runtimeConf} 0644 root root -" ];
    systemd.services.webtop-containers-runtime = {
      description = "Detect what containers may use here (tun, pivot_root, keyctl)";
      wantedBy = [ "multi-user.target" ];
      before = [ "systemd-user-sessions.service" "user@${toString cfg.uid}.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${detect} ${lib.optionalString ccfg.noPivotRoot "--no-pivot-root "}${runtimeConf}";
      };
    };

    # The docker API for compose, IDEs and other clients: the user's Podman socket (socket-activated).
    environment.sessionVariables.DOCKER_HOST = "unix:///run/user/${toString cfg.uid}/podman/podman.sock";
  };
}
