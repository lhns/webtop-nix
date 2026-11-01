# Spike: can a Selkies second display (#display2-<pos>) get its own KWin screen, stream it and take
# input, (a) with no primary page connected and (b) beside a primary page? Records evidence in $out
# (summary.txt, screenshots, logs) instead of asserting, so one run answers every case.
{ pkgs, self }:

let
  py = pkgs.python3.withPackages (ps: [ ps.playwright ps.pillow ]);
  # Sends every window of the probe app to the newest screen, fullscreen and focused.
  placeScript = pkgs.writeText "place-probe.js" ''
    const screens = workspace.screens;
    print("probe: screens " + screens.map(s => s.name + "@" + JSON.stringify(s.geometry)).join(" "));
    const target = screens[screens.length - 1];
    for (const w of workspace.windowList()) {
      if (w.resourceClass === "wev" || w.caption.indexOf("wev") >= 0) {
        workspace.sendClientToScreen(w, target);
        w.fullScreen = true;
        workspace.activeWindow = w;
        print("probe: moved " + w.caption + " to " + target.name + " " + JSON.stringify(w.frameGeometry));
      }
    }
  '';
  driver = pkgs.writeText "second-display-driver.py" ''
    import os, subprocess, time
    from playwright.sync_api import sync_playwright
    from PIL import Image, ImageStat

    OUT = "/tmp/out"
    URL = "http://127.0.0.1:8082/"
    os.makedirs(OUT, exist_ok=True)
    summary = open(f"{OUT}/summary.txt", "w")

    def note(line):
        print(line, flush=True)
        summary.write(line + "\n")
        summary.flush()

    def user(cmd):
        env = ("XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
               "WAYLAND_DISPLAY=wayland-0")
        r = subprocess.run(f"runuser -u user -- env {env} {cmd}", shell=True, capture_output=True, text=True)
        return (r.stdout + r.stderr).strip()

    def screens():
        return user("kscreen-doctor -o 2>&1 | sed 's/\\x1b\\[[0-9;]*m//g' | grep -E '^Output|Geometry'")

    def shot(page, name):
        path = f"{OUT}/{name}.png"
        page.screenshot(path=path)
        img = Image.open(path).convert("L")
        st = ImageStat.Stat(img)
        lo, hi = img.getextrema()
        note(f"  screenshot {name}: mean={st.mean[0]:.1f} stddev={st.stddev[0]:.1f} range={lo}-{hi}")

    def mark(label):
        subprocess.run(["logger", "-t", "probe", label])

    def journal(since_label, path):
        subprocess.run(f"journalctl -b --no-pager -o short-monotonic > {OUT}/{path}", shell=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])

        def open_page(fragment, w, h, name):
            ctx = browser.new_context(viewport={"width": w, "height": h})
            page = ctx.new_page()
            page.on("console", lambda m: open(f"{OUT}/console-{name}.log", "a").write(f"{m.type}: {m.text}\n"))
            page.goto(URL + fragment)
            return ctx, page

        note("screens at start:\n" + screens())

        # (a) the second display alone
        mark("phase-a-start")
        ctx_b, page_b = open_page("#display2-right", 1024, 640, "a-display2")
        time.sleep(30)
        note("phase a (display2, no primary): screens:\n" + screens())
        shot(page_b, "a-display2")
        ctx_b.close()
        mark("phase-a-end")
        time.sleep(5)

        # (b) primary first, then the second display
        mark("phase-b-start")
        ctx_a, page_a = open_page("", 1280, 720, "b-primary")
        time.sleep(20)
        shot(page_a, "b-primary-alone")
        ctx_b, page_b = open_page("#display2-right", 1024, 640, "b-display2")
        time.sleep(30)
        note("phase b (primary + display2): screens:\n" + screens())
        shot(page_a, "b-primary")
        shot(page_b, "b-display2")

        # Input: a probe app on the newest screen, then a click and keys through the display2 page.
        wev = subprocess.Popen(
            "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 "
            f"${pkgs.wev}/bin/wev > {OUT}/wev.log 2>&1", shell=True)
        time.sleep(5)
        sid = user("busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss ${placeScript} probe")
        note(f"  loadScript: {sid}")
        try:
            n = sid.split()[-1]
            note("  run: " + user(f"busctl --user call org.kde.KWin /Scripting/Script{n} org.kde.kwin.Script run"))
        except Exception as e:
            note(f"  run failed: {e}")
        time.sleep(5)
        shot(page_b, "b-display2-probe")
        mark("phase-b-input")
        page_b.mouse.move(500, 300)
        page_b.mouse.click(512, 320)
        time.sleep(1)
        page_b.keyboard.type("kq")
        time.sleep(3)
        shot(page_b, "b-display2-after-input")
        log = open(f"{OUT}/wev.log").read()
        note(f"  wev pointer enter events: {log.count('wl_pointer] enter')}")
        note(f"  wev button events: {log.count('wl_pointer] button')}")
        note(f"  wev key events: {log.count('wl_keyboard] key')}")
        wev.terminate()
        mark("phase-b-end")
        browser.close()

    journal("", "journal.txt")
    summary.close()
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-second-display";
  node.pkgsReadOnly = false;
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # The page decodes JPEG with no codec dependency; the headless browser has no H.264.
    services.webtop.extraEnvironment.SELKIES_ENCODER = "jpeg";
    environment.systemPackages = [ pkgs.wev pkgs.kdePackages.libkscreen ];
    environment.variables.PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
  };
  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("selkies.service", "user")
    machine.wait_for_open_port(8082)
    machine.wait_for_unit("webtop-session.service")
    machine.wait_until_succeeds(
        "runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
        "busctl --user get-property org.kde.KWin /Compositor org.kde.kwin.Compositing active | grep -qx 'b true'",
        timeout=180,
    )
    machine.sleep(20)  # let Plasma settle
    print(machine.succeed(
        "PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers} "
        "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true ${py}/bin/python3 ${driver} 2>&1",
        timeout=900,
    ))
    machine.succeed("journalctl -b --no-pager -o short-monotonic | grep -iE 'screen|display2|layout|probe|virtual|aborting' > /tmp/out/journal-filtered.txt || true")
    machine.copy_from_machine("/tmp/out")
  '';
}
