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
    # The user's graphical session, not its manager session (which cannot be locked). Without a VT it is "online", not "active".
    sid = lambda: machine.succeed("for s in $(loginctl show-user user -p Sessions --value); do [ \"$(loginctl show-session $s -p Class --value)\" = user ] && echo $s || true; done | head -n1").strip()
    pids = lambda: {c: machine.succeed(f"pgrep -u user -x {c} | sort | tr '\n' ' '").strip() for c in core.split()}
    def diag():
        print(machine.execute(f"journalctl --no-pager -o cat -b | grep -E 'webtop-lock|kscreenlocker|ksld' | tail -40; ps -eo pid,cmd | grep -E 'greet|dbus-monitor'; {ubus} systemctl --user status webtop-lock-guard --no-pager -l; loginctl show-session {sid()} -p LockedHint -p Id; loginctl list-sessions; for s in $(loginctl show-user user -p Sessions --value); do loginctl show-session $s -p Id -p Class -p State -p Seat; done")[1])
    def ready():
        machine.wait_for_unit("webtop-session.service")
        ${import ./wait-compositing.nix}
        machine.wait_until_succeeds(f"{ubus} systemctl --user is-active plasma-workspace.target plasma-ksmserver.service plasma-plasmashell.service", timeout=180)
        machine.wait_until_succeeds(f"{ubus} systemctl --user is-active webtop-lock-guard.service", timeout=60)
        # dbus-monitor must be attached before the first lock.
        machine.wait_until_succeeds("pgrep -u user -x dbus-monitor", timeout=60)
        machine.sleep(3)
    def settled():
        machine.wait_until_succeeds("! pgrep -f kscreenlocker_greet", timeout=60)
        machine.wait_until_succeeds(f"{ubus} busctl --user call org.freedesktop.ScreenSaver /org/freedesktop/ScreenSaver org.freedesktop.ScreenSaver GetActive | grep -qx 'b false'", timeout=60)
        assert machine.succeed(f"loginctl show-session {sid()} -p LockedHint --value").strip() == "no"
    lockers = {
        "loginctl": lambda: machine.succeed(f"loginctl lock-session {sid()}"),
        "dbus": lambda: machine.succeed(f"{ubus} busctl --user call org.freedesktop.ScreenSaver /ScreenSaver org.freedesktop.ScreenSaver Lock"),
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
            diag()
            raise

    # On: written at the session start, so restart it.
    machine.succeed("echo WEBTOP_LOCK_SCREEN=true > /run/webtop-lock.env")
    machine.succeed("systemctl restart webtop-session.service")
    ready()
    machine.succeed("grep -qx 'action/lock_screen=true' /etc/xdg/kdeglobals")
    machine.succeed("grep -qx 'Autolock=false' /etc/xdg/kscreenlockerrc")
    machine.succeed("grep -qx 'LockOnResume=false' /etc/xdg/kscreenlockerrc")

    for name, lock in lockers.items():
        before = pids()
        assert all(before.values()), f"missing session processes: {before}"
        session = machine.succeed("systemctl show -p MainPID --value webtop-session.service").strip()
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
        assert machine.succeed("systemctl show -p MainPID --value webtop-session.service").strip() == session
        machine.succeed(f"{ubus} systemctl --user is-active plasma-workspace.target")

  '';
}
