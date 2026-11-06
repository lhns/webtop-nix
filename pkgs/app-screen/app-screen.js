// KWin script: keeps every window of one app on one screen; normal top-level windows fullscreen.
// webtop-app-screen prepends `const APP_ID = "..."; const SCREEN = "...";` and common.js.
// Stays loaded until unloaded, so windows opened later are moved too. When the screen goes
// (page closed) the windows the script changed go back to the main screen and their prior state;
// when it comes back (page reload) they are placed again. `release` is release.js.

// Windows this script made fullscreen/maximized -> state before, so a window the user had
// fullscreened stays fullscreen.
const changed = new Map();
const returning = new Set();

function target() {
    return workspace.screens.find(s => s.name === SCREEN) || null;
}

function place(w) {
    const screen = target();
    if (!screen || w.popupWindow || w.specialWindow || !belongs(w)) {
        return;
    }
    const moved = w.output !== screen;
    if (moved) {
        workspace.sendClientToScreen(w, screen);
    }
    if (w.normalWindow && !w.transient) {
        const first = !changed.has(w);
        if (first) {
            changed.set(w, { fullScreen: w.fullScreen, maximized: !w.fullScreenable });
        }
        if (w.fullScreenable) {
            w.fullScreen = true;
        } else {
            w.setMaximize(true, true);
        }
        // Not on every screen change: another app's screen coming or going must not take the keyboard.
        if (moved || first) {
            workspace.activeWindow = w;
        }
    }
}

function placeAll() {
    if (target()) {
        workspace.windowList().forEach(place);
    } else {
        restoreAll();
    }
}

// The app screen is gone: KWin has moved or is moving the windows; make sure they end on the main
// screen with their old state. A window not on the main screen yet is moved explicitly.
function restoreAll() {
    const main = mainScreen();
    changed.forEach((prior, w) => {
        changed.delete(w);
        returning.add(w);
        if (!w.normalWindow) {
            return;
        }
        if (prior.maximized) {
            w.setMaximize(false, false);
        }
        // KWin may have moved it to another app's screen.
        if (main && w.output !== main && (!w.output || /^SELKIES-/.test(w.output.name))) {
            workspace.sendClientToScreen(w, main);
        }
        // Set after the move: KWin may have dropped fullscreen on its own.
        w.fullScreen = prior.fullScreen;
    });
}

// KWin can reset a window's output or fullscreen state after place() ran (e.g. a screen is re-added
// while others are still laid out), and no screensChanged follows. Place again, but only on a
// mismatch and never from inside place() itself, so our own changes cannot loop. Only output and
// fullscreen changes count: a fullscreen request is not acked yet while the frame still changes.
let placing = false;
function settle(w, fullScreenLost) {
    const screen = target();
    const main = mainScreen();
    if (returning.has(w) && !screen && main && w.output && w.output !== main && /^SELKIES-/.test(w.output.name)) {
        workspace.sendClientToScreen(w, main);
    }
    if (placing || !screen || !belongs(w)) {
        return;
    }
    if (w.output !== screen || (fullScreenLost && w.fullScreenable && !w.fullScreen)) {
        placing = true;
        try {
            place(w);
        } finally {
            placing = false;
        }
    }
}

workspace.windowAdded.connect(w => {
    place(w);
    w.outputChanged.connect(() => settle(w));
    w.fullScreenChanged.connect(() => settle(w, true));
    w.closed.connect(() => { changed.delete(w); returning.delete(w); });
    // Some clients set the app id after mapping.
    w.desktopFileNameChanged.connect(() => place(w));
    w.windowClassChanged.connect(() => place(w));
});
workspace.screensChanged.connect(placeAll);
placeAll();
