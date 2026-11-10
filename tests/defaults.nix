# Admin defaults (README, "Time zone and locale"; ADR 0015): the defaults directory is snapshotted, its
# session.conf feeds the per-key time zone / locale / format chain (admin < user's webtop.* < System
# Settings), its xdg/ joins Plasma's KConfig cascade, and a missing or broken source leaves the desktop
# working. Also proves the assumptions the design rests on (RESULT lines in the log): A1 startplasma reads
# plasma-localerc through the cascade and exports it, A2 a write of one key keeps the others, A4 whether a
# first login writes ~/.config/kdedefaults, A5 which LC_TIME renders ISO dates with 24 h in Qt and glibc.
# Needs KVM to run; evaluates without.
{ pkgs, self }:

let
  # Formats as Qt reports them: locale name, short date, short time, long date, weekday, month.
  fmtQml = pkgs.writeText "fmt.qml" ''
    import QtQml
    QtObject {
      Component.onCompleted: {
        var d = new Date(2026, 10, 9, 15, 5, 7)
        var l = Qt.locale()
        console.log("QTFMT " + [l.name, d.toLocaleDateString(l, Locale.ShortFormat), d.toLocaleTimeString(l, Locale.ShortFormat),
          d.toLocaleDateString(l, Locale.LongFormat), l.dayName(1, Locale.LongFormat), l.monthName(11, Locale.LongFormat)].join("|"))
        Qt.quit()
      }
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-defaults";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { lib, options, ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # The module's own defaults, below the admin's.
    services.webtop.timeZone = "America/New_York";
    services.webtop.locale = "en_GB.UTF-8";
    services.webtop.locales = options.services.webtop.locales.default ++ [ "en_DK.UTF-8" ];
    # services.webtop.defaults.source is left at its default, /etc/webtop/defaults.
    environment.etc."webtop/defaults/session.conf".text = ''
      timeZone=Europe/Berlin
      locale=de_DE.UTF-8
      language=de:en
      LC_TIME=sv_SE.UTF-8
      LC_MONETARY=nl_NL.UTF-8
    '';
    environment.etc."webtop/defaults/home.nix".text = ''
      { lib, ... }: {
        home.sessionVariables.SITE_DEFAULT = lib.mkDefault "admin";
      }
    '';
    environment.etc."webtop/defaults/xdg/kdeglobals".text = ''
      [Webtop]
      AdminKey=admin
      Both=admin

      [KDE]
      widgetStyle=AdminStyle

      [General]
      ColorScheme=AdminScheme
    '';
    # Stands in for a key in the cascade layer that /etc/locale.conf does not carry (appended after webtop-locale).
    systemd.services.webtop-session.serviceConfig.ExecStartPre = lib.mkAfter [
      "-+${pkgs.writeShellScript "inject-localerc" ''
        if [ -f /etc/inject-localerc ]; then cat /etc/inject-localerc >> /run/webtop/xdg-session/plasma-localerc; fi
      ''}"
    ];
    environment.systemPackages = [ pkgs.kdePackages.kconfig pkgs.kdePackages.qtdeclarative ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
  };
  testScript = ''
    import base64, shlex, re
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    snap = "/run/webtop/defaults"
    problems: list[str] = []

    def check(name, ok, evidence=""):
        print(f"RESULT {name}: {'PASS' if ok else 'FAIL'} {evidence}")
        if not ok:
            problems.append(name)

    def put(path, text, owner=None):
        b64 = base64.b64encode(text.encode()).decode()
        machine.succeed(f"mkdir -p $(dirname {path}) && echo {b64} | base64 -d > {path}" + (f" && chown {owner} {path}" if owner else ""))

    def ready():
        machine.wait_for_unit("webtop-session.service")
        machine.wait_until_succeeds(f"{ubus} systemctl --user is-active plasma-workspace.target", timeout=300)
        ${import ./wait-compositing.nix}
        ${import ./wait-session.nix}

    def restart_session():
        machine.succeed("systemctl reset-failed webtop-session.service; systemctl restart webtop-session.service")
        ready()

    def penv():
        """The environment plasmashell started with: what Plasma's apps inherit."""
        machine.wait_until_succeeds(f"test \"$({ubus} systemctl --user show -p MainPID --value plasma-plasmashell.service)\" -gt 0", timeout=120)
        pid = machine.succeed(f"{ubus} systemctl --user show -p MainPID --value plasma-plasmashell.service").strip()
        out = machine.succeed(f"xargs -0 -n1 < /proc/{pid}/environ")
        return dict(l.split("=", 1) for l in out.splitlines() if "=" in l)

    def user_run(cmd, env):
        pairs = " ".join(shlex.quote(f"{k}={v}") for k, v in env.items())
        return machine.execute(f"runuser -u user -- env -i {pairs} {cmd} 2>&1")

    def kread(file, group, key, env):
        status, out = user_run(f"kreadconfig6 --file {file} --group {shlex.quote(group)} --key {key}", env)
        return out.strip()

    def kwrite(args, env):
        status, out = user_run(f"kwriteconfig6 {args}", env)
        assert status == 0, out

    def ini(text):
        """group -> {key: value}"""
        res, g = {}, None
        for l in text.splitlines():
            l = l.strip()
            if l.startswith("[") and l.endswith("]"):
                g = l[1:-1]; res.setdefault(g, {})
            elif "=" in l and g is not None:
                k, v = l.split("=", 1); res[g][k] = v
        return res

    def locale_conf():
        return dict(l.split("=", 1) for l in machine.succeed("cat /etc/locale.conf").splitlines() if "=" in l)

    def zone():
        return machine.succeed("readlink /etc/localtime").strip().removeprefix("/etc/zoneinfo/")

    def qt_fmt(env):
        status, out = user_run("env QT_QPA_PLATFORM=offscreen ${pkgs.kdePackages.qtdeclarative}/bin/qml ${fmtQml}", env)
        m = re.search(r"QTFMT (.*)", out)
        return m.group(1).split("|") if m else out

    # ---- Boot with the admin's directory only ----
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("webtop-defaults.service")
    assert machine.succeed(f"stat -c '%U:%a' {snap}").strip() == "root:755", "snapshot is not root-owned and world-readable"
    # A valid module survives the snapshot (nix-instantiate --parse works in the unit).
    machine.succeed(f"cmp {snap}/home.nix /etc/webtop/defaults/home.nix")
    assert "AdminKey=admin" in machine.succeed(f"cat {snap}/xdg/kdeglobals")
    machine.succeed(f"test ! -e {snap}/..data && test ! -L {snap}/session.conf")
    ready()
    e = penv()

    check("admin: time zone", zone() == "Europe/Berlin" and machine.succeed("timedatectl show -P Timezone").strip() == "Europe/Berlin", zone())
    lc = locale_conf()
    admin = {"LANG": "de_DE.UTF-8", "LANGUAGE": "de:en", "LC_TIME": "sv_SE.UTF-8", "LC_MONETARY": "nl_NL.UTF-8"}
    check("admin: /etc/locale.conf", lc == admin, str(lc))
    lr = ini(machine.succeed("cat /run/webtop/xdg-session/plasma-localerc"))
    check("admin: xdg-session/plasma-localerc", lr == {"Formats": {"LANG": "de_DE.UTF-8", "LC_TIME": "sv_SE.UTF-8", "LC_MONETARY": "nl_NL.UTF-8"}, "Translations": {"LANGUAGE": "de:en"}}, str(lr))
    check("session sees the admin's locale", all(e.get(k) == v for k, v in admin.items()), str({k: e.get(k) for k in admin}))
    dirs = e.get("XDG_CONFIG_DIRS", "")
    # Nix's wrappers of the Plasma binaries put their packages' etc/xdg first; the admin's layers sit above /etc/xdg.
    parts = dirs.split(":")
    check("XDG_CONFIG_DIRS: xdg-session, then the admin's xdg, both above /etc/xdg", "/run/webtop/xdg-session:/run/webtop/defaults/xdg" in dirs and parts.index("/run/webtop/xdg-session") < parts.index("/etc/xdg") and "/home/user/.config/kdedefaults" in parts[:parts.index("/run/webtop/xdg-session")], dirs)
    check("systemd user manager sees XDG_CONFIG_DIRS", "/run/webtop/xdg-session" in machine.succeed(f"{ubus} systemctl --user show-environment"))
    # A terminal: a shell started from the session's environment (it sources NixOS's profile scripts).
    status, term = user_run("/run/current-system/sw/bin/bash -ic 'echo TERM_XDG=$XDG_CONFIG_DIRS' 2>/dev/null", e)
    tdirs = re.search(r"TERM_XDG=(.*)", term)
    tenv = {**e, "XDG_CONFIG_DIRS": tdirs.group(1)} if tdirs else e
    check("a terminal keeps XDG_CONFIG_DIRS and sees the admin's xdg key", tdirs is not None and "/run/webtop/defaults/xdg" in tdirs.group(1) and kread("kdeglobals", "Webtop", "AdminKey", tenv) == "admin", term)
    # A Plasma app (Qt, KConfig) in the session's environment.
    f = qt_fmt({**e, "QT_QPA_PLATFORM": "offscreen"})
    print("DIAG Qt in the session, admin LC_TIME sv_SE:", f)
    check("a Plasma app sees LC_TIME: ISO date, 24 h", isinstance(f, list) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", f[1]) is not None and re.fullmatch(r"\d{2}:\d{2}", f[2]) is not None, str(f))

    # ---- KDE settings through the cascade; A4 ----
    print("DIAG kdedefaults after the first login:", machine.execute("ls -la /home/user/.config/kdedefaults 2>&1; head -40 /home/user/.config/kdedefaults/kdeglobals 2>&1")[1])
    print("DIAG ~/.config/kdeglobals after the first login:", machine.execute("head -40 /home/user/.config/kdeglobals 2>&1")[1])
    seen = {k: kread("kdeglobals", g, k, e) for g, k in [("Webtop", "AdminKey"), ("KDE", "widgetStyle"), ("General", "ColorScheme")]}
    check("kdeglobals: admin key through KConfig", seen["AdminKey"] == "admin", str(seen))
    check("kdeglobals: other keys of /etc/xdg survive (lock screen)", kread("kdeglobals", "KDE Action Restrictions", "action/lock_screen", e) == "false")
    # A4, observed: the first login writes ~/.config/kdedefaults, which masks the admin's look-and-feel keys.
    kd = machine.succeed("ls /home/user/.config/kdedefaults").split()
    print(f"RESULT A4: kdedefaults written at first login: {kd}; admin widgetStyle/ColorScheme seen: {seen['widgetStyle']!r}/{seen['ColorScheme']!r}")
    check("A4: first login writes kdedefaults and masks the admin's look-and-feel keys", "kdeglobals" in kd and seen["widgetStyle"] != "AdminStyle" and seen["ColorScheme"] != "AdminScheme", str(kd))
    kwrite("--file kdeglobals --group Webtop --key Both user", e)
    after = ini(machine.succeed("cat /home/user/.config/kdeglobals"))
    check("kdeglobals: a user write lands in ~/.config only, with that key", after.get("Webtop") == {"Both": "user"} and "AdminKey" not in after.get("Webtop", {}) and after.get("KDE", {}).get("widgetStyle") != "AdminStyle", str(after.get("Webtop")))
    check("kdeglobals: user key wins, admin key stays", kread("kdeglobals", "Webtop", "Both", e) == "user" and kread("kdeglobals", "Webtop", "AdminKey", e) == "admin")
    machine.succeed("grep -q 'Both=admin' /run/webtop/defaults/xdg/kdeglobals")

    # ---- A1: startplasma reads plasma-localerc through the cascade and exports it ----
    check("A1 precondition: user has no plasma-localerc, so nothing came from it", machine.execute("test -e /home/user/.config/plasma-localerc")[0] != 0,
          machine.execute("cat /home/user/.config/plasma-localerc 2>&1")[1])
    put("/etc/inject-localerc", "[Formats]\nLC_MEASUREMENT=fr_FR.UTF-8\n")
    restart_session()
    e = penv()
    check("A1: a key only in xdg-session/plasma-localerc reaches the session", e.get("LC_MEASUREMENT") == "fr_FR.UTF-8" and "LC_MEASUREMENT" not in locale_conf(),
          f"LC_MEASUREMENT={e.get('LC_MEASUREMENT')} locale.conf={locale_conf()}")
    machine.succeed("rm -f /etc/inject-localerc")
    # Both startplasma's own write (LANG, only if no layer has one) and anything else must leave the user's file alone.
    check("A2 (startplasma): no write to ~/.config/plasma-localerc by a plain login", machine.execute("test -e /home/user/.config/plasma-localerc")[0] != 0,
          machine.execute("cat /home/user/.config/plasma-localerc 2>&1")[1])

    # ---- The user's webtop.* (session.conf) beat the admin's, per key ----
    put("/home/user/.config/webtop/session.conf", "locale=en_US.UTF-8\nLC_NUMERIC=fr_FR.UTF-8\n", "user:")
    restart_session()
    e = penv()
    want = {"LANG": "en_US.UTF-8", "LANGUAGE": "de:en", "LC_TIME": "sv_SE.UTF-8", "LC_MONETARY": "nl_NL.UTF-8", "LC_NUMERIC": "fr_FR.UTF-8"}
    check("user: time zone stays the admin's", zone() == "Europe/Berlin", zone())
    check("user: /etc/locale.conf per key", locale_conf() == want, str(locale_conf()))
    check("user: session per key", all(e.get(k) == v for k, v in want.items()), str({k: e.get(k) for k in want}))
    lr = ini(machine.succeed("cat /run/webtop/xdg-session/plasma-localerc"))
    check("user: xdg-session/plasma-localerc per key", lr.get("Formats", {}).get("LANG") == "en_US.UTF-8" and lr["Formats"].get("LC_TIME") == "sv_SE.UTF-8" and lr["Formats"].get("LC_NUMERIC") == "fr_FR.UTF-8" and lr.get("Translations") == {"LANGUAGE": "de:en"}, str(lr))
    put("/home/user/.config/webtop/session.conf", "timeZone=Asia/Tokyo\n", "user:")
    machine.succeed("systemctl reset-failed webtop-session.service; systemctl restart webtop-session.service")
    ready()
    check("user: time zone", zone() == "Asia/Tokyo" and locale_conf() == admin, f"{zone()} {locale_conf()}")
    machine.succeed("rm -f /home/user/.config/webtop/session.conf")

    # ---- A2: a System Settings-style write of one formats key wins and keeps the language ----
    put("/home/user/.config/webtop/session.conf", "locale=en_US.UTF-8\n", "user:")
    restart_session()
    e = penv()
    kwrite("--file plasma-localerc --group Formats --key LC_TIME en_GB.UTF-8", e)
    uf = ini(machine.succeed("cat /home/user/.config/plasma-localerc"))
    check("A2: the write holds only that key", uf == {"Formats": {"LC_TIME": "en_GB.UTF-8"}}, str(uf))
    restart_session()
    e = penv()
    want = {"LANG": "en_US.UTF-8", "LANGUAGE": "de:en", "LC_TIME": "en_GB.UTF-8", "LC_MONETARY": "nl_NL.UTF-8"}
    check("A2: the user's LC_TIME wins in the session, LANG and LANGUAGE stay", all(e.get(k) == v for k, v in want.items()), str({k: e.get(k) for k in want}))
    check("A2: startplasma left the user's file as it was", ini(machine.succeed("cat /home/user/.config/plasma-localerc")) == {"Formats": {"LC_TIME": "en_GB.UTF-8"}})
    check("A2: /etc/locale.conf keeps the system value", locale_conf().get("LC_TIME") == "sv_SE.UTF-8")
    f = qt_fmt({**e, "QT_QPA_PLATFORM": "offscreen"})
    print("DIAG Qt in the session, user LC_TIME en_GB:", f)
    check("a Plasma app sees the user's LC_TIME", isinstance(f, list) and f[1] != "2026-11-09", str(f))
    kwrite("--file plasma-localerc --group Formats --key LC_TIME --delete", e)
    restart_session()
    e = penv()
    check("deleting the user's key brings the admin's back", e.get("LC_TIME") == "sv_SE.UTF-8", str(e.get("LC_TIME")))
    machine.succeed("rm -f /home/user/.config/webtop/session.conf /home/user/.config/plasma-localerc")

    # ---- A5: which LC_TIME renders ISO dates with 24 h ----
    ok_cands = []
    for cand in ["sv_SE.UTF-8", "en_DK.UTF-8"]:
        env = {"LANG": "de_DE.UTF-8", "LC_TIME": cand, "LOCALE_ARCHIVE": "/run/current-system/sw/lib/locale/locale-archive",
               "PATH": "/run/current-system/sw/bin", "HOME": "/home/user", "XDG_RUNTIME_DIR": "/run/user/1000",
               "QT_PLUGIN_PATH": e.get("QT_PLUGIN_PATH", ""), "QML2_IMPORT_PATH": e.get("QML2_IMPORT_PATH", "")}
        q = qt_fmt(env)
        g = machine.succeed(f"LANG=de_DE.UTF-8 LC_TIME={cand} LOCALE_ARCHIVE=/run/current-system/sw/lib/locale/locale-archive date -d '2026-11-09 15:05:07' +'%x|%X|%A|%B'").strip()
        print(f"DIAG A5 {cand}: Qt {q}; glibc {g}")
        qt_ok = isinstance(q, list) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", q[1]) is not None and re.fullmatch(r"\d{2}:\d{2}", q[2]) is not None
        gl = g.split("|")
        glibc_ok = re.fullmatch(r"\d{4}-\d{2}-\d{2}", gl[0]) is not None and re.fullmatch(r"\d{2}:\d{2}:\d{2}", gl[1]) is not None
        print(f"RESULT A5 {cand}: Qt ISO+24h={qt_ok} glibc ISO+24h={glibc_ok}")
        if qt_ok and glibc_ok:
            ok_cands.append(cand)
    check("A5: one candidate gives ISO dates with 24 h in Qt and glibc", bool(ok_cands), str(ok_cands))

    # ---- A missing source: the module's defaults, the desktop works ----
    machine.succeed("rm -rf /etc/webtop")
    machine.succeed("systemctl restart webtop-defaults.service")
    machine.succeed(f"test ! -e {snap}/session.conf && test ! -e {snap}/xdg/kdeglobals && test \"$(cat {snap}/home.nix)\" = '{{ }}'")
    machine.succeed("journalctl -u webtop-defaults.service -o cat | grep -q 'no defaults at /etc/webtop/defaults'")
    restart_session()
    e = penv()
    check("missing source: module defaults, nothing stale", zone() == "America/New_York" and locale_conf() == {"LANG": "en_GB.UTF-8"} and e.get("LANG") == "en_GB.UTF-8" and kread("kdeglobals", "Webtop", "AdminKey", e) == "",
          f"{zone()} {locale_conf()} {e.get('LANG')}")
    check("missing source: xdg-session/plasma-localerc holds LANG only", ini(machine.succeed("cat /run/webtop/xdg-session/plasma-localerc")) == {"Formats": {"LANG": "en_GB.UTF-8"}})

    # ---- A broken source, laid out as a ConfigMap mount: links through ..data, bad values, a syntax error ----
    d = "/etc/webtop/defaults"
    put(f"{d}/..2026_11_10/session.conf", "timeZone=Mars/Olympus\nlocale=xx_XX.UTF-8\nLC_TIME=sv_SE.UTF-8\nno equals sign\n")
    put(f"{d}/..2026_11_10/xdg/kdeglobals", "[Webtop]\nAdminKey=configmap\n")
    put(f"{d}/..2026_11_10/xdg/plasma-localerc", "[Formats]\nLC_TIME=en_DK.UTF-8\n")
    put(f"{d}/..2026_11_10/home.nix", "{ foo = ; }\n")
    machine.succeed(f"cd {d} && ln -s ..2026_11_10 ..data && ln -s ..data/session.conf session.conf && ln -s ..data/xdg xdg && ln -s ..data/home.nix home.nix && mkfifo stray")
    machine.succeed("systemctl restart webtop-defaults.service")
    machine.succeed(f"test -f {snap}/session.conf && test ! -L {snap}/session.conf && test -f {snap}/xdg/kdeglobals && test ! -e {snap}/..data && test ! -e {snap}/stray")
    machine.succeed(f"test ! -e {snap}/xdg/plasma-localerc && test \"$(cat {snap}/home.nix)\" = '{{ }}'")
    machine.succeed("journalctl -u webtop-defaults.service -o cat | grep -q 'home.nix does not parse' && journalctl -u webtop-defaults.service -o cat | grep -q 'xdg/plasma-localerc is reserved'")
    restart_session()
    e = penv()
    check("broken source: bad values fall back, good ones apply", zone() == "America/New_York" and e.get("LANG") == "en_GB.UTF-8" and e.get("LC_TIME") == "sv_SE.UTF-8", f"{zone()} {e.get('LANG')} {e.get('LC_TIME')}")
    check("broken source: xdg through ..data links", kread("kdeglobals", "Webtop", "AdminKey", e) == "configmap")
    machine.succeed("journalctl -u webtop-session.service -o cat | grep -q 'defaults session.conf: ignored 1 lines'")
    machine.succeed("journalctl -u webtop-session.service -o cat | grep -q \"ignoring invalid timeZone 'Mars/Olympus' from admin defaults\"")
    # A garbage directory in place of the source.
    machine.succeed("rm -rf /etc/webtop; mkdir -p /etc/webtop; head -c 3000 /dev/urandom > /etc/webtop/defaults; systemctl restart webtop-defaults.service")
    machine.succeed(f"test \"$(cat {snap}/home.nix)\" = '{{ }}' && test ! -e {snap}/session.conf")
    restart_session()
    check("source is not a directory: module defaults", zone() == "America/New_York" and penv().get("LANG") == "en_GB.UTF-8")

    # Nothing set at all (no module default, no admin file): LANG stays the image's and is still given to
    # the cascade, so startplasma does not write its own into the user's plasma-localerc.
    machine.succeed("rm -rf /etc/webtop; systemctl restart webtop-defaults.service")
    machine.succeed("printf 'LANG=en_GB.UTF-8\n' > /etc/locale.conf; rm -rf /tmp/xs")
    bin = machine.succeed("ls /nix/store/*-webtop-locale/bin/webtop-locale").split()[0]
    machine.succeed(f"{bin} 1000 /run/current-system/sw/lib/locale/locale-archive \"\" \"\" \"\" /run/webtop/defaults /tmp/xs")
    check("no source and no module default: LANG still reaches the cascade, locale.conf untouched",
          machine.succeed("cat /tmp/xs/plasma-localerc") == "[Formats]\nLANG=en_GB.UTF-8\n" and machine.succeed("cat /etc/locale.conf") == "LANG=en_GB.UTF-8\n")

    print("PROBLEMS:", problems)
    assert not problems, problems
  '';
}
