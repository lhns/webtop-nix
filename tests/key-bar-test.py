"""key-bar.js in mobile-emulated Chromium, against tests/key-bar-stub.js (a webrtcInput with the shipped
client's key handling). A real Android keyboard is not covered. With --built DIR (a selkies_web
directory) it only checks that the built client loads the bar.
Run: pip install playwright && playwright install chromium && python3 tests/key-bar-test.py"""
import functools
import http.server
import os
import sys
import threading

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
SEL = os.path.join(HERE, "..", "pkgs", "selkies")
ESC, TAB, CTRL, ALT, LEFT, BS, C = 65307, 65289, 65507, 65513, 65361, 65288, 99
PAGE = ("<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
        "<div class=toggle-handle style='position:fixed;left:8px;top:50%;width:44px;height:72px;z-index:1020'></div>"
        "<input id=keyboard-input-assist style='position:absolute;left:-9999px;width:1px;height:1px'>")
failures = []
ROOT_DISPLAY = "getComputedStyle(document.querySelector('.kb-root')).display"
GEOMETRY = ("(() => { const r = document.querySelector('.kb-root').getBoundingClientRect(); const v = visualViewport;"
            " return [Math.round(r.bottom - (v.offsetTop + v.height)), Math.round(r.width - v.width)]; })()")


def check(name, got, want=None):
    ok = bool(got) if want is None else got == want
    print(("ok   " if ok else "FAIL ") + name + ("" if ok or want is None else f"\n     got  {got}\n     want {want}"))
    if not ok:
        failures.append(name)


def sent(page, keep_heartbeat=False):
    out = page.evaluate("window.__sent.splice(0)")
    return out if keep_heartbeat else [m for m in out if not m.startswith("kh,")]


def fire(page, key, kind):
    """A touch pointer event on the button; returns whether the default was prevented."""
    return page.evaluate("""([k, t]) => !document.querySelector(`[data-key="${k}"]`).dispatchEvent(
        new PointerEvent(t, {bubbles: true, cancelable: true, pointerId: 7, pointerType: 'touch', isPrimary: true}))""",
                         [key, kind])


def tap(page, key):
    fire(page, key, "pointerdown")
    fire(page, key, "pointerup")


def state(page, key):
    return page.get_attribute(f"[data-key={key}]", "data-state")


def open_keyboard(page, height=500):
    page.set_viewport_size({"width": 390, "height": height})
    page.evaluate("document.getElementById('keyboard-input-assist').focus()")
    page.wait_for_function("document.querySelector('.kb-root').style.display !== 'none'")


def stubbed(p):
    browser = p.chromium.launch()
    page = browser.new_context(**{**p.devices["Pixel 7"], "viewport": {"width": 390, "height": 800}}).new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.set_content(PAGE)
    page.add_script_tag(path=os.path.join(HERE, "key-bar-stub.js"))
    page.evaluate("newInput()")
    page.add_style_tag(path=os.path.join(SEL, "key-bar.css"))
    page.add_script_tag(path=os.path.join(SEL, "key-bar.js"))

    check("pointer:coarse under the device profile", page.evaluate("matchMedia('(pointer:coarse)').matches"))
    check("hidden before the keyboard", page.evaluate(ROOT_DISPLAY), "none")
    check("no script errors", errors, [])

    # shown only with the keyboard open, pinned to its top edge
    page.set_viewport_size({"width": 390, "height": 500})
    page.wait_for_timeout(100)
    check("viewport shrink without a focused field keeps it hidden", page.evaluate(ROOT_DISPLAY), "none")
    open_keyboard(page, 500)
    check("bar bottom is the viewport bottom", page.evaluate(GEOMETRY), [0, 0])
    page.set_viewport_size({"width": 390, "height": 430})
    page.wait_for_timeout(100)
    check("follows a viewport resize", page.evaluate(GEOMETRY), [0, 0])
    page.evaluate("Object.defineProperty(visualViewport, 'offsetTop', {get: () => 60, configurable: true});"
                  "visualViewport.dispatchEvent(new Event('scroll'))")
    page.wait_for_timeout(50)
    check("follows a viewport scroll", page.evaluate(GEOMETRY), [0, 0])
    page.evaluate("delete visualViewport.offsetTop; visualViewport.dispatchEvent(new Event('scroll'))")
    z = page.evaluate("[+getComputedStyle(document.querySelector('.kb-root')).zIndex, "
                      "+getComputedStyle(document.querySelector('.toggle-handle')).zIndex]")
    check("above the sidebar handle", z[0] > z[1])
    open_keyboard(page, 500)
    check("does not cover the handle at this size", page.evaluate("""(() => {
        const a = document.querySelector('.kb-root').getBoundingClientRect();
        const b = document.querySelector('.toggle-handle').getBoundingClientRect();
        return a.top >= b.bottom || a.bottom <= b.top; })()"""))
    sent(page)

    # tap; the press must not take the focus
    check("pointerdown is prevented", fire(page, "Esc", "pointerdown"))
    fire(page, "Esc", "pointerup")
    check("tap Esc", sent(page), [f"kd,{ESC}", f"ku,{ESC}"])
    check("focus stays", page.evaluate("document.activeElement.id"), "keyboard-input-assist")

    # hold: down at once, kept alive by the heartbeat, up on release
    fire(page, "Left", "pointerdown")
    page.wait_for_timeout(350)
    got = sent(page, True)
    check("hold: kd first", got[:1], [f"kd,{LEFT}"])
    check("hold: then heartbeats only, at least two", got[1:].count(f"kh,{LEFT}") >= 2 and len(set(got[1:])) == 1)
    fire(page, "Left", "pointerup")
    check("hold: up on release", sent(page), [f"ku,{LEFT}"])
    fire(page, "Left", "pointerdown")
    sent(page)
    fire(page, "Left", "pointercancel")
    check("pointercancel releases", sent(page), [f"ku,{LEFT}"])

    # armed Ctrl: the next key from the Android keyboard, then released
    tap(page, "Ctrl")
    check("arm", sent(page), [f"kd,{CTRL}"])
    check("armed state shown", state(page, "Ctrl"), "armed")
    check("Ctrl counts as a chord modifier while armed", page.evaluate("webrtcInput._chordModifierHeld()"))
    page.evaluate(f"webrtcInput.realKey({C})")
    check("armed Ctrl + keyboard key", sent(page), [f"kd,{C}", f"ku,{C}", f"ku,{CTRL}"])
    check("armed state cleared", state(page, "Ctrl"), "off")
    # a real key event reports no Ctrl: the client's resync must not drop ours
    tap(page, "Ctrl")
    sent(page)
    page.evaluate(f"webrtcInput.realKey({BS})")
    check("resync keeps an armed Ctrl until its key", sent(page), [f"kd,{BS}", f"ku,{BS}", f"ku,{CTRL}"])
    tap(page, "Ctrl")
    sent(page)
    tap(page, "Left")
    check("armed Ctrl + bar key", sent(page), [f"kd,{LEFT}", f"ku,{LEFT}", f"ku,{CTRL}"])

    # lock, and the third tap releases
    tap(page, "Alt")
    tap(page, "Alt")
    check("lock", state(page, "Alt"), "locked")
    sent(page)
    tap(page, "Tab")
    tap(page, "Tab")
    check("locked Alt stays", sent(page), [f"kd,{TAB}", f"ku,{TAB}", f"kd,{TAB}", f"ku,{TAB}"])
    tap(page, "Alt")
    check("third tap releases", sent(page), [f"ku,{ALT}"])
    check("state off", state(page, "Alt"), "off")

    # window blur, hidden tab, keyboard closing
    tap(page, "Alt")
    tap(page, "Alt")
    fire(page, "Left", "pointerdown")
    sent(page)
    page.evaluate("dispatchEvent(new Event('blur'))")
    check("window blur releases everything", sorted(sent(page)), sorted([f"ku,{ALT}", f"ku,{LEFT}"]))
    check("state off after blur", state(page, "Alt"), "off")
    fire(page, "Left", "pointerup")
    check("late release sends nothing", sent(page), [])
    tap(page, "Ctrl")
    tap(page, "Ctrl")
    sent(page)
    page.evaluate("Object.defineProperty(document, 'visibilityState', {get: () => 'hidden', configurable: true});"
                  "document.dispatchEvent(new Event('visibilitychange'))")
    check("hidden tab releases once", sent(page), [f"ku,{CTRL}"])
    page.evaluate("delete document.visibilityState")
    tap(page, "Ctrl")
    tap(page, "Ctrl")
    sent(page)
    page.evaluate("document.activeElement.blur()")
    page.set_viewport_size({"width": 390, "height": 800})
    page.wait_for_function("document.querySelector('.kb-root').style.display === 'none'")
    check("keyboard closing releases", sent(page), [f"ku,{CTRL}"])

    # disconnect: held state is dropped, and the next instance is driven
    open_keyboard(page, 500)
    tap(page, "Super")
    tap(page, "Super")
    page.evaluate("window.webrtcInput = null")
    page.wait_for_function("document.querySelector('[data-key=Super]').getAttribute('data-state') === 'off'")
    page.evaluate("newInput()")
    page.wait_for_timeout(700)
    sent(page)
    tap(page, "Esc")
    check("new instance driven", sent(page), [f"kd,{ESC}", f"ku,{ESC}"])

    # the panel
    tap(page, "more")
    check("more closes the keyboard", page.evaluate("document.activeElement === document.body"))
    page.set_viewport_size({"width": 390, "height": 800})
    page.wait_for_timeout(100)
    check("panel shown without the keyboard", page.evaluate("getComputedStyle(document.querySelector('.kb-panel')).display"), "block")
    check("panel scrolls", page.evaluate("getComputedStyle(document.querySelector('.kb-panel')).overflowY"), "auto")
    page.set_viewport_size({"width": 390, "height": 300})
    page.wait_for_timeout(100)
    check("panel fits a small viewport", page.evaluate("document.querySelector('.kb-root').getBoundingClientRect().top >= 0"))
    check("panel scrollable there", page.evaluate("(p => p.scrollHeight > p.clientHeight)(document.querySelector('.kb-panel'))"))
    sent(page)
    tap(page, "F5")
    check("F5", sent(page), ["kd,65474", "ku,65474"])
    tap(page, "Copy")
    check("Copy", sent(page), [f"kd,{CTRL}", f"kd,{C}", f"ku,{C}", f"ku,{CTRL}"])
    tap(page, "Paste")
    check("Paste", sent(page), [f"kd,{CTRL}", "kd,118", "ku,118", f"ku,{CTRL}"])
    tap(page, "Alt+Tab")
    check("Alt+Tab", sent(page), [f"kd,{ALT}", f"kd,{TAB}", f"ku,{TAB}", f"ku,{ALT}"])
    tap(page, "Ctrl+Alt+T")
    check("Ctrl+Alt+T", sent(page), [f"kd,{CTRL}", f"kd,{ALT}", "kd,116", "ku,116", f"ku,{ALT}", f"ku,{CTRL}"])
    for k, ks in [("Home", 65360), ("End", 65367), ("PgUp", 65365), ("PgDn", 65366), ("Ins", 65379),
                  ("Del", 65535), ("PrtSc", 65377), ("F1", 65470), ("F12", 65481)]:
        tap(page, k)
        check(k, sent(page), [f"kd,{ks}", f"ku,{ks}"])
    page.click("[data-key=keyboard]")
    check("keyboard button refocuses", page.evaluate("document.activeElement.id"), "keyboard-input-assist")
    page.set_viewport_size({"width": 390, "height": 500})
    page.wait_for_function("getComputedStyle(document.querySelector('.kb-panel')).display === 'none'")
    check("the keyboard replaces the panel", page.evaluate(ROOT_DISPLAY), "block")
    check("no script errors at the end", errors, [])
    check("no innerHTML", "innerHTML" not in open(os.path.join(SEL, "key-bar.js")).read())
    browser.close()


def built(p, web):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a):
            pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=web))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    browser = p.chromium.launch()
    page = browser.new_context(**p.devices["Pixel 7"]).new_page()
    missing = []
    page.on("response", lambda r: missing.append(r.url) if r.status == 404 and "key-bar" in r.url else None)
    page.goto(f"http://127.0.0.1:{srv.server_address[1]}/index.html")
    html = open(os.path.join(web, "index.html")).read()
    check("index.html names key-bar-<hash>.js", "assets/key-bar-" in html and "key-bar.js" not in html)
    page.wait_for_selector(".kb-root", state="attached", timeout=20000)
    check("the real client builds the bar", True)
    check("key-bar script found", missing, [])
    check("styles in the client stylesheet", page.evaluate(
        "[...document.styleSheets].some(s => { try { return [...s.cssRules].some(r => (r.selectorText||'').includes('kb-root')); }"
        " catch (e) { return false; } })"))
    browser.close()
    srv.shutdown()


if __name__ == "__main__":
    with sync_playwright() as p:
        if "--built" in sys.argv:
            built(p, sys.argv[sys.argv.index("--built") + 1])
        else:
            stubbed(p)
    print("FAILED: " + ", ".join(failures) if failures else "all passed")
    sys.exit(1 if failures else 0)
