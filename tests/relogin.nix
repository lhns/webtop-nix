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
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/true";
        ExecStop = pkgs.writeShellScript "power-hook" "echo stop/user >> /var/lib/power-hook";
      };
    };
  };
  testScript = ''
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    pid = lambda unit: machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()
    selkies_pid = lambda: machine.succeed(f"{ubus} systemctl --user show -p MainPID --value selkies.service").strip()
    logout = lambda: machine.succeed(f"{ubus} busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logout")
    def ready():
        ${import ./wait-session.nix}
    restarted = lambda old: machine.wait_until_succeeds(f"test \"$(systemctl show -p MainPID --value webtop-session.service)\" -gt 0 && test \"$(systemctl show -p MainPID --value webtop-session.service)\" != {old}", timeout=120)
    def diag():
        print(machine.execute(f"systemctl status webtop-session.service --no-pager -l; {ubus} systemctl --user list-units --no-pager 'plasma-*' 'app-*'; ps -eo pid,ppid,etime,cmd | grep -E 'plasma|kwin|ksm' | head -30; journalctl -b --no-pager -o short-monotonic | grep -E 'transaction|startplasma|plasma-shutdown' | tail -20")[1])

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
            restarted(old)
        except Exception:
            diag()
            raise
        machine.wait_for_unit("webtop-session.service")
        ${import ./wait-compositing.nix}
        assert selkies_pid() == selkies, "Selkies was restarted by the logout"
        machine.wait_for_open_port(8082)
        machine.succeed("curl -sf http://localhost:8082/ | grep -qi '<html'")

    # Log Out in the first seconds of a session, while start jobs are still queued: Plasma's own stop
    # (mode "fail") is refused then, and the next session must still come up whole. The bus names are
    # still waited for: before KWin's /Session exists a Log Out is cancelled, not hung.
    early = 0
    for i in range(3):
        ready()
        old = pid("webtop-session.service")
        logout()
        restarted(old)
        machine.wait_until_succeeds(f"{ubus} busctl --user status org.kde.KWin >/dev/null && {ubus} busctl --user status org.kde.ksmserver >/dev/null && {ubus} busctl --user status org.kde.plasmashell >/dev/null && {ubus} busctl --user introspect org.kde.KWin /Session >/dev/null", timeout=180)
        jobs = machine.succeed(f"{ubus} systemctl --user list-jobs --no-legend").strip()
        early += bool(jobs)
        print(f"early logout {i}, queued jobs: {jobs!r}")
        old = pid("webtop-session.service")
        logout()
        try:
            restarted(old)
            ${import ./wait-compositing.nix}
            ready()
        except Exception:
            diag()
            raise
    assert early, "no Log Out happened while start jobs were queued"
    assert selkies_pid() == selkies, "Selkies was restarted by a logout"

    # A crash of the session process takes Plasma down too; the next start brings a new KWin.
    kwin = lambda: machine.succeed(f"{ubus} systemctl --user show -p MainPID --value plasma-kwin_wayland.service").strip()
    old, old_kwin = pid("webtop-session.service"), kwin()
    machine.succeed(f"kill -9 {old}")
    restarted(old)
    ${import ./wait-compositing.nix}
    ready()
    assert kwin() not in ("0", old_kwin), "KWin survived the crash of the session"
    # Each new session started at once: none raced the previous one's teardown.
    machine.fail("journalctl -b -u webtop-session.service | grep 'Could not start Plasma session'")

    # Still inside the start limit.
    assert machine.succeed("systemctl show -p ActiveState --value webtop-session.service").strip() == "active"
    assert machine.succeed("systemctl show -p Result --value webtop-session.service").strip() == "success"
    machine.succeed("journalctl -u webtop-session.service | grep -c 'Scheduled restart job' | grep -qv '^0$'")

    # Shut down from Plasma: logout plus poweroff. The hook runs and the session is not restarted.
    machine.succeed(f"{ubus} busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logoutAndShutdown")
    machine.wait_for_shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("grep -qx stop/user /var/lib/power-hook")
    j = machine.succeed("journalctl -b -1 -o short-monotonic --no-pager").splitlines()
    marks = [n for n, l in enumerate(j) if "poweroff requested" in l]
    assert marks, "no poweroff request in the previous boot"
    late = [l for l in j[marks[0]:] if "webtop-session" in l and ("Scheduled restart job" in l or "Started" in l)]
    assert not late, "session restarted during shutdown: " + repr(late)
    assert not [l for l in j if "user jobs still queued" in l], "the session's teardown held up the shutdown"
  '';
}
