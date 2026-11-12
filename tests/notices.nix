# The notice channel (ADR 0019): files in /run/webtop/notices become notifications. Needs KVM to run; evaluates without.
# The notification calls are read off the session bus; a click is a signal sent by hand, since a VM
# test cannot press the button. The restart itself is stubbed (services.webtop.notices.restartCommand).
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "webtop-notices";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    services.webtop.notices.restartCommand = "${pkgs.coreutils}/bin/touch /tmp/notices-restart";
    environment.systemPackages = [ pkgs.dbus ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    services.journald.storage = "persistent";
  };
  testScript = ''
    import json, shlex
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    notices = "/run/webtop/notices"
    mon = "/tmp/notices-mon.log"
    state = "/run/user/1000/webtop/notices"

    def put(name, content):
        # Temp name, then rename: a half-written file is never read.
        data = content if isinstance(content, str) else json.dumps(content)
        machine.succeed(f"printf '%s' {shlex.quote(data)} > {notices}/.{name}.tmp && mv {notices}/.{name}.tmp {notices}/{name}.json")

    def seen(text, count=1):
        machine.wait_until_succeeds(f"test \"$(grep -cF -- {shlex.quote(text)} {mon})\" -ge {count}", timeout=60)

    def notify_count(text):
        return int(machine.succeed(f"grep -cF -- {shlex.quote(text)} {mon} || true").strip())

    def entry(name):
        # The state file is written just after the notification is sent.
        return machine.wait_until_succeeds(f"cat {state}/*/{name}", timeout=30).split()

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_unit("webtop-session.service")
    ${import ./wait-compositing.nix}
    ${import ./wait-session.nix}
    machine.wait_for_unit("webtop-notices.service", "user")
    machine.wait_until_succeeds(f"{ubus} busctl --user status org.freedesktop.Notifications", timeout=60)

    # The server renders body markup and links, which is why the body is escaped (the summary is plain text).
    caps = machine.succeed(f"{ubus} busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications GetCapabilities")
    assert "body-markup" in caps and "body-hyperlinks" in caps and "actions" in caps, caps
    # Plasma's Restart is a D-Bus service that can be started on demand.
    machine.succeed(f"{ubus} busctl --user list --activatable --no-legend | grep -q '^org.kde.LogoutPrompt '")

    # The directory is root's: the desktop user cannot forge a notice.
    machine.fail(f"runuser -u user -- touch {notices}/forged.json")

    machine.succeed(f"systemd-run --unit=notices-mon --uid=user -p StandardOutput=file:{mon} --setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus dbus-monitor --session \"interface='org.freedesktop.Notifications'\"")
    machine.sleep(2)

    # A file becomes a notification; markup and links in the body arrive escaped, the summary as is.
    put("update-pending", {"title": "Updates are ready", "body": "Restart <a href=\"http://example.invalid\">now</a> & go", "action": "restart"})
    seen('string "Updates are ready"')
    seen("&lt;a href=")
    seen("&amp; go")
    machine.fail(f"grep -F '<a href' {mon}")
    seen('string "restart"')
    seen('string "Restart"')
    h, nid, dismissed, action = entry("update-pending")
    assert dismissed == "0" and action == "restart", (h, nid, dismissed, action)

    # The action: the stub runs. Anyone on the bus can send this signal; the action is only Plasma's confirmed restart.
    machine.succeed(f"{ubus} busctl --user emit /org/freedesktop/Notifications org.freedesktop.Notifications ActionInvoked us {nid} restart")
    machine.wait_until_succeeds("test -e /tmp/notices-restart", timeout=30)

    # Dismissed stays dismissed: not on another notice, not on a rescan, not when the watcher restarts.
    machine.succeed(f"{ubus} busctl --user emit /org/freedesktop/Notifications org.freedesktop.Notifications NotificationClosed uu {nid} 2")
    machine.wait_until_succeeds(f"cat {state}/*/update-pending | grep -q ' 1 restart$'", timeout=30)
    put("dash", {"title": "- Maintenance tonight", "body": "--help"})
    seen('string "- Maintenance tonight"')
    seen('string "--help"')
    put("plain", {"title": "Tom & Jerry", "body": "low", "urgency": "low", "action": "open-url"})
    seen('string "Tom & Jerry"')
    assert entry("plain")[3:] == [], "an unknown action gets no button"
    machine.succeed(f"{ubus} systemctl --user restart webtop-notices.service")
    machine.wait_until_succeeds(f"{ubus} systemctl --user is-active webtop-notices.service", timeout=30)
    machine.sleep(5)
    assert notify_count('string "Updates are ready"') == 1, "a dismissed notice came back"

    # Changed content shows again, in place.
    put("update-pending", {"title": "Updates are ready", "body": "Second text", "action": "restart"})
    seen('string "Second text"')
    machine.wait_until_succeeds(f"cat {state}/*/update-pending | grep -q ' 0 restart$'", timeout=30)
    assert entry("update-pending")[1] == nid

    # A removed file withdraws its notification.
    machine.succeed(f"rm {notices}/update-pending.json")
    seen("member=CloseNotification")
    machine.wait_until_succeeds(f"! ls {state}/*/update-pending", timeout=30)

    # Bad files are skipped; the watcher goes on.
    put("broken", "{not json")
    put("wrong", {"title": 1, "body": "x"})
    put("urgent", {"title": "Bad urgency", "body": "x", "urgency": "loud"})
    machine.succeed(f"head -c 20000 /dev/urandom | base64 -w0 > {notices}/big.json")
    put("after", {"title": "Still running", "body": "fine", "urgency": "critical"})
    seen('string "Still running"')
    assert notify_count('string "Bad urgency"') == 0
    assert machine.succeed(f"{ubus} systemctl --user show -P NRestarts webtop-notices.service").strip() == "0"
    machine.succeed("journalctl --user -u webtop-notices -o cat 2>/dev/null | grep -q 'broken.json skipped' || journalctl -b -o cat | grep -q 'broken.json skipped'")
  '';
}
