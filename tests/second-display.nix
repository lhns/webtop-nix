# Spike: can a Selkies second display (#display2-<pos>) get its own KWin screen, stream it and take
# input, (a) with no primary page connected and (b) beside a primary page? Records evidence in $out
# (summary.txt, screenshots, logs) instead of asserting, so one run answers every case.
{ pkgs, self }:

let
  py = pkgs.python3.withPackages (ps: [ ps.playwright ps.pillow ]);
  # Selkies lays out a second display only beside a connected primary page. This lays it out
  # beside the primary screen at its last size when no primary page is connected.
  soloPatch = pkgs.writeText "selkies-solo-secondary.py" ''
    import sys
    path = sys.argv[1]
    src = open(path).read()
    anchor = "                layouts[secondary_id] = computed['secondary']\n"
    assert src.count(anchor) == 1, "anchor"
    src = src.replace(anchor, anchor + """
            elif secondary_client:
                prev = (getattr(self, 'display_layouts', None) or {}).get('primary') or {}
                p_w, p_h = prev.get('w') or 1280, prev.get('h') or 720
                s_w, s_h = secondary_client.get('width', 0), secondary_client.get('height', 0)
                position = secondary_client.get('position', 'right')
                if position not in ('right', 'left', 'up', 'down'):
                    position = 'right'
                if s_w > 0 and s_h > 0:
                    computed, total_width, total_height = compute_dual_layout(
                        (p_w, p_h), (s_w, s_h), position
                    )
                    layouts['primary'] = computed['primary']
                    layouts[secondary_id] = computed['secondary']
                    data_logger.info("Secondary-only layout: primary screen kept at %dx%d" % (p_w, p_h))
    """)
    open(path, "w").write(src)
  '';
  selkiesSolo = pkgs.selkies.overridePythonAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      ${pkgs.python3}/bin/python3 ${soloPatch} $out/lib/python*/site-packages/selkies/websockets_mode.py
    '';
  });
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

    # KWin's own socket: the one besides Selkies' wayland-1.
    KWIN = next((n for n in sorted(os.listdir("/run/user/1000"))
                 if n.startswith("wayland-") and not n.endswith(".lock") and n != "wayland-1"), "wayland-0")

    def user(cmd):
        env = ("XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
               f"WAYLAND_DISPLAY={KWIN} QT_QPA_PLATFORM=wayland")
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

        note(f"runtime dir: {sorted(os.listdir('/run/user/1000'))}, KWin socket: {KWIN}")
        note("screens at start:\n" + screens())

        def probe_input(page, tag):
            # A probe app on the newest screen, then a click and keys through the display2 page.
            log = f"{OUT}/wev-{tag}.log"
            subprocess.Popen(
                f"runuser -u user -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY={KWIN} "
                f"${pkgs.coreutils}/bin/stdbuf -oL ${pkgs.wev}/bin/wev > {log} 2>&1", shell=True)
            time.sleep(5)
            sid = user(f"busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting loadScript ss ${placeScript} probe-{tag}")
            note(f"  loadScript: {sid}")
            try:
                n = sid.split()[-1]
                note("  run: " + user(f"busctl --user call org.kde.KWin /Scripting/Script{n} org.kde.kwin.Script run"))
            except Exception as e:
                note(f"  run failed: {e}")
            time.sleep(5)
            shot(page, f"{tag}-probe")
            mark(f"{tag}-input")
            page.mouse.move(500, 300)
            page.mouse.click(512, 320)
            time.sleep(1)
            page.keyboard.type("kq")
            time.sleep(3)
            shot(page, f"{tag}-after-input")
            text = open(log).read()
            note(f"  wev pointer enter events: {text.count('wl_pointer] enter')}")
            note(f"  wev button events: {text.count('wl_pointer] button')}")
            note(f"  wev key events: {text.count('wl_keyboard] key')}")
            subprocess.run(["pkill", "-f", "bin/wev"])
            time.sleep(2)

        # (a) the second display alone
        mark("phase-a-start")
        ctx_b, page_b = open_page("#display2-right", 1024, 640, "a-display2")
        time.sleep(30)
        note("phase a (display2, no primary): screens:\n" + screens())
        shot(page_b, "a-display2")
        probe_input(page_b, "a-display2")
        ctx_b.close()
        mark("phase-a-end")
        time.sleep(8)

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
        probe_input(page_b, "b-display2")
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
    services.webtop.package = selkiesSolo;
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
