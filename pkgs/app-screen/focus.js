// KWin script, one shot: gives the keyboard to the top window of a screen (one seat, several tabs).
// webtop-app-screen prepends `const APP_ID = ""; const SCREEN = "...";` and common.js.
const screen = SCREEN === "main" ? mainScreen() : workspace.screens.find(s => s.name === SCREEN);
const top = workspace.stackingOrder
    .filter(w => w.output === screen && !w.minimized && (w.normalWindow || w.dialog || w.desktopWindow))
    .pop();
if (top && workspace.activeWindow !== top) {
    workspace.activeWindow = top;
}
