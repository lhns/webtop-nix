# Lock: never a greeter, whether Lock is offered or not. Needs KVM to run; evaluates without.
# Off (the default): Lock is hidden and blocked, a lock that happens anyway is cleared. On
# (WEBTOP_LOCK_SCREEN=true from an env file, applied at the session start): a lock through logind or
# through the D-Bus call is recorded and cleared at once, the session and its processes untouched.
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "webtop-lock";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    services.webtop.lockEnvironmentFiles = [ "-/run/webtop-lock.env" ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    services.journald.storage = "persistent";
  };
  testScript = ''
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    marker = "/run/user/1000/webtop/lock"
    core = "kwin_wayland plasmashell kded6"
    session_pid = lambda: machine.succeed("systemctl show -p MainPID --value webtop-session.service").strip()
    restarted = lambda old: machine.wait_until_succeeds(f"test \"$(systemctl show -p MainPID --value webtop-session.service)\" -gt 0 && test \"$(systemctl show -p MainPID --value webtop-session.service)\" != {old}", timeout=120)
    # The user's graphical session: not its manager session (which cannot be locked), nor one still closing after a Log Out.
    def sid():
        rows = machine.succeed("for s in $(loginctl show-user user -p Sessions --value); do echo $s $(loginctl show-session $s -p Class --value) $(loginctl show-session $s -p State --value); done")
        found = [r.split()[0] for r in rows.splitlines() if r.split()[1:2] == ["user"] and r.split()[2:3] != ["closing"]]
        assert len(found) == 1, f"not one graphical session for user: {rows!r}"
        return found[0]
    # By argv[0], since the comm of a wrapped program is ".name-wrapped", cut to 15 characters.
    def pids():
        rows = [r.split(None, 1) for r in machine.succeed("ps -u user -o pid=,args=").splitlines() if len(r.split(None, 1)) == 2]
        name = lambda a: a.split()[0].rsplit("/", 1)[-1].lstrip(".").removesuffix("-wrapped")
        return {c: sorted(p for p, a in rows if name(a) == c) for c in core.split()}
    def diag():
        print(machine.execute(f"journalctl --no-pager -o cat -b | grep -E 'webtop-lock|kscreenlocker|ksld' | tail -40; {ubus} systemctl --user status webtop-lock-guard --no-pager -l; loginctl list-sessions; loginctl show-session {sid()} -p LockedHint")[1])
    def ready():
        machine.wait_for_unit("webtop-session.service")
        ${import ./wait-compositing.nix}
        # Processes are compared across a lock, and a Log Out before KWin and ksmserver are up is cancelled.
        ${import ./wait-session.nix}
        machine.wait_until_succeeds(f"{ubus} systemctl --user is-active webtop-lock-guard.service", timeout=60)
        # dbus-monitor must be attached before the first lock.
        machine.wait_until_succeeds("pgrep -u user -x dbus-monitor", timeout=60)
        machine.sleep(3)
    def settled():
        machine.wait_until_succeeds("! pgrep -f [k]screenlocker_greet", timeout=60)
        machine.wait_until_succeeds(f"{ubus} busctl --user call org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver GetActive | grep -qx 'b false'", timeout=60)
        assert machine.succeed(f"loginctl show-session {sid()} -p LockedHint --value").strip() == "no"
    # KDE's Lock (the D-Bus call) first: it is the one users reach.
    lockers = {
        "dbus": lambda: machine.succeed(f"{ubus} busctl --user call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver Lock"),
        "loginctl": lambda: machine.succeed(f"loginctl lock-session {sid()}"),
    }

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    ready()

    # Off: hidden and blocked; a lock that gets through is cleared all the same.
    machine.succeed("grep -qx 'action/lock_screen=false' /etc/xdg/kdeglobals")
    machine.succeed("grep -qx 'Autolock=false' /etc/xdg/kscreenlockerrc")
    for name, lock in lockers.items():
        lock()
        machine.sleep(5)
        try:
            settled()
        except Exception:
            print(name)
            diag()
            raise

    # On: written at the session start, so Log Out, as a user would.
    machine.succeed("echo WEBTOP_LOCK_SCREEN=true > /run/webtop-lock.env")
    old_session, old_kwin = session_pid(), set(pids()["kwin_wayland"])
    machine.succeed(f"{ubus} busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logout")
    restarted(old_session)
    retry(lambda _: bool(pids()["kwin_wayland"]) and not set(pids()["kwin_wayland"]) & old_kwin, 120)
    ready()
    machine.succeed("grep -qx 'action/lock_screen=true' /etc/xdg/kdeglobals")
    machine.succeed("grep -qx 'Autolock=false' /etc/xdg/kscreenlockerrc")
    machine.succeed("grep -qx 'LockOnResume=false' /etc/xdg/kscreenlockerrc")

    def locks_cleared():
        for name, lock in lockers.items():
            before = pids()
            assert all(before.values()), f"missing session processes: {before} " + machine.succeed("ps -u user -o pid=,args=")
            session = session_pid()
            machine.succeed(f"rm -f {marker}")
            lock()
            try:
                machine.wait_until_succeeds(f"grep -Eq '^[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}T[0-9:]+Z$' {marker}", timeout=60)
                settled()
            except Exception:
                print(name)
                diag()
                raise
            assert pids() == before, f"{name}: processes changed: {before} -> {pids()}"
            assert session_pid() == session
            machine.succeed(f"{ubus} systemctl --user is-active plasma-workspace.target")
    locks_cleared()

    # A bare restart of the session unit (as after a crash) takes Plasma down like Log Out, so KWin's
    # screen locker binds to the new logind session. Selkies and the guard keep running.
    keep = lambda: [machine.succeed(f"{ubus} systemctl --user show -p MainPID --value {u}").strip() for u in ("selkies.service", "webtop-lock-guard.service")]
    kept, old_session, old_kwin = keep(), session_pid(), set(pids()["kwin_wayland"])
    machine.succeed("systemctl restart webtop-session.service")
    restarted(old_session)
    ready()
    locks_cleared()
    assert not set(pids()["kwin_wayland"]) & old_kwin, "KWin was not restarted"
    assert keep() == kept, f"Selkies or the lock guard restarted: {kept} -> {keep()}"
  '';
}
