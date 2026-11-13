# The page opened last owns the primary display and the pages before it stay connected beside it.
# Runs the real patched server: scripted websocket clients for the protocol, then a real browser for
# what the web client does when demoted, resized or cut off. Writes summary.txt and screenshots to
# the output directory, also on failure, then asserts.
{ pkgs, self }:

let
  py = pkgs.python3.withPackages (ps: [ ps.aiohttp ps.playwright ps.pillow ]);
  driver = pkgs.writeText "latest-owner-driver.py" ''
    import asyncio, json, os, re, subprocess, threading, time
    import aiohttp
    from playwright.sync_api import sync_playwright
    from PIL import Image, ImageStat

    OUT = "/tmp/out"
    WS = "ws://127.0.0.1:8082/api/websockets"
    SPACING = 1.0  # above the server's per-address reconnect debounce
    GRACE = 8.0  # above the server's reconnect grace, for a promotion to happen
    SETTLE = 4.0  # how long a resize that must not apply is given to apply
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

    class Page:
        """A scripted web client: what the page sends for the primary display, and what it was told."""

        def __init__(self, tab, size, reconnecting=False):
            self.tab, self.size, self.reconnecting = tab, size, reconnecting
            self.res, self.texts = None, []
            self.frames, self.closed = 0, False

        def settings(self):
            s = {"displayId": "primary", "manual_resolution": False, "useCssScaling": True, "displayScale": 1,
                 "initialClientWidth": self.size[0], "initialClientHeight": self.size[1], "audioRedundancy": True}
            if self.tab:
                s["tabId"] = self.tab
            if self.reconnecting:
                s["reconnecting"] = True
            return "SETTINGS," + json.dumps(s)

        async def open(self, http):
            await asyncio.sleep(SPACING)
            self.ws = await http.ws_connect(WS)
            self.reader = asyncio.create_task(self.read())
            await self.ws.send_str(self.settings())

        async def read(self):
            async for msg in self.ws:
                if msg.type == aiohttp.WSMsgType.BINARY:
                    self.frames += 1
                elif msg.type == aiohttp.WSMsgType.TEXT:
                    self.texts.append(msg.data[:200])
                    if msg.data.startswith("{"):
                        m = json.loads(msg.data)
                        if m.get("type") == "stream_resolution" and m.get("displayId") == "primary":
                            self.res = (m["width"], m["height"])
            self.closed = True

        def told(self, prefix):
            return any(t.startswith(prefix) for t in self.texts)

        async def send(self, text):
            await self.ws.send_str(text)

        async def resize(self, size):
            self.size = size
            await self.send(f"r,{size[0]}x{size[1]},primary")

        async def close(self):
            await self.ws.close()
            await self.reader

    async def until(pred, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            if pred():
                return True
            await asyncio.sleep(0.25)
        return pred()

    async def frames_flow(page):
        start = page.frames
        return await until(lambda: page.frames > start + 2, 20)

    async def owns(page, witness, size):
        """Whether a resize from `page` applies, as `witness` sees it."""
        await page.resize(size)
        return await until(lambda: witness.res == size, 20)

    async def scripted():
        async with aiohttp.ClientSession() as http:
            a = Page("tab-a", (1024, 640))
            await a.open(http)
            check("first page sizes the desktop", await until(lambda: a.res == a.size), f"{a.res}")
            check("first page receives frames", await frames_flow(a), f"{a.frames}")

            b = Page("tab-b", (800, 480))
            await b.open(http)
            check("page B of another tab takes the display", await until(lambda: a.res == b.size), f"A told {a.res}")
            check("A is not closed or killed", not a.closed and not a.told("KILL"))
            check("A is told the stream was reset", await until(lambda: a.told("PIPELINE_RESETTING primary"), 5))
            check("A is told what the display streams with", await until(lambda: a.told('{"type": "display_settings"'), 5))
            check("A still receives frames", await frames_flow(a), f"{a.frames}")

            check("a resize from B applies", await owns(b, a, (960, 544)), f"A told {a.res}")
            current = a.res
            await a.resize((1280, 736))
            await asyncio.sleep(SETTLE)
            check("a resize from A does not apply", b.res == current, f"B told {b.res}")
            check("A is told the size back after its resize", a.res == current, f"{a.res}")

            await a.send(a.settings())
            await asyncio.sleep(SETTLE)
            check("SETTINGS from a page beside the owner does not take over", b.res == current and not b.closed, f"{b.res}")
            check("B still owns after that SETTINGS", await owns(b, a, (800, 480)), f"A told {a.res}")

            a.texts.clear(); b.texts.clear()
            await b.send("STOP_AUDIO")
            check("the owner's audio stop reaches the owner", await until(lambda: b.told("AUDIO_STOPPED"), 5))
            check("the owner's audio stop leaves the page beside it alone", not a.told("AUDIO_STOPPED"))
            await b.send("START_AUDIO")

            r = Page("tab-r", (640, 480), reconnecting=True)
            await r.open(http)
            await asyncio.sleep(SETTLE)
            check("a reconnecting page does not claim the display", b.res == (800, 480) and not b.closed, f"B told {b.res}")
            check("a reconnecting page is streamed", await frames_flow(r), f"{r.frames}")
            await r.close()

            a.texts.clear()
            await b.close()
            check("A is promoted when the owner leaves", await until(lambda: a.told("DISPLAY_OWNER primary"), GRACE * 2))
            a.size = (1024, 640)
            await a.send(a.settings())
            check("the promoted page sizes the desktop", await until(lambda: a.res == a.size), f"{a.res}")
            check("a resize from the promoted page applies", await owns(a, a, (960, 544)), f"{a.res}")

            b = Page("tab-b", (800, 480))
            await b.open(http)
            check("B opened again takes the display", await until(lambda: a.res == b.size), f"A told {a.res}")
            await a.close()
            a = Page("tab-a", (1024, 640))
            await a.open(http)
            check("A reloading becomes the owner", await until(lambda: b.res == a.size), f"B told {b.res}")
            check("B stays connected", not b.closed and not b.told("KILL"))
            current = b.res
            await b.resize((1280, 736))
            await asyncio.sleep(SETTLE)
            check("the page reloaded last keeps the size", a.res == current, f"A told {a.res}")

            overlap = Page("tab-a", (960, 544))
            await overlap.open(http)
            check("a second socket of the owner's tab replaces it", await until(lambda: a.closed), f"told KILL: {a.told('KILL')}")
            check("that socket owns the display", await until(lambda: b.res == overlap.size), f"B told {b.res}")

            old = Page(None, (800, 480))
            await old.open(http)
            check("a page naming no tab kills the owner, as before", await until(lambda: overlap.closed and overlap.told("KILL")))
            check("a page naming no tab owns the display", await until(lambda: b.res == old.size), f"B told {b.res}")
            await old.close()
            await b.close()

            # Opened laptop, monitor, phone: closing the phone hands the desktop to the
            # monitor, the newest page left, not the laptop beside it.
            lap = Page("tab-lap", (1024, 640))
            await lap.open(http)
            check("laptop sizes the desktop", await until(lambda: lap.res == lap.size), f"{lap.res}")
            mon = Page("tab-mon", (800, 480))
            await mon.open(http)
            check("monitor takes the display", await until(lambda: lap.res == mon.size), f"laptop told {lap.res}")
            phone = Page("tab-phone", (480, 800))
            await phone.open(http)
            check("phone takes the display", await until(lambda: mon.res == phone.size), f"monitor told {mon.res}")
            lap.texts.clear(); mon.texts.clear()
            await phone.close()
            check("the monitor is promoted when the phone leaves", await until(lambda: mon.told("DISPLAY_OWNER primary"), GRACE * 2))
            check("the laptop is not promoted", not lap.told("DISPLAY_OWNER primary"))
            await mon.send(mon.settings())
            check("the promoted monitor sizes the desktop", await until(lambda: lap.res == mon.size), f"laptop told {lap.res}")
            await mon.close()
            await lap.close()

    class Proxy(threading.Thread):
        """A TCP proxy a page connects through, so its socket can be cut with no close frame."""

        def __init__(self, port, target):
            super().__init__(daemon=True)
            self.port, self.target, self.loop, self.pairs = port, target, None, []
            self.ready = threading.Event()

        def run(self):
            asyncio.run(self.serve())

        async def serve(self):
            self.loop = asyncio.get_running_loop()
            server = await asyncio.start_server(self.handle, "127.0.0.1", self.port)
            self.ready.set()
            await server.serve_forever()

        async def handle(self, reader, writer):
            up_reader, up_writer = await asyncio.open_connection("127.0.0.1", self.target)
            self.pairs.append((writer, up_writer))
            async def pipe(src, dst):
                try:
                    while data := await src.read(65536):
                        dst.write(data)
                        await dst.drain()
                except (ConnectionError, asyncio.CancelledError):
                    pass
                dst.close()
            await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))

        def cut(self):
            def abort():
                for pair in self.pairs:
                    for w in pair:
                        w.transport.abort()
                self.pairs.clear()
            self.loop.call_soon_threadsafe(abort)

    def video_box(page):
        """The width and height the stream is shown at in the page."""
        return page.evaluate("""() => {
            let best = [0, 0];
            for (const e of document.querySelectorAll('canvas, video')) {
                const r = e.getBoundingClientRect();
                if (r.width * r.height > best[0] * best[1]) best = [r.width, r.height];
            }
            return best;
        }""")

    def aspect_is(page, size):
        w, h = video_box(page)
        return h > 0 and abs(w / h - size[0] / size[1]) < 0.03

    def wait_aspect(page, size, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            if aspect_is(page, size):
                return True
            page.wait_for_timeout(500)
        return aspect_is(page, size)

    def shows_desktop(page, name):
        page.wait_for_timeout(2000)
        path = f"{OUT}/{name}.png"
        page.screenshot(path=path)
        stat = ImageStat.Stat(Image.open(path).convert("L"))
        return stat.stddev[0] > 1, f"mean {stat.mean[0]:.1f} stddev {stat.stddev[0]:.1f}, box {video_box(page)}"

    def wait_console(page, text, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if any(text in m for m in page.console):
                return True
            page.wait_for_timeout(250)
        return False

    def browser():
        proxy = Proxy(18082, 8082)
        proxy.start()
        proxy.ready.wait()
        with sync_playwright() as p:
            chromium = p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"])
            def open_page(url, size):
                ctx = chromium.new_context(viewport={"width": size[0], "height": size[1]})
                page = ctx.new_page()
                page.console = []
                page.assets = {}
                page.on("response", lambda r: page.assets.update({r.url.rsplit("/", 1)[-1]: r.status}) if "/assets/" in r.url else None)
                page.on("console", lambda m: page.console.append(m.text))
                page.goto(url)
                return page
            a = open_page("http://127.0.0.1:18082/", (1024, 640))
            check("browser: A shows the desktop", wait_aspect(a, (1024, 640)), f"{video_box(a)}")
            for kind in ("index-", "selkies-core-"):
                loaded = {n: c for n, c in a.assets.items() if n.startswith(kind) and re.search(r"-[\w-]{8}\.\w+$", n)}
                check(f"browser: the content-hashed {kind}* asset loaded", loaded and all(c == 200 for c in loaded.values()), f"{a.assets}")
            time.sleep(SPACING)
            b = open_page("http://127.0.0.1:8082/", (640, 640))
            check("browser: A fits the size of B, which owns the display", wait_aspect(a, (640, 640)), f"{video_box(a)}")
            check("browser: B fills its window", wait_aspect(b, (640, 640)), f"{video_box(b)}")
            check("browser: A keeps rendering after being demoted", *shows_desktop(a, "a-demoted"))
            check("browser: A was not terminated", not any("KILL" in m for m in a.console))

            a.set_viewport_size({"width": 1200, "height": 640})
            a.wait_for_timeout(int(SETTLE * 1000))
            check("browser: A's own resize leaves the desktop alone", aspect_is(b, (640, 640)), f"{video_box(b)}")
            check("browser: A still fits B's size after its own resize", wait_aspect(a, (640, 640), 10), f"{video_box(a)}")
            check("browser: A keeps rendering after its own resize", *shows_desktop(a, "a-resized"))

            b.set_viewport_size({"width": 800, "height": 400})
            check("browser: a resize of B applies and A follows", wait_aspect(a, (800, 400)), f"{video_box(a)}")

            proxy.cut()
            check("browser: A cut off reconnects in place", wait_console(a, "Reconnecting in place", 20))
            a.wait_for_timeout(int(GRACE * 1000))
            check("browser: A's reconnect does not take the display", aspect_is(b, (800, 400)) and aspect_is(a, (800, 400)),
                  f"A {video_box(a)}, B {video_box(b)}")
            check("browser: A renders after its reconnect", *shows_desktop(a, "a-reconnected"))

            b.reload()
            check("browser: B reloading keeps the display", wait_aspect(a, (800, 400)), f"{video_box(a)}")
            time.sleep(SPACING)
            a.reload()
            check("browser: A reloading takes the display", wait_aspect(b, (1200, 640)), f"{video_box(b)}")
            check("browser: B keeps rendering after being demoted", *shows_desktop(b, "b-demoted"))
            time.sleep(SPACING)
            a.close()
            check("browser: B is promoted and sizes the desktop", wait_aspect(b, (800, 400), 30), f"{video_box(b)}")
            check("browser: the promoted page renders", *shows_desktop(b, "b-promoted"))
            chromium.close()

    # The capture sends no frame for a still screen.
    moving = subprocess.Popen(
        ["runuser", "-u", "user", "--", "env", "XDG_RUNTIME_DIR=/run/user/1000",
         "WAYLAND_DISPLAY=" + next(n for n in sorted(os.listdir("/run/user/1000"))
                                   if n.startswith("wayland-") and not n.endswith(".lock") and n != "wayland-1"),
         "${pkgs.foot}/bin/foot", "sh", "-c", "while :; do date +%N; sleep 0.1; done"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(5)
    note(f"moving window running: {moving.poll() is None}")
    try:
        asyncio.run(scripted())
    except Exception as e:
        check("scripted clients ran to the end", False, repr(e))
    time.sleep(GRACE)
    try:
        browser()
    except Exception as e:
        check("browser run ran to the end", False, repr(e))
    moving.terminate()
    failed = [n for n, ok in results if not ok]
    note(f"{len(results) - len(failed)}/{len(results)} passed")
    raise SystemExit(1 if failed else 0)
  '';
in
pkgs.testers.runNixOSTest {
  name = "webtop-latest-owner";
  node.pkgsReadOnly = false;
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.webtop ];
    services.webtop.enable = true;
    # The headless browser has no H.264; JPEG needs no codec.
    services.webtop.extraEnvironment.SELKIES_ENCODER = "jpeg";
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
    assert status == 0, "latest owner checks failed, see summary above"
  '';
}
