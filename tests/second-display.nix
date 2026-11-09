# One app on its own screen, streamed by a Selkies second-display page with no primary page open:
# the screen is grown, streams, takes input at the page's coordinates, keeps the app's windows
# (also ones opened later), goes away with the page and hands the windows back (also on release). Writes summary.txt, screenshots and logs to
# the output directory, also on failure, then asserts.
{ pkgs, self }:

let
  py = pkgs.python3.withPackages (ps: [ ps.playwright ps.pillow ]);
  screen = "SELKIES-2"; # the screen Selkies grows for display2
  driver = pkgs.writeText "second-display-driver.py" ''
    import json, os, re, subprocess, time
    from playwright.sync_api import sync_playwright
    from PIL import Image, ImageStat

    OUT = "/tmp/out"
    URL = "http://127.0.0.1:8082/"
    SCREEN = "${screen}"
    PAGE_W, PAGE_H = 1024, 640
    os.makedirs(OUT, exist_ok=True)
    summary = open(f"{OUT}/summary.txt", "w")
    results = []

    def note(line):
        print(line, flush=True)
        summary.write(line + "\n")
        summary.flush()

    def check(name, ok, detail=""):
        results.append((name, bool(ok)))
        note(f"{'PASS' if ok else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))

    # KWin's own socket: the one besides Selkies' wayland-1.
    KWIN = next((n for n in sorted(os.listdir("/run/user/1000"))
                 if n.startswith("wayland-") and not n.endswith(".lock") and n != "wayland-1"), "wayland-0")
    ENV = ("XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
           f"WAYLAND_DISPLAY={KWIN} QT_QPA_PLATFORM=wayland")

    def user(cmd):
        r = subprocess.run(f"runuser -u user -- env {ENV} {cmd}", shell=True, capture_output=True, text=True)
        return (r.stdout + r.stderr).strip()

    def screens():
        out = user("kscreen-doctor -o 2>&1")
        return re.findall(r"Output: \d+ (\S+)", re.sub(r"\x1b\[[0-9;]*m", "", out))

    def wait_for(pred, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return True
            time.sleep(1)
        return pred()

    def shot(page, name):
        path = f"{OUT}/{name}.png"
        page.screenshot(path=path)
        stat = ImageStat.Stat(Image.open(path).convert("L"))
        return stat.mean[0], stat.stddev[0]

    query_n = [0]
    def kwin_js(code):
        """Runs a one-shot KWin script; returns what it print()s, after its tag."""
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

    def windows():
        """[{id, app, screen, fullScreen}] of every normal window."""
        return json.loads(kwin_js("print('TAG ' + JSON.stringify(workspace.windowList().filter(w => w.normalWindow)"
                                  ".map(w => ({id: String(w.internalId), app: w.resourceClass, "
                                  "screen: w.output ? w.output.name : null, fullScreen: w.fullScreen}))));"))

    def app_windows(app):
        return [w for w in windows() if w["app"] == app]

    def on_main_normal(ws):
        return bool(ws) and all(w["screen"] not in (None, SCREEN) and not w["fullScreen"] for w in ws)

    def on_app_screen(ws):
        return bool(ws) and all(w["screen"] == SCREEN and w["fullScreen"] for w in ws)

    def wev(n):
        return subprocess.Popen(
            f"runuser -u user -- env {ENV} ${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.wev}/bin/wev "
            f"> {OUT}/wev-{n}.log 2>&1", shell=True)

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
            ctx = browser.new_context(viewport={"width": PAGE_W, "height": PAGE_H})
            page = ctx.new_page()
            page.on("console", lambda m: open(f"{OUT}/console.log", "a").write(f"{m.type}: {m.text}\n"))

            note(f"screens before: {screens()}")
            page.goto(URL + "#display2-right")
            check("screen appears for a display2 page with no primary page",
                  wait_for(lambda: SCREEN in screens(), 60), f"screens: {screens()}")

            stats = []
            def streaming():
                stats.append(shot(page, "display2"))
                mean, sd = stats[-1]
                return mean > 20 and sd > 5
            check("the page streams non-black frames", wait_for(streaming, 30),
                  "mean %.1f, stddev %.1f" % stats[-1])

            wev(1)
            time.sleep(5)
            note("place: " + user(f"webtop-app-screen place wev {SCREEN}"))
            time.sleep(3)
            ws = [w for w in windows() if w["app"] == "wev"]
            check("app window moved to its screen, fullscreen",
                  len(ws) == 1 and ws[0]["screen"] == SCREEN and ws[0]["fullScreen"], json.dumps(ws))
            shot(page, "display2-app")

            page.mouse.move(500, 300)
            page.mouse.click(500, 300)
            time.sleep(1)
            page.keyboard.type("kq")
            time.sleep(3)
            log = open(f"{OUT}/wev-1.log").read()
            enter = re.search(r"wl_pointer\] enter: .*x, y: ([\d.]+), ([\d.]+)", log)
            check("pointer arrives at the page's coordinates",
                  enter and abs(float(enter.group(1)) - 500) < 1 and abs(float(enter.group(2)) - 300) < 1,
                  enter.group(0) if enter else "no enter event")
            check("click arrives", "button: 272 (left), state: 1 (pressed)" in log
                  and "button: 272 (left), state: 0 (released)" in log)
            syms = re.findall(r"sym: (\w+)\s+\(\d+\), utf8: '(\w)'", log)
            check("keys arrive", [s for s, _ in syms] == ["k", "q"], f"syms: {syms}")

            wev(2)
            time.sleep(5)
            ws = [w for w in windows() if w["app"] == "wev"]
            check("a window opened later lands on the app's screen",
                  len(ws) == 2 and all(w["screen"] == SCREEN for w in ws), json.dumps(ws))
            shot(page, "display2-second-window")

            ctx.close()
            check("closing the page removes the screen", wait_for(lambda: SCREEN not in screens(), 30),
                  f"screens: {screens()}")
            check("the windows go back to the main screen, not fullscreen (panel reachable)",
                  wait_for(lambda: on_main_normal(app_windows("wev")), 15), json.dumps(app_windows("wev")))

            ctx = browser.new_context(viewport={"width": PAGE_W, "height": PAGE_H})
            page = ctx.new_page()
            page.goto(URL + "#display2-right")
            check("the screen coming back takes the windows again",
                  wait_for(lambda: on_app_screen(app_windows("wev")), 60), json.dumps(app_windows("wev")))

            note("release: " + user("webtop-app-screen release wev"))
            time.sleep(2)
            check("release sends the windows to the main screen, not fullscreen",
                  on_main_normal(app_windows("wev")), json.dumps(app_windows("wev")))

            subprocess.Popen(f"runuser -u user -- env {ENV} ${pkgs.kdePackages.kcalc}/bin/kcalc", shell=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            wait_for(lambda: app_windows("org.kde.kcalc"), 30)
            note("place B: " + user(f"webtop-app-screen place org.kde.kcalc {SCREEN}"))
            check("a second app replaces the first on the app screen",
                  wait_for(lambda: on_app_screen(app_windows("org.kde.kcalc")), 15)
                  and on_main_normal(app_windows("wev")),
                  json.dumps(windows()))
            note("release B: " + user("webtop-app-screen release org.kde.kcalc"))
            subprocess.run(["pkill", "-f", "bin/kcalc"])

            # A window the user fullscreened before place stays fullscreen when the screen goes.
            first = app_windows("wev")[0]["id"]
            note("user fullscreen: " + json.dumps(kwin_js("workspace.windowList().filter(w => String(w.internalId) === '%s').forEach(w => { w.fullScreen = true; print('TAG ' + w.fullScreen); });" % first)))
            note("place again: " + user(f"webtop-app-screen place wev {SCREEN}"))
            check("both windows on the app screen again",
                  wait_for(lambda: on_app_screen(app_windows("wev")), 15), json.dumps(app_windows("wev")))
            ctx.close()
            wait_for(lambda: SCREEN not in screens(), 30)
            time.sleep(3)
            ws = {w["id"]: w for w in app_windows("wev")}
            check("only the window the user fullscreened stays fullscreen",
                  len(ws) == 2 and ws[first]["fullScreen"] and ws[first]["screen"] != SCREEN
                  and all(not w["fullScreen"] for i, w in ws.items() if i != first), json.dumps(ws))
            browser.close()
    except Exception as e:
        check("driver ran to the end", False, repr(e))
    finally:
        subprocess.run(["pkill", "-f", "bin/wev"])
        subprocess.run(f"journalctl -b --no-pager -o short-monotonic > {OUT}/journal.txt", shell=True)
        failed = [n for n, ok in results if not ok]
        note(f"{len(results) - len(failed)}/{len(results)} passed")
        summary.close()
        raise SystemExit(1 if failed or not results else 0)
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-second-display";
  node.pkgsReadOnly = false;
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # The headless browser has no H.264; JPEG needs no codec.
    services.webtop.extraEnvironment.SELKIES_ENCODER = "jpeg";
    environment.systemPackages = [ pkgs.wev pkgs.kdePackages.libkscreen pkgs.kdePackages.kcalc ];
    virtualisation.memorySize = 6144;
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
        timeout=900,
    )
    print(output)
    machine.copy_from_machine("/tmp/out")
    assert status == 0, "second display checks failed, see summary above"
  '';
}
