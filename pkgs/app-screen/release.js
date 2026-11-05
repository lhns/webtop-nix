// One-shot KWin script for `webtop-app-screen release`: sends the app's windows on an app screen
// back to the main screen and undoes fullscreen/maximize. The loaded script's memory of prior
// state is gone with it, so this always un-fullscreens (SCREEN is "" here).
workspace.windowList().forEach(w => {
    const main = mainScreen();
    if (!main || !w.output || !/^SELKIES-/.test(w.output.name) || !belongs(w)) {
        return;
    }
    if (w.normalWindow) {
        w.fullScreen = false;
        w.setMaximize(false, false);
    }
    workspace.sendClientToScreen(w, main);
});
