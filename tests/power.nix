# Sleep freezes the session and an external stop saves it (ADR 0012). Needs KVM to run; evaluates without.
# The units are started directly (`systemd-suspend.service`, `webtop-session-save.service`): logind's
# own checks for Sleep are the distro's, the units are this repo's. Ends with a Sleep that powers off.
{ pkgs, self }:

let
  py = pkgs.python3.withPackages (ps: [ ps.aiohttp ]);
  # A Selkies web client as far as the server counts it: a websocket with the primary display's settings.
  client = pkgs.writeText "ws-client.py" ''
    import asyncio, json, aiohttp

    async def main():
        async with aiohttp.ClientSession() as http:
            ws = await http.ws_connect("ws://127.0.0.1:8082/api/websockets")
            await ws.send_str("SETTINGS," + json.dumps({"displayId": "primary", "manual_resolution": False,
                "useCssScaling": True, "displayScale": 1, "initialClientWidth": 1280, "initialClientHeight": 720,
                "audioRedundancy": True}))
            async for _ in ws:
                pass

    asyncio.run(main())
  '';
  hook = pkgs.writeShellScript "sleep-hook" ''
    echo "$1" >> /tmp/sleep-hook.log
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-power";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop = {
      enable = true;
      sleep.mode = "freeze";
      sleep.hooks = [ "${hook}" ];
      sleep.environmentFiles = [ "-/etc/webtop-sleep.env" ];
      sessionSave.enable = true;
    };
    environment.systemPackages = [ py ];
    services.journald.storage = "persistent";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
  };
  testScript = ''
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    rc = "/home/user/.config/ksmserverrc"
    group = "saved at previous logout"
    frozen_file = "/run/webtop/frozen-units"

    def ready():
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("selkies.service", "user")
        machine.wait_for_open_port(8082)
        machine.wait_for_unit("webtop-session.service")
        ${import ./wait-compositing.nix}
        ${import ./wait-session.nix}

    def units():
        return machine.succeed(f"cat {frozen_file}").split()

    def state(unit):
        return machine.succeed(f"{ubus} systemctl --user show -P FreezerState {unit}").strip()

    def sessions():
        return machine.succeed("curl -sf http://127.0.0.1:8082/api/sessions")

    def sleep():
        machine.succeed("rm -f /tmp/sleep-hook.log")
        machine.succeed("systemctl start --no-block systemd-suspend.service")
        machine.wait_until_succeeds(f"test -s {frozen_file}", timeout=60)

    def connect(name):
        machine.succeed(f"systemd-run --unit={name} ${py}/bin/python3 ${client}")

    def awake():
        machine.wait_until_succeeds(f"! test -e {frozen_file}", timeout=60)
        machine.wait_until_succeeds("test \"$(systemctl show -P ActiveState systemd-suspend.service)\" = inactive", timeout=60)
        assert machine.succeed("systemctl show -P Result systemd-suspend.service").strip() == "success"

    ready()
    assert machine.execute(f"grep -q '{group}' {rc}")[0] != 0, "the session was saved before anything asked for it"

    # Sleep with nobody connected: frozen, Selkies and the bus up, the hook told. The first client wakes it.
    sleep()
    frozen = units()
    assert any(u.startswith("plasma-") for u in frozen), frozen
    assert "selkies.service" not in frozen and "dbus-broker.service" not in frozen, frozen
    for u in frozen:
        assert state(u) == "frozen", (u, state(u))
    assert state("selkies.service") == "running"
    machine.succeed("curl -sf http://127.0.0.1:8082/ | grep -qi '<html'")
    assert machine.succeed("cat /tmp/sleep-hook.log") == "asleep\n"
    assert machine.succeed("systemctl show -P ActiveState systemd-suspend.service").strip() == "activating"
    connect("client-1")
    awake()
    for u in frozen:
        assert state(u) == "running", (u, state(u))
    assert machine.succeed("cat /tmp/sleep-hook.log") == "asleep\nawake\n"
    print("sessions after wake:", sessions())

    # A client that was there at Sleep does not wake it; another one does.
    sleep()
    machine.sleep(5)
    machine.succeed(f"test -s {frozen_file}")
    connect("client-2")
    awake()

    # An external stop thaws first, then saves. No marker and no halt.target: not saved, as with `systemctl poweroff`.
    machine.succeed("systemctl stop webtop-session-save.service; systemctl start webtop-session-save.service")
    assert "not saving" in machine.succeed("journalctl -u webtop-session-save.service -o cat -n 20")
    assert machine.execute(f"grep -q '{group}' {rc}")[0] != 0, "saved without a reason"
    # With the marker, while asleep: ksmserver must answer, so the stop thaws before it saves.
    machine.succeed("touch /run/webtop/sleep-poweroff")
    sleep()
    machine.succeed("systemctl stop webtop-session-save.service")
    machine.succeed(f"! test -e {frozen_file}")
    assert state("plasma-ksmserver.service") == "running"
    machine.succeed(f"grep -q '{group}' {rc}")
    assert "save-session: saved" in machine.succeed("journalctl -u webtop-session-save.service -o cat -n 20")
    machine.succeed("systemctl start webtop-session-save.service; rm -f /run/webtop/sleep-poweroff")
    connect("client-3")
    awake()

    # WEBTOP_SUSPEND_MODE=poweroff from an env file: the session is saved and the machine powers off.
    machine.succeed("echo WEBTOP_SUSPEND_MODE=poweroff > /etc/webtop-sleep.env")
    machine.succeed("systemctl start --no-block systemd-suspend.service")
    machine.wait_for_shutdown()
    machine.start()
    machine.wait_for_unit("multi-user.target")
    prev = machine.succeed("journalctl -b -1 -u webtop-session-save.service -o cat")
    assert "saving (sleep poweroff)" in prev and "save-session: saved" in prev, prev
  '';
}
