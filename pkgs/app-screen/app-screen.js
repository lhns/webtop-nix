// KWin script: keeps every window of one app on one screen; normal top-level windows fullscreen.
// webtop-app-screen prepends `const APP_ID = "..."; const SCREEN = "...";`.
// Stays loaded until unloaded, so windows opened later are moved too, and a screen that goes and
// comes back (page reload) gets them back.

const WANT = APP_ID.replace(/\.desktop$/, "");

function matches(w) {
    return [w.desktopFileName, w.resourceClass, w.resourceName]
        .some(id => id && id.replace(/\.desktop$/, "") === WANT);
}

// Dialogs of the app (a portal file chooser is another process) follow their parent.
function belongs(w) {
    for (let v = w, depth = 0; v && depth < 16; v = v.transientFor, depth++) {
        if (matches(v)) {
            return true;
        }
    }
    return false;
}

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
        if (w.fullScreenable) {
            w.fullScreen = true;
        } else {
            w.setMaximize(true, true);
        }
        workspace.activeWindow = w;
    }
}

function placeAll() {
    workspace.windowList().forEach(place);
}

workspace.windowAdded.connect(w => {
    place(w);
    // Some clients set the app id after mapping.
    w.desktopFileNameChanged.connect(() => place(w));
    w.windowClassChanged.connect(() => place(w));
});
workspace.screensChanged.connect(placeAll);
placeAll();
