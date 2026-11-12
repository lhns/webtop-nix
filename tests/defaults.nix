# Admin defaults (README, "Time zone and locale"; ADR 0015): the defaults directory is snapshotted, its
# session.conf feeds the per-key time zone / locale / format chain (admin < user's webtop.* < System
# Settings), its xdg/ joins Plasma's KConfig cascade, and a missing or broken source leaves the desktop
# working. Its home.nix reaches the user's home-manager flake through the starter's `defaults` input (A3 on
# real Nix: tests/defaults-input-test.sh). Also proves the assumptions the design rests on (RESULT lines
# in the log): A1 startplasma reads plasma-localerc through the cascade and exports it, A2 a write of one key keeps the others, A4 the first
# login's ~/.config/kdedefaults masks admin look-and-feel keys, so the admin defaults the global theme
# ([KDE] LookAndFeelPackage) instead, A5 which LC_TIME renders ISO dates with 24 h in Qt and glibc.
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
  # What the Global Theme page of System Settings does on Defaults + Apply: its LookAndFeelSettings is a
  # KConfigSkeleton string item (kcms/lookandfeel/lookandfeelsettings.kcfg), reset with setDefaults() and saved.
  kcmDefaults = pkgs.stdenv.mkDerivation {
    name = "lnf-kcm-defaults";
    dontUnpack = true;
    dontConfigure = true;
    dontWrapQtApps = true;
    nativeBuildInputs = [ pkgs.cmake ];
    buildInputs = [ pkgs.kdePackages.qtbase pkgs.kdePackages.kconfig ];
    cmakeLists = pkgs.writeText "CMakeLists.txt" ''
      cmake_minimum_required(VERSION 3.16)
      project(lnf-kcm-defaults CXX)
      set(CMAKE_CXX_STANDARD 17)
      find_package(Qt6 REQUIRED COMPONENTS Core)
      find_package(KF6Config REQUIRED)
      add_executable(lnf-kcm-defaults main.cpp)
      target_link_libraries(lnf-kcm-defaults Qt6::Core KF6::ConfigCore)
    '';
    mainCpp = pkgs.writeText "main.cpp" ''
      #include <KCoreConfigSkeleton>
      #include <KSharedConfig>
      #include <QCoreApplication>
      #include <cstdio>

      int main(int argc, char **argv)
      {
          QCoreApplication app(argc, argv);
          KCoreConfigSkeleton settings(KSharedConfig::openConfig(QStringLiteral("kdeglobals")));
          settings.setCurrentGroup(QStringLiteral("KDE"));
          QString lnf;
          settings.addItemString(QStringLiteral("lookAndFeelPackage"), lnf, QStringLiteral("org.kde.breeze.desktop"), QStringLiteral("LookAndFeelPackage"));
          settings.load();
          settings.setDefaults();
          std::printf("KCMDEFAULT %s\n", qPrintable(lnf));
          return settings.save() ? 0 : 1;
      }
    '';
    buildPhase = ''
      cp $cmakeLists CMakeLists.txt
      cp $mainCpp main.cpp
      cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
      cmake --build build
    '';
    installPhase = "install -Dm755 build/lnf-kcm-defaults $out/bin/lnf-kcm-defaults";
  };
in
pkgs.testers.runNixOSTest {
  name = "webtop-defaults";
  node.pkgsReadOnly = false; # the module adds the overlay itself
  nodes.machine = { lib, options, ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # The starter flake, whose `defaults` input imports the admin's home.nix. It is evaluated here and
    # relocked by the setup unit, which is started by hand (a switch needs the network).
    services.webtop.nixProfile.enable = true;
    systemd.services.webtop-home-manager.wantedBy = lib.mkForce [ ];
    nix.settings.substituters = lib.mkForce [ ];
    # nixosSystem sets this registry entry; a test node does not.
    nix.registry.nixpkgs.to = { type = "path"; path = "${self.inputs.nixpkgs}"; };
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
      { lib, pkgs, config, ... }: {
        # The list is the option's default, so a user's `site.packages = [ ... ];` replaces it.
        options.site.packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ pkgs.hello ];
        };
        config = {
          home.packages = config.site.packages;
          home.sessionVariables.SITE_DEFAULT = lib.mkDefault "admin";
        };
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
    virtualisation.memorySize = 6144;
    virtualisation.cores = 2;
  };
  testScript = ''
    import base64, json, shlex, re
    ubus = "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
    snap = "/run/webtop/defaults"
    problems: list[str] = []

    def check(name, ok, evidence=""):
        print(f"RESULT {name}: {'PASS' if ok else 'FAIL'} {evidence}")
        if not ok:
            problems.append(name)

    def put(path, text, owner=None):
        b64 = base64.b64encode(text.encode()).decode()
        machine.succeed(f"mkdir -p $(dirname {path}) && rm -f {path} && echo {b64} | base64 -d > {path}" + (f" && chown {owner} {path}" if owner else ""))

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
    # Non-interactive shells that source what a terminal's shell does (a login shell: /etc/profile; an
    # interactive one: /etc/bashrc), so no tty or job control is involved.
    bash = "/run/current-system/sw/bin/bash"
    for how, cmd in [("login shell", f"{bash} -lc 'echo TERM_XDG=$XDG_CONFIG_DIRS' < /dev/null"),
                     ("interactive rc", f"PS1=x {bash} -c '. /etc/bashrc; echo TERM_XDG=$XDG_CONFIG_DIRS' < /dev/null")]:
        status, term = user_run(cmd, e)
        tdirs = re.search(r"TERM_XDG=(.*)", term)
        tenv = {**e, "XDG_CONFIG_DIRS": tdirs.group(1)} if tdirs else e
        check(f"a terminal ({how}) keeps XDG_CONFIG_DIRS and sees the admin's xdg key", tdirs is not None and "/run/webtop/defaults/xdg" in tdirs.group(1) and kread("kdeglobals", "Webtop", "AdminKey", tenv) == "admin", term)
    # A Plasma app (Qt, KConfig) in the session's environment.
    f = qt_fmt({**e, "QT_QPA_PLATFORM": "offscreen"})
    print("DIAG Qt in the session, admin LC_TIME sv_SE:", f)
    check("a Plasma app sees LC_TIME: ISO date, 24 h", isinstance(f, list) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", f[1]) is not None and re.fullmatch(r"\d{2}:\d{2}", f[2]) is not None, str(f))

    # ---- KDE settings through the cascade; A4 ----
    seen = {k: kread("kdeglobals", g, k, e) for g, k in [("Webtop", "AdminKey"), ("KDE", "widgetStyle"), ("General", "ColorScheme")]}
    check("kdeglobals: admin key through KConfig", seen["AdminKey"] == "admin", str(seen))
    check("kdeglobals: other keys of /etc/xdg survive (lock screen)", kread("kdeglobals", "KDE Action Restrictions", "action/lock_screen", e) == "false")
    # A4, observed: the first login writes ~/.config/kdedefaults, which masks the admin's look-and-feel keys.
    kd = machine.succeed("ls /home/user/.config/kdedefaults").split()
    print(f"RESULT A4: kdedefaults written at first login: {kd}; admin widgetStyle/ColorScheme seen: {seen['widgetStyle']!r}/{seen['ColorScheme']!r}")
    check("A4: first login writes kdedefaults and masks look-and-feel keys the admin sets directly", "kdeglobals" in kd and seen["widgetStyle"] != "AdminStyle" and seen["ColorScheme"] != "AdminScheme", str(kd))
    kwrite("--file kdeglobals --group Webtop --key Both user", e)
    after = ini(machine.succeed("cat /home/user/.config/kdeglobals"))
    check("kdeglobals: a user write lands in ~/.config only, with that key", after.get("Webtop") == {"Both": "user"} and "AdminKey" not in after.get("Webtop", {}) and after.get("KDE", {}).get("widgetStyle") != "AdminStyle", str(after.get("Webtop")))
    check("kdeglobals: user key wins, admin key stays", kread("kdeglobals", "Webtop", "Both", e) == "user" and kread("kdeglobals", "Webtop", "AdminKey", e) == "admin")
    machine.succeed("grep -q 'Both=admin' /run/webtop/defaults/xdg/kdeglobals")

    # ---- The global theme: the admin's [KDE] LookAndFeelPackage; startplasma regenerates kdedefaults from it ----
    admin_kdeglobals = machine.succeed("cat /etc/webtop/defaults/xdg/kdeglobals")

    def admin_theme(pkg):
        put("/etc/webtop/defaults/xdg/kdeglobals", admin_kdeglobals.replace("[KDE]\n", f"[KDE]\nLookAndFeelPackage={pkg}\n"))
        machine.succeed("systemctl restart webtop-defaults.service")

    def scheme_bg(scheme, env):
        """[Colors:Window] BackgroundNormal of a colour scheme, from the session's data dirs."""
        for d in env.get("XDG_DATA_DIRS", "").split(":"):
            status, out = machine.execute(f"cat {d}/color-schemes/{scheme}.colors")
            if status == 0:
                return ini(out)["Colors:Window"]["BackgroundNormal"]
        return None

    def theme(env):
        """The theme kdedefaults was made from, the colour scheme KConfig resolves, the palette in the user's kdeglobals (what apps paint with)."""
        pkg = machine.execute("cat /home/user/.config/kdedefaults/package")[1].strip()
        user = ini(machine.execute("cat /home/user/.config/kdeglobals")[1])
        return (pkg, kread("kdeglobals", "General", "ColorScheme", env), user.get("Colors:Window", {}).get("BackgroundNormal"))

    dark = lambda env: ("org.kde.breezedark.desktop", "BreezeDark", scheme_bg("BreezeDark", env))
    admin_theme("org.kde.breezedark.desktop")
    restart_session()
    e = penv()
    check("theme: the admin's LookAndFeelPackage replaces an existing home's kdedefaults and palette", dark(e)[2] is not None and theme(e) == dark(e), f"{theme(e)} want {dark(e)}")
    check("theme: keys the theme does not set still come from the admin", kread("kdeglobals", "Webtop", "AdminKey", e) == "admin")
    machine.succeed("rm -rf /home/user/.config/kdedefaults /home/user/.config/kdeglobals")
    restart_session()
    e = penv()
    check("theme: a first login applies the admin's theme", theme(e) == dark(e), f"{theme(e)} want {dark(e)}")
    user_lnf = lambda: machine.succeed("grep '^LookAndFeelPackage' /home/user/.config/kdeglobals || true").strip()
    # The user picks Breeze: plasma-apply-lookandfeel saves through the same settings as System Settings.
    status, out = user_run("plasma-apply-lookandfeel -a org.kde.breeze.desktop", e)
    assert status == 0, out
    restart_session()
    e = penv()
    light = ("org.kde.breeze.desktop", "BreezeLight", scheme_bg("BreezeLight", e))
    check("theme: the user's own choice wins", light[2] is not None and theme(e) == light, f"{theme(e)} want {light} {user_lnf()}")
    # Defaults + Apply in System Settings: the skeleton reads its default through the cascade (the admin's),
    # and since a lower layer has the key it writes the value instead of removing it.
    status, out = user_run("${kcmDefaults}/bin/lnf-kcm-defaults", e)
    print(f"RESULT theme: Defaults in System Settings: {out.strip()}; the user's file then has {user_lnf()!r}")
    check("theme: Defaults in System Settings resolves to the admin's theme", status == 0 and "KCMDEFAULT org.kde.breezedark.desktop" in out, out)
    restart_session()
    e = penv()
    check("theme: Defaults in System Settings brings the admin's theme back", theme(e) == dark(e), f"{theme(e)} want {dark(e)}")
    # The session start removes a user's entry equal to the admin's (webtop-follow-defaults), only in the
    # group the admin sets it in.
    machine.succeed("printf '\n[Elsewhere]\nAdminKey=admin\n[Webtop]\nAdminKey=admin\n' >> /home/user/.config/kdeglobals")
    admin_theme("org.kde.breeze.desktop")
    restart_session()
    e = penv()
    check("theme: after Defaults the user follows the admin's next theme", theme(e) == light and user_lnf() == "", f"{theme(e)} {user_lnf()!r}")
    uk = ini(machine.succeed("cat /home/user/.config/kdeglobals"))
    check("follow: an entry equal to the admin's is removed, the same line in another group stays",
          "AdminKey" not in uk.get("Webtop", {}) and uk.get("Elsewhere", {}).get("AdminKey") == "admin", str({g: uk.get(g) for g in ("Webtop", "Elsewhere")}))
    # KConfig's delete of a key a lower layer sets writes key[$d], which hides that layer too.
    kwrite("--file kdeglobals --group KDE --key LookAndFeelPackage --delete", e)
    check("theme: kwriteconfig6 --delete masks the admin's key with [$d]", user_lnf() == "LookAndFeelPackage[$d]", user_lnf())
    machine.succeed("sed -i '/^LookAndFeelPackage/d' /home/user/.config/kdeglobals")
    admin_theme("org.example.missing.desktop")
    restart_session()
    e = penv()
    check("theme: an unknown package gives Plasma's default, Breeze", theme(e) == light, f"{theme(e)} want {light}")
    put("/etc/webtop/defaults/xdg/kdeglobals", admin_kdeglobals)
    machine.succeed("systemctl restart webtop-defaults.service")

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

    # ---- home.nix: the starter flake imports the snapshot's through its `defaults` input ----
    hm = "/home/user/.config/home-manager"
    uh = "runuser -u user -- env HOME=/home/user"

    def hm_eval(attr, apply=None):
        a = f"--apply {shlex.quote(apply)} " if apply else ""
        status, out = machine.execute(f"{uh} nix eval --json {a}'path:{hm}#homeConfigurations.user.config.{attr}' 2>/tmp/hm-eval.err")
        err = machine.succeed("cat /tmp/hm-eval.err")
        return (json.loads(out) if status == 0 else None), err

    def hm_names():
        names, err = hm_eval("home.packages", "ps: map (p: p.name) ps")
        assert names is not None, err
        return names

    def hm_var():
        v, err = hm_eval("home.sessionVariables.SITE_DEFAULT")
        assert v is not None, err
        return v

    def run_setup():
        """The setup unit once, to the end. The switch needs the network, so it ends in a failure; the relock comes before it."""
        # No reset-failed first: on a unit that never ran it exits 1, and commands run under set -e.
        machine.succeed("systemctl start webtop-home-manager.service")
        machine.wait_until_succeeds("case \"$(systemctl show -P ActiveState webtop-home-manager.service)\" in inactive|failed) exit 0;; *) exit 1;; esac", timeout=900)

    machine.wait_until_succeeds(f"test -f {hm}/flake.nix", timeout=120)
    starter = machine.succeed(f"cat {hm}/flake.nix")
    check("home.nix: the starter has the defaults input and module", 'url = "path:/run/webtop/defaults";' in starter and '"''${defaults}/home.nix"' in starter)
    check("home.nix: an admin mkDefault value applies", hm_var() == "admin")
    check("home.nix: the admin's package applies", any(n.startswith("hello") for n in hm_names()), str(hm_names()))
    lock = json.loads(machine.succeed(f"cat {hm}/flake.lock"))["nodes"]["defaults"]["locked"]
    check("home.nix: the lock holds the snapshot as a path input with its narHash", lock["type"] == "path" and lock["path"] == snap and "narHash" in lock, str(lock))
    put(f"{hm}/local.nix", "{ ... }: { home.sessionVariables.SITE_DEFAULT = \"user\"; site.packages = [ ]; }\n", "user:")
    check("home.nix: the user's plain value beats the admin's mkDefault", hm_var() == "user")
    check("home.nix: the user's site.packages replaces the admin's list", not any(n.startswith("hello") for n in hm_names()), str(hm_names()))
    machine.succeed(f"rm {hm}/local.nix")

    # A new snapshot changes the directory's hash; the setup unit relocks it.
    put("/etc/webtop/defaults/home.nix", """{ lib, ... }: {
      options.site.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
      config.home.sessionVariables.SITE_DEFAULT = lib.mkDefault "admin2";
    }
    """)
    machine.succeed("systemctl restart webtop-defaults.service")
    # The old copy is still in the store, so the lock holds: the flake keeps the previous module until it is relocked.
    check("home.nix: a new snapshot is not picked up before the relock", hm_var() == "admin")
    machine.succeed("rm -f /home/user/.local/state/webtop/home-manager-switch /home/user/.local/state/webtop/applied")
    run_setup()
    hmlog = machine.succeed("journalctl -u webtop-home-manager.service -o cat")
    check("home.nix: the setup unit relocks the changed snapshot", "relocking stale inputs: defaults" in hmlog, hmlog[-600:])
    check("home.nix: the new home.nix applies after the relock", hm_var() == "admin2" and not any(n.startswith("hello") for n in hm_names()))
    run_setup()
    check("home.nix: an unchanged snapshot is not relocked again", machine.succeed("journalctl -u webtop-home-manager.service -o cat | grep -c 'relocking stale inputs: defaults'").strip() == "1")

    # A syntax error: replaced by { }, logged, and the user told once Plasma is up.
    put("/etc/webtop/defaults/home.nix", "{ foo = ; }\n")
    machine.succeed("systemctl restart webtop-defaults.service")
    machine.succeed(f"test \"$(cat {snap}/home.nix)\" = '{{ }}'")
    machine.succeed("journalctl -u webtop-defaults.service -o cat | grep -q 'home.nix does not parse'")
    machine.succeed("head -n1 /run/webtop/defaults-notice | grep -qx 'Admin defaults: home.nix ignored'")
    machine.succeed("systemctl restart webtop-defaults-notice.service")
    machine.wait_until_succeeds("test \"$(systemctl show -P ActiveState webtop-defaults-notice.service)\" != active", timeout=300)
    nlog = machine.succeed("journalctl -u webtop-defaults-notice.service -o cat")
    check("home.nix: a syntax error is announced to the user", "notifying: Admin defaults: home.nix ignored" in nlog and "not delivered" not in nlog, nlog)
    put("/etc/webtop/defaults/home.nix", "{ }\n")
    machine.succeed("systemctl restart webtop-defaults.service; test ! -e /run/webtop/defaults-notice")

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
