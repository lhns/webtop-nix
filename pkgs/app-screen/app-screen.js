// KWin script: keeps every window of one app on one screen; normal top-level windows fullscreen.
// webtop-app-screen prepends `const APP_ID = "..."; const SCREEN = "...";` and common.js.
// Stays loaded until unloaded, so windows opened later are moved too. When the screen goes
// (page closed) the windows the script changed go back to the main screen and their prior state;
// when it comes back (page reload) they are placed again. `release` is release.js.

// Windows this script made fullscreen/maximized -> state before, so a window the user had
// fullscreened stays fullscreen.
const changed = new Map();

function target() {
    return workspace.screens.find(s => s.name === SCREEN) || null;
}

function place(w) {
    const screen = target();
    if (!screen || w.popupWindow || w.specialWindow || !belongs(w)) {
        return;
    }
    if (w.output !== screen) {
        workspace.sendClientToScreen(w, screen);
    }
    if (w.normalWindow && !w.transient) {
        if (!changed.has(w)) {
            changed.set(w, { fullScreen: w.fullScreen, maximized: !w.fullScreenable });
        }
        if (w.fullScreenable) {
            w.fullScreen = true;
        } else {
            w.setMaximize(true, true);
        }
        workspace.activeWindow = w;
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
        if (!w.normalWindow) {
            return;
        }
        if (prior.maximized) {
            w.setMaximize(false, false);
        }
        if (main && w.output !== main && (!w.output || w.output.name === SCREEN)) {
            workspace.sendClientToScreen(w, main);
        }
        // Set after the move: KWin may have dropped fullscreen on its own.
        w.fullScreen = prior.fullScreen;
    });
}

workspace.windowAdded.connect(w => {
    place(w);
    w.closed.connect(() => changed.delete(w));
    // Some clients set the app id after mapping.
    w.desktopFileNameChanged.connect(() => place(w));
    w.windowClassChanged.connect(() => place(w));
});
workspace.screensChanged.connect(placeAll);
placeAll();
