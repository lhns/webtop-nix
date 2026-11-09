# Several apps at once, each on its own screen and its own stream (README, "One app per screen"):
# routing of stream and input per page, focus, dialogs, closing a middle one, reopening, reload,
# takeover, the main page beside them, cost at 1, 2 and 4 screens, stopping with pages open.
# Writes summary.txt, screenshots and logs to the output directory, also on failure, then asserts.
{ pkgs, self }:

let
  py = pkgs.python3.withPackages (ps: [ ps.playwright ps.pillow ]);
  appPy = pkgs.python3.withPackages (ps: [ ps.pyside6 ]);
  # An app of a given id and colour: logs clicks and keys, `d` opens a dialog, and it repaints all
  # its pixels while /tmp/animate exists (the costly case for capture and encode).
  app = pkgs.writeText "test-app.py" ''
    import os, random, sys
    from PySide6.QtCore import QTimer
    from PySide6.QtGui import QColor, QGuiApplication, QPainter
    from PySide6.QtWidgets import QApplication, QDialog, QWidget

    app_id, colour, log = sys.argv[1:4]
    QGuiApplication.setDesktopFileName(app_id)

    class W(QWidget):
        def __init__(self):
            super().__init__()
            self.log = open(log, "a", buffering=1)
            self.noise = False
            self.t = QTimer(self)
            self.t.timeout.connect(self.tick)
            self.t.start(33)
        def tick(self):
            noise = os.path.exists("/tmp/animate")
            if noise or noise != self.noise:
                self.update()
            self.noise = noise
        def paintEvent(self, e):
            p = QPainter(self)
            p.fillRect(self.rect(), QColor(colour))
            if self.noise:
                for y in range(0, self.height(), 16):
                    for x in range(0, self.width(), 16):
                        p.fillRect(x, y, 16, 16, QColor(random.randrange(1 << 24)))
        def mousePressEvent(self, e):
            self.log.write(f"press {int(e.position().x())} {int(e.position().y())}\n")
        def keyPressEvent(self, e):
            self.log.write(f"key {e.text()}\n")
            if e.text() == "d":
                d = QDialog(self)
                d.setWindowTitle("dialog")
                d.open()

    a = QApplication(sys.argv)
    w = W()
    w.show()
    a.exec()
  '';
  driver = pkgs.writeText "app-screens-driver.py" ''
    import json, os, re, subprocess, time
    from playwright.sync_api import sync_playwright
    from PIL import Image

    OUT = "/tmp/out"
    URL = "http://127.0.0.1:8082/"
    os.makedirs(OUT, exist_ok=True)
    os.chmod(OUT, 0o777)
    summary = open(f"{OUT}/summary.txt", "w")
    results = []

    def note(line):
        print(line, flush=True)
        summary.write(line + "\n")
        summary.flush()

    def check(name, ok, detail=""):
        results.append((name, bool(ok)))
        note(f"{'PASS' if ok else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))

    KWIN = next((n for n in sorted(os.listdir("/run/user/1000"))
                 if n.startswith("wayland-") and not n.endswith(".lock") and n != "wayland-1"), "wayland-0")
    ENV = ("XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
           f"WAYLAND_DISPLAY={KWIN} QT_QPA_PLATFORM=wayland "
           "QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins:${pkgs.qt6.qtwayland}/lib/qt-6/plugins")

    def user(cmd):
        r = subprocess.run(f"runuser -u user -- env {ENV} {cmd}", shell=True, capture_output=True, text=True)
        return (r.stdout + r.stderr).strip()

    def wait_for(pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return True
            time.sleep(1)
        return pred()

    query_n = [0]
    def kwin_js(code):
        query_n[0] += 1
        tag = f"webtop-query-{query_n[0]}"
        path = f"/tmp/{tag}.js"
        with open(path, "w") as f:
            f.write(code.replace("TAG", tag))
        os.chmod(path, 0o644)
        sid = user(f"busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss {path} {tag}")
        user(f"busctl --user call org.kde.KWin /Scripting/Script{sid.split()[-1]} org.kde.kwin.Script run")
        time.sleep(1)
        user(f"busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting unloadScript s {tag}")
        log = subprocess.run(["journalctl", "-b", "--no-pager", "-o", "cat"], capture_output=True, text=True).stdout
        lines = [l for l in log.splitlines() if tag + " " in l]
        return lines[-1].split(tag + " ", 1)[1] if lines else None

    def screens():
        """name -> (x, y, w, h) of every KWin screen."""
        out = kwin_js("print('TAG ' + JSON.stringify(workspace.screens.map(s => "
                      "[s.name, s.geometry.x, s.geometry.y, s.geometry.width, s.geometry.height])));")
        return {s[0]: tuple(s[1:]) for s in json.loads(out)} if out else {}

    def app_screens():
        return sorted(n for n in screens() if n.startswith("SELKIES-"))

    def overlap(sc):
        rects = list(sc.values())
        return [(a, b) for i, a in enumerate(rects) for b in rects[i + 1:]
                if a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]]

    def windows():
        return json.loads(kwin_js(
            "print('TAG ' + JSON.stringify(workspace.windowList().filter(w => w.normalWindow || w.dialog)"
            ".map(w => ({app: w.desktopFileName, dialog: w.transient, "
            "screen: w.output ? w.output.name : null, fullScreen: w.fullScreen}))));") or "[]")

    def active():
        return kwin_js("print('TAG ' + (workspace.activeWindow ? workspace.activeWindow.desktopFileName : 'none'));")

    def main_windows(ws, app_id):
        return [w for w in ws if w["app"] == app_id and not w["dialog"]]

    def placed(app_id, screen):
        ws = main_windows(windows(), app_id)
        return bool(ws) and all(w["screen"] == screen and w["fullScreen"] for w in ws)

    def returned(app_id):
        ws = main_windows(windows(), app_id)
        return bool(ws) and all(w["screen"] and not w["screen"].startswith("SELKIES-") and not w["fullScreen"] for w in ws)

    COLOURS = {"a": (200, 40, 40), "b": (40, 200, 40), "c": (40, 40, 200), "d": (200, 200, 40)}
    APPS = {k: f"test.app.{k}" for k in COLOURS}
    SCREEN = {"a": "SELKIES-3", "b": "SELKIES-4", "c": "SELKIES-5", "d": "SELKIES-6"}
    HASH = {k: "#display" + SCREEN[k].split("-")[1] + "-right" for k in COLOURS}
    SIZE = {"a": (1024, 640), "b": (800, 600), "c": (900, 500), "d": (1024, 640)}

    def start_app(k):
        name = "#%02x%02x%02x" % COLOURS[k]
        return subprocess.Popen(f"runuser -u user -- env {ENV} ${appPy}/bin/python3 ${app} {APPS[k]} '{name}' {OUT}/{k}.log "
                                f"> {OUT}/{k}.out 2>&1", shell=True)

    def log_of(k):
        try:
            return open(f"{OUT}/{k}.log").read().splitlines()
        except FileNotFoundError:
            return []

    def shows(page, k, name):
        """The page's centre pixel is the app's colour."""
        path = f"{OUT}/{name}.png"
        page.screenshot(path=path)
        im = Image.open(path).convert("RGB")
        px = im.getpixel((im.width // 2, im.height // 2))
        return all(abs(p - c) < 50 for p, c in zip(px, COLOURS[k]))

    def click(page, k, x, y):
        """Clicks at (x, y); whether exactly app k logged exactly that press."""
        before = {o: len(log_of(o)) for o in COLOURS}
        page.mouse.move(x, y)
        page.mouse.click(x, y)
        time.sleep(2)
        new = {o: log_of(o)[before[o]:] for o in COLOURS}
        hit = new[k] and new[k][0].split()[0] == "press" and all(
            abs(int(v) - w) <= 1 for v, w in zip(new[k][0].split()[1:], (x, y)))
        others = [o for o in COLOURS if o != k and new[o]]
        note(f"click {k} at {x},{y}: {new}")
        return bool(hit) and not others

    def typed(page, k, text):
        before = {o: len(log_of(o)) for o in COLOURS}
        page.keyboard.type(text)
        time.sleep(2)
        new = {o: log_of(o)[before[o]:] for o in COLOURS}
        note(f"typed {text} for {k}: {new}")
        return new[k] == [f"key {c}" for c in text] and not any(new[o] for o in COLOURS if o != k)

    def open_page(browser, k):
        ctx = browser.new_context(viewport={"width": SIZE[k][0], "height": SIZE[k][1]})
        page = ctx.new_page()
        page.on("console", lambda m: open(f"{OUT}/console-{k}.log", "a").write(f"{m.type}: {m.text}\n"))
        page.goto(URL + HASH[k])
        return ctx, page

    def proc_groups():
        """comm group -> (cpu ticks, rss kB), for the desktop user's processes."""
        out = {}
        for pid in filter(str.isdigit, os.listdir("/proc")):
            try:
                if os.stat(f"/proc/{pid}").st_uid != 1000:
                    continue
                f = open(f"/proc/{pid}/stat").read()
                comm = f[f.index("(") + 1:f.rindex(")")]
                rest = f[f.rindex(")") + 2:].split()
                ticks = int(rest[11]) + int(rest[12])
                rss = int(rest[21]) * 4
                cmd = open(f"/proc/{pid}/cmdline").read()
            except (OSError, ValueError):
                continue
            group = ("kwin_wayland" if "kwin_wayland" in comm else
                     "app" if "test.app." in cmd else
                     "selkies" if "selkies" in cmd else "rest")
            t, r = out.get(group, (0, 0))
            out[group] = (t + ticks, r + rss)
        return out

    def cost(label, seconds=30):
        a = proc_groups()
        time.sleep(seconds)
        b = proc_groups()
        hz = os.sysconf("SC_CLK_TCK")
        row = {g: (round((b[g][0] - a.get(g, (0, 0))[0]) / hz / seconds * 100), round(b[g][1] / 1024)) for g in b}
        session = {g: v for g, v in row.items() if g != "app"}
        note(f"COST {label}: session cpu {sum(v[0] for v in session.values())}% of a core, "
             f"rss {sum(v[1] for v in session.values())} MiB; by group (cpu %, rss MiB): {json.dumps(row, sort_keys=True)}")

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
            for k in "abc":
                note("place: " + user(f"webtop-app-screen place {APPS[k]} {SCREEN[k]}"))
                start_app(k)
            wait_for(lambda: all(main_windows(windows(), APPS[k]) for k in "abc"), 60)

            pages = {k: open_page(browser, k) for k in "abc"}
            page = {k: v[1] for k, v in pages.items()}
            want = sorted(SCREEN[k] for k in "abc")
            check("three pages get three screens", wait_for(lambda: app_screens() == want, 90), str(screens()))
            listed = user("webtop-app-screen screens")
            check("webtop-app-screen screens lists them", listed.split() == want, listed)
            check("the screens overlap nothing", not overlap(screens()), str(screens()))
            for k in "abc":
                check(f"app {k} is fullscreen on its own screen", wait_for(lambda: placed(APPS[k], SCREEN[k]), 30),
                      json.dumps(windows()))
            # KWin can reset a window after it was placed; the script must place it again.
            note("reset: " + str(kwin_js(
                "const w = workspace.windowList().find(w => w.desktopFileName === 'test.app.c' && !w.transient);"
                "w.fullScreen = false; workspace.sendClientToScreen(w, workspace.screens.find(s => !/^SELKIES-/.test(s.name)));"
                "print('TAG done');")))
            check("a window reset by KWin is placed again", wait_for(lambda: placed(APPS["c"], SCREEN["c"]), 15),
                  json.dumps(windows()))
            for k in "abc":
                check(f"page {k} streams only app {k}", wait_for(lambda: shows(page[k], k, f"stream-{k}"), 30))

            for k, (x, y) in {"a": (500, 300), "b": (700, 100), "c": (100, 450)}.items():
                check(f"a click on page {k} reaches app {k} at the page's coordinates, and no other",
                      click(page[k], k, x, y))
            for k in "abc":
                note("focus: " + user(f"webtop-app-screen focus {SCREEN[k]}"))
                time.sleep(1)
                check(f"focusing {SCREEN[k]} makes app {k} the active window", active() == APPS[k], active())
                check(f"keys on page {k} reach app {k} only", typed(page[k], k, "kq"))

            user(f"webtop-app-screen focus {SCREEN['b']}")
            time.sleep(1)
            page["b"].keyboard.type("d")
            def dialog_on_b():
                return [w for w in windows() if w["dialog"] and w["app"] == APPS["b"] and w["screen"] == SCREEN["b"]]
            check("a dialog opens on its app's screen", wait_for(dialog_on_b, 15), json.dumps(windows()))
            page["b"].keyboard.press("Escape")
            check("the dialog closes", wait_for(lambda: not dialog_on_b(), 15), json.dumps(windows()))

            # The main page owns the primary; app pages neither disturb it nor move with it.
            before = screens()
            main_ctx = browser.new_context(viewport={"width": 1600, "height": 900})
            main_page = main_ctx.new_page()
            main_page.goto(URL)
            main = next(n for n in before if not n.startswith("SELKIES-"))
            check("the main page sizes the main screen",
                  wait_for(lambda: screens().get(main, (0, 0, 0, 0))[2:] == (1600, 900), 60), str(screens()))
            after = screens()
            check("the app screens do not overlap the grown main screen", not overlap(after), str(after))
            for k in "abc":
                check(f"page {k} still streams app {k} beside the main page",
                      wait_for(lambda: shows(page[k], k, f"beside-{k}"), 30))
            check("a click on page a still reaches app a", click(page["a"], "a", 300, 200))
            user("webtop-app-screen focus main")
            time.sleep(1)
            check("focus main leaves no app active", active() not in APPS.values(), active())

            positions = screens()
            pages["b"][0].close()
            check("closing the middle page removes only its screen",
                  wait_for(lambda: app_screens() == [SCREEN["a"], SCREEN["c"]], 30), str(screens()))
            check("its app returns to the main screen, not fullscreen", wait_for(lambda: returned(APPS["b"]), 15),
                  json.dumps(windows()))
            check("the others stay where they were", all(screens()[SCREEN[k]] == positions[SCREEN[k]] for k in "ac"),
                  f"{positions} -> {screens()}")
            for k, (x, y) in {"a": (400, 400), "c": (600, 300)}.items():
                check(f"page {k} still works after the close",
                      shows(page[k], k, f"after-close-{k}") and click(page[k], k, x, y))

            pages["b"] = open_page(browser, "b")
            page["b"] = pages["b"][1]
            check("reopening brings its screen back", wait_for(lambda: app_screens() == want, 60), str(screens()))
            check("and its app, fullscreen", wait_for(lambda: placed(APPS["b"], SCREEN["b"]), 30), json.dumps(windows()))
            check("and the stream", wait_for(lambda: shows(page["b"], "b", "reopen-b"), 30))
            check("and input", click(page["b"], "b", 200, 300))

            page["a"].reload()
            check("reloading a page keeps its screen and app", wait_for(lambda: placed(APPS["a"], SCREEN["a"]), 60)
                  and wait_for(lambda: shows(page["a"], "a", "reload-a"), 30), json.dumps(windows()))
            check("input works after reload", click(page["a"], "a", 500, 500))

            taker = open_page(browser, "c")
            check("a second page of a screen takes the stream over",
                  wait_for(lambda: shows(taker[1], "c", "takeover-c"), 30))
            check("and tells the page before it",
                  wait_for(lambda: "Connection Terminated" in page["c"].inner_text("body"), 15))
            check("and input follows", click(taker[1], "c", 300, 200))
            for c in (taker[0], pages["c"][0], pages["a"][0], pages["b"][0], main_ctx):
                c.close()
            check("closing all pages removes all app screens", wait_for(lambda: app_screens() == [], 30), str(screens()))
            for k in "abc":
                check(f"app {k} is back on the main screen", wait_for(lambda: returned(APPS[k]), 15), json.dumps(windows()))

            # Cost: software rendering, JPEG (the headless browser has no H.264), every screen 1024x640.
            note("place: " + user(f"webtop-app-screen place {APPS['d']} {SCREEN['d']}"))
            start_app("d")
            SIZE.update({k: (1024, 640) for k in "abc"})
            time.sleep(10)
            cost("0 screens, idle")
            for n in (1, 2, 4):
                ctxs = [(k, open_page(browser, k)) for k in "abcd"[:n]]
                wait_for(lambda: len(app_screens()) == n, 60)
                check(f"{n} screens up for the measurement",
                      all(wait_for(lambda: shows(c[1], k, f"cost-{n}-{k}"), 30) for k, c in ctxs))
                cost(f"{n} screens, idle apps")
                open("/tmp/animate", "w").close()
                time.sleep(5)
                cost(f"{n} screens, every app repainting all pixels at 30 fps")
                os.remove("/tmp/animate")
                if n < 4:
                    for _, c in ctxs:
                        c[0].close()
                    wait_for(lambda: app_screens() == [], 30)

            start = time.time()
            note(user("systemctl --user stop selkies.service"))
            took = time.time() - start
            check("Selkies stops with four pages open", took < 60, f"{took:.0f} s")
            browser.close()
    except Exception as e:
        check("driver ran to the end", False, repr(e))
    finally:
        subprocess.run(["pkill", "-f", "test.app"])
        subprocess.run(f"journalctl -b --no-pager -o short-monotonic > {OUT}/journal.txt", shell=True)
        failed = [n for n, ok in results if not ok]
        note(f"{len(results) - len(failed)}/{len(results)} passed")
        summary.close()
        raise SystemExit(1 if failed or not results else 0)
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-app-screens";
  node.pkgsReadOnly = false;
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # The headless browser has no H.264; JPEG needs no codec.
    services.webtop.extraEnvironment.SELKIES_ENCODER = "jpeg";
    virtualisation.memorySize = 8192;
    virtualisation.cores = 4;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_open_port(8082)
    machine.wait_for_unit("webtop-session.service")
    ${import ./wait-compositing.nix}
    machine.sleep(20)  # let Plasma settle
    status, output = machine.execute(
        "PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers} "
        "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true ${py}/bin/python3 ${driver} 2>&1",
        timeout=1500,
    )
    print(output)
    machine.copy_from_machine("/tmp/out")
    assert status == 0, "app screens checks failed, see summary above"
    machine.shutdown()
  '';
}
