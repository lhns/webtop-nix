# Containers for the desktop user (README, "Containers"): `docker run`, `docker build` and
# `docker compose up --build` against rootless Podman, with networking, a published port, a bind mount,
# a memory limit and the configured subordinate ids; then the fallbacks the boot-time detection chooses
# without /dev/net/tun and under a seccomp filter refusing pivot_root and keyctl (Kubernetes'
# RuntimeDefault). Offline: the image is built here. Needs KVM to run; evaluates without.
{ pkgs, self }:

let
  testbox = pkgs.dockerTools.buildImage {
    name = "localhost/testbox";
    tag = "latest";
    copyToRoot = pkgs.buildEnv { name = "testbox-root"; paths = [ pkgs.busybox ]; pathsToLink = [ "/bin" ]; };
    config.Cmd = [ "/bin/sh" ];
  };
  dockerfile = pkgs.writeText "Dockerfile" ''
    FROM localhost/testbox
    RUN mkdir /www && echo compose-ok > /www/index.html && echo built > /built
  '';
  compose = pkgs.writeText "compose.yaml" ''
    services:
      web:
        build: .
        command: ["httpd", "-f", "-p", "8080", "-h", "/www"]
      client:
        image: localhost/testbox
        depends_on: [web]
        command: ["sh", "-c", "for i in $$(seq 60); do wget -q -O- http://web:8080/ && exit 0; sleep 1; done; exit 1"]
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-containers";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    services.webtop.containers.enable = true;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;
  };
  testScript = { nodes, ... }: ''
    import shlex
    detect = "${nodes.machine.systemd.services.webtop-containers-runtime.serviceConfig.ExecStart}".split()[0]
    env = "export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus;"
    # A login shell, so DOCKER_HOST comes from the session environment as in a terminal.
    def u(cmd, ok=True):
        full = f"runuser -l user -c {shlex.quote(env + ' ' + cmd)}"
        return machine.succeed(full) if ok else machine.fail(full)

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("webtop-containers-runtime.service")
    machine.wait_for_unit("podman.socket", "user")
    host_net = machine.succeed("readlink /proc/1/ns/net")

    with subtest("configuration"):
        assert machine.succeed("cat /etc/subuid").split() == ["user:1001:28999", "user:32768:28416"], machine.succeed("cat /etc/subuid")
        assert machine.succeed("cat /etc/subgid").split() == ["user:1001:28999", "user:32768:28416"]
        assert u("echo $DOCKER_HOST").strip() == "unix:///run/user/1000/podman/podman.sock"
        # Nothing refused in a VM: no fallback settings.
        assert machine.succeed("cat /run/webtop/containers-runtime.conf").strip() == ""
        u("docker load -i ${testbox}")
        u("curl -sf --unix-socket /run/user/1000/podman/podman.sock http://d/_ping | grep -qx OK")
        info = u("podman info --format '{{.Store.GraphDriverName}} {{.Store.GraphRoot}} {{.Host.NetworkBackend}}'")
        assert info.split() == ["overlay", "/home/user/.local/share/containers/storage", "netavark"], info
        assert "mount_program" not in u("podman info --format '{{.Store.GraphOptions}}'")

    with subtest("docker run"):
        out = u("docker run --rm localhost/testbox sh -c 'id -u; cat /proc/self/uid_map'")
        assert out.split() == ["0", "0", "1000", "1", "1", "1001", "28999", "29000", "32768", "28416"], out
        # Its own network namespace (pasta), not the host's.
        assert u("docker run --rm localhost/testbox readlink /proc/self/ns/net") != host_net
        u("docker run --rm localhost/testbox sh -c 'mkdir /x && chown 40000 /x'")
        mem = u("docker run --rm --memory 64m localhost/testbox cat /sys/fs/cgroup/memory.max").strip()
        assert mem == "67108864", mem

    with subtest("bind mount"):
        u("mkdir -p ~/bm && echo hi > ~/bm/in")
        assert u("docker run --rm -v ~/bm:/bm localhost/testbox sh -c 'cat /bm/in; echo out > /bm/out'").strip() == "hi"
        assert machine.succeed("stat -c %U /home/user/bm/out").strip() == "user"

    with subtest("published port"):
        u("mkdir -p ~/www && echo port-ok > ~/www/index.html")
        u("docker run -d --name web -p 18080:8080 -v ~/www:/www localhost/testbox httpd -f -p 8080 -h /www")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:18080/ | grep -qx port-ok", timeout=60)
        u("docker rm -f web")

    with subtest("docker build"):
        u("mkdir -p ~/proj && cp ${dockerfile} ~/proj/Dockerfile && cp ${compose} ~/proj/compose.yaml")
        u("docker build -t localhost/built ~/proj")
        assert u("docker run --rm localhost/built cat /built").strip() == "built"

    with subtest("docker compose"):
        out = u("cd ~/proj && docker compose up --build --abort-on-container-exit --exit-code-from client 2>&1")
        assert "compose-ok" in out, out
        u("cd ~/proj && docker compose down")

    with subtest("no tun: the host network"):
        machine.succeed("mv /dev/net/tun /dev/net/tun.off && systemctl restart webtop-containers-runtime")
        assert 'netns = "host"' in machine.succeed("cat /run/webtop/containers-runtime.conf")
        assert u("docker run --rm localhost/testbox readlink /proc/self/ns/net") == host_net
        u("docker build --no-cache -t localhost/built-host ~/proj")
        machine.succeed("mv /dev/net/tun.off /dev/net/tun && systemctl restart webtop-containers-runtime")

    with subtest("seccomp refuses pivot_root and keyctl"):
        machine.succeed(f"systemd-run --wait --pipe -p SystemCallFilter='~pivot_root keyctl' -p SystemCallErrorNumber=EPERM {detect} /run/webtop/containers-runtime.conf")
        conf = machine.succeed("cat /run/webtop/containers-runtime.conf")
        assert "no_pivot_root = true" in conf and "keyring = false" in conf, conf
        # Containers start with those settings.
        assert u("docker run --rm localhost/testbox echo started").strip() == "started"
        machine.succeed("systemctl restart webtop-containers-runtime")
  '';
}
