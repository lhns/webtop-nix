# Boots the module and checks that Selkies answers. Needs KVM to run; evaluates without.
{ pkgs, self }:

let
  userDirs = pkgs.writeText "user-dirs.dirs" ''
    XDG_DOWNLOAD_DIR="$HOME/Inbox"
  '';
  # One setting the user may change and one they may not.
  userSettings = pkgs.writeText "selkies.env" ''
    # comment
    SELKIES_FRAMERATE=33
    SELKIES_FILE_TRANSFERS=none
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # Overrides the module's SELKIES_USE_BROWSER_CURSORS=true; the "-" makes a missing file harmless.
    services.webtop.environmentFiles = [ "-/etc/webtop-test.env" ];
    environment.etc."webtop-test.env".text = "SELKIES_USE_BROWSER_CURSORS=false
";
    # Time zone and locale: module default < env file (the pod env in a cluster) < the user's session.conf.
    services.webtop.timeZone = "Europe/Berlin";
    services.webtop.locale = "en_GB.UTF-8";
    services.webtop.localeEnvironmentFiles = [ "-/etc/webtop-locale.env" ];
    environment.etc."webtop-locale.env".text = "WEBTOP_TIME_ZONE=Asia/Tokyo
WEBTOP_LOCALE=de_DE.UTF-8
";
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_open_port(8082)
    machine.succeed("curl -sf http://localhost:8082/ | grep -qi '<html'")
    machine.wait_for_unit("webtop-session.service")

    # A gray screen is KWin up but not compositing (no render device); the session unit still looks healthy.
    ${import ./wait-compositing.nix}

    # Uploads and downloads, runtime settings. The XDG download dir is a custom one, so the
    # upload directory is not hard-coded; the user's settings file mixes an allowed and a refused key.
    user = lambda cmd: machine.succeed(f"runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 {cmd}")
    machine.succeed("install -D -o user -m644 ${userDirs} /home/user/.config/user-dirs.dirs")
    machine.succeed("install -D -o user -m644 ${userSettings} /home/user/.config/webtop/selkies.env")
    machine.succeed("install -D -o user -m644 ${userDirs} /home/user/Documents/doc.txt")
    machine.succeed("chown -R user: /home/user")
    user("systemctl --user restart selkies.service")
    machine.wait_for_open_port(8082)

    pid = user("systemctl --user show -p MainPID --value selkies.service").strip()
    env = machine.succeed(f"xargs -0 -n1 < /proc/{pid}/environ")
    assert "SELKIES_USE_BROWSER_CURSORS=false" in env, "environmentFiles entry did not override the default"
    assert "SELKIES_FRAMERATE=33" in env, "allowlisted user setting not applied"
    assert "SELKIES_FILE_TRANSFERS=upload,download" in env, "non-allowlisted user setting was applied"
    assert "SELKIES_UPLOAD_PATH=/home/user/Inbox" in env, "upload path is not the XDG download dir"

    machine.succeed(
        "curl -sf -X POST -H 'X-Upload-Path: hello.txt' --data-binary 'hi there' http://localhost:8082/api/upload"
    )
    assert machine.succeed("cat /home/user/Inbox/hello.txt") == "hi there"
    machine.fail("test -e /home/user/hello.txt")
    machine.fail("test -e /home/user/Desktop/hello.txt")

    # Downloads are served from the whole home.
    assert machine.succeed("curl -sf http://localhost:8082/api/files/Documents/doc.txt").strip() == 'XDG_DOWNLOAD_DIR="$HOME/Inbox"'
    machine.succeed("curl -sfL http://localhost:8082/api/files/ -o /tmp/files.html && grep -q Documents /tmp/files.html")

    # Time zone and locale. A change needs a session restart, which applies it again.
    import base64, shlex
    problems = []
    conf = "/home/user/.config/webtop/session.conf"
    def session_env():
        machine.wait_for_unit("webtop-session.service")
        # Past the wrapper, which sources /etc/locale.conf and then execs Plasma's starter.
        machine.wait_until_succeeds("grep -aq startplasma /proc/$(systemctl show -P MainPID webtop-session)/cmdline", timeout=120)
        return machine.succeed("xargs -0 -n1 < /proc/$(systemctl show -P MainPID webtop-session)/environ")
    def restart_session(text=None):
        machine.succeed(f"rm -f {conf}")
        if text is not None:
            b64 = base64.b64encode(text.encode()).decode()
            machine.succeed(f"echo {b64} | base64 -d > {conf} && chown user: {conf}")
        machine.succeed("systemctl reset-failed webtop-session.service; systemctl restart webtop-session.service")
        return session_env()
    def expect(zone, lang, env):
        assert machine.succeed("readlink /etc/localtime").strip() == f"/etc/zoneinfo/{zone}", "localtime"
        assert machine.succeed("timedatectl show -P Timezone").strip() == zone, "timedated disagrees"
        lc = machine.succeed("localectl status")
        if f"LANG={lang}" not in lc:
            print("DIAG localectl status:"+chr(10)+lc+machine.execute("ls -l /etc/locale.conf; cat /etc/locale.conf; systemctl status systemd-localed --no-pager; tr '\\0' '\\n' < /proc/1/environ | grep -a LANG")[1])
            problems.append("localectl disagrees")
        assert f"LANG={lang}" in env.splitlines(), "session lacks LANG"
        assert not any(l.startswith(("TZ=", "LC_ALL=")) for l in env.splitlines()), "TZ/LC_ALL leaked"
        # A terminal: a shell started from the session's environment (it sources NixOS's profile scripts).
        shell_env = " ".join(shlex.quote(l) for l in env.splitlines() if "=" in l)
        term = machine.succeed(f"runuser -u user -- env -i {shell_env} /run/current-system/sw/bin/bash -ic 'echo LANG=$LANG; date +%Z' 2>/dev/null").split()
        assert term[0] == f"LANG={lang}", f"a terminal sees {term}"

    # Boot: the env file beats the module's defaults.
    expect("Asia/Tokyo", "de_DE.UTF-8", session_env())
    assert machine.succeed("env -u TZ date +%Z").strip() == "JST"
    machine.wait_until_succeeds("runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment | grep -qx LANG=de_DE.UTF-8", timeout=120)

    # The user's file beats the env file; unknown and gateway keys are ignored.
    expect("America/New_York", "fr_FR.UTF-8", restart_session("# c\nonLogout=true\nbogus=1\ntimeZone=America/New_York\nlocale=fr_FR.UTF-8\n"))

    # Invalid values fall back to the next source (here the env file), and the session still starts.
    for bad in ["timeZone=../../etc/passwd", "timeZone=/etc/passwd", "timeZone=Asia/../../../etc/shadow",
                "timeZone=Mars/Olympus", "timeZone=tzdata.zi", "timeZone=" + "A" * 5000,
                "timeZone=$(touch /pwned)", "locale=xx_XX.UTF-8", "locale=de_DE.UTF-8;touch /pwned", "locale=../../x",
                "no equals sign", "\x00\x01\x02"]:
        expect("Asia/Tokyo", "de_DE.UTF-8", restart_session(bad + "\n"))
    machine.fail("test -e /pwned")
    # A bad user value does not discard a good one on another line.
    expect("Asia/Tokyo", "fr_FR.UTF-8", restart_session("timeZone=Mars/Olympus\nlocale=fr_FR.UTF-8\n"))
    # Links, directories and oversized files are not read.
    machine.succeed(f"rm -f {conf}; ln -s /etc/webtop-locale.env {conf}")
    machine.succeed("systemctl reset-failed webtop-session.service; systemctl restart webtop-session.service")
    expect("Asia/Tokyo", "de_DE.UTF-8", session_env())
    machine.succeed(f"rm -f {conf}; head -c 100000 /dev/zero | tr '\0' '#' > {conf}; printf 'timeZone=Europe/Paris\n' >> {conf}; chown user: {conf}")
    machine.succeed("systemctl reset-failed webtop-session.service; systemctl restart webtop-session.service")
    expect("Asia/Tokyo", "de_DE.UTF-8", session_env())

    # Nothing valid anywhere: the module's defaults (here after the env file is gone).
    machine.succeed("rm -f /etc/webtop-locale.env")
    machine.succeed(f"rm -f {conf}; systemctl reset-failed webtop-session.service; systemctl restart webtop-session.service")
    expect("Europe/Berlin", "en_GB.UTF-8", session_env())

    # KDE's settings page writes through timedated to /etc/localtime; the next start applies the setting again.
    machine.succeed("timedatectl set-timezone Europe/London")
    assert machine.succeed("timedatectl show -P Timezone").strip() == "Europe/London"
    machine.succeed("systemctl reset-failed webtop-session.service; systemctl restart webtop-session.service")
    expect("Europe/Berlin", "en_GB.UTF-8", session_env())
    assert not problems, problems
  '';
}
