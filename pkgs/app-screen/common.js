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

// A screen that is not an app screen (Selkies names them SELKIES-<n>), or null.
function mainScreen() {
    return workspace.screens.find(s => s.name !== SCREEN && !/^SELKIES-/.test(s.name)) || null;
}

