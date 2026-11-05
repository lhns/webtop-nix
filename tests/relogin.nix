# Log Out, Shut down and repeated logouts of the Plasma session. Needs KVM to run; evaluates without.
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "webtop-relogin";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    services.journald.storage = "persistent";
    # Stands in for an environment's power hook: it must still see the stop.
    systemd.services.power-hook = {
      wantedBy = [ "poweroff.target" ];
      before = [ "poweroff.target" "shutdown.target" ];
      conflicts = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      script = "echo power-hook-ran > /var/lib/power-hook; logger -t power-hook stop/user";
    };
  };
  testScript = ''
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    pid = lambda unit: machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()
    selkies_pid = lambda: machine.succeed(f"{ubus} systemctl --user show -p MainPID --value selkies.service").strip()
    logout = lambda: machine.succeed(f"{ubus} busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logout")
    # The session is only logout-able once plasma-workspace.target is up (ksmserver, plasmashell).
    ready = lambda: machine.wait_until_succeeds(f"{ubus} systemctl --user is-active plasma-workspace.target plasma-ksmserver.service plasma-plasmashell.service", timeout=180)
    def diag():
        print(machine.execute(f"systemctl status webtop-session.service --no-pager -l; {ubus} systemctl --user list-units --no-pager 'plasma-*' 'app-*'; ps -eo pid,ppid,etime,cmd | grep -E 'plasma|kwin|ksm' | head -30")[1])

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_unit("webtop-session.service")
    ${import ./wait-compositing.nix}
    selkies = selkies_pid()

    # Log Out exits the session unit with 0; it must come back with a compositor, Selkies untouched.
    for i in range(3):
        ready()
        old = pid("webtop-session.service")
        logout()
        try:
            machine.wait_until_succeeds(f"test \"$(systemctl show -p MainPID --value webtop-session.service)\" -gt 0 && test \"$(systemctl show -p MainPID --value webtop-session.service)\" != {old}", timeout=120)
        except Exception:
            diag()
            raise
        machine.wait_for_unit("webtop-session.service")
        ${import ./wait-compositing.nix}
        assert selkies_pid() == selkies, "Selkies was restarted by the logout"
        machine.wait_for_open_port(8082)
        machine.succeed("curl -sf http://localhost:8082/ | grep -qi '<html'")

    # Still inside the start limit.
    assert machine.succeed("systemctl show -p ActiveState --value webtop-session.service").strip() == "active"
    assert machine.succeed("systemctl show -p Result --value webtop-session.service").strip() == "success"
    machine.succeed("journalctl -u webtop-session.service | grep -c 'Scheduled restart job' | grep -qv '^0$'")

    # Shut down from Plasma: logout plus poweroff. The hook runs and the session is not restarted.
    machine.succeed(f"{ubus} busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logoutAndShutdown")
    machine.wait_for_shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("grep -q power-hook-ran /var/lib/power-hook")
    j = machine.succeed("journalctl -b -1 -o short-monotonic --no-pager").splitlines()
    mark = next(n for n, l in enumerate(j) if "power-hook" in l and "stop/user" in l)
    late = [l for l in j[mark:] if "webtop-session" in l and ("Scheduled restart job" in l or "Started" in l)]
    assert not late, "session restarted during shutdown: " + repr(late)
  '';
}
