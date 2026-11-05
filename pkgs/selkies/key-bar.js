/* Special-key bar for touch screens, above the on-screen keyboard. Added to the Selkies web client by
   pkgs/selkies.nix; it drives window.webrtcInput from outside and patches nothing in the client.
   Held keys go through _sendKeyEvent, which is what puts them in _keyDownList: the client's `kh`
   heartbeat covers only that list, and the server releases a key whose heartbeat stops (2 s). */
(function () {
  'use strict';
  if (!window.matchMedia || !window.matchMedia('(pointer:coarse)').matches) return;

  var PREFIX = 'keybar:'; // codes in _keyDownList, apart from every real event.code
  var MIN_KEYBOARD = 100; // px the visual viewport must lose before it counts as a keyboard
  var MOD_KEYSYM = { Ctrl: 0xffe3, Alt: 0xffe9, Super: 0xffeb };
  var BAR = [
    ['Esc', 'Esc', 0xff1b], ['Tab', 'Tab', 0xff09],
    ['Ctrl', 'Ctrl'], ['Alt', 'Alt'], ['Super', 'Super'],
    ['Left', '\u2190', 0xff51, 'Left'], ['Down', '\u2193', 0xff54, 'Down'],
    ['Up', '\u2191', 0xff52, 'Up'], ['Right', '\u2192', 0xff53, 'Right'],
    ['more', '\u22EF', 0, 'More keys']
  ];
  var PANEL_KEYS = [
    ['Home', 'Home', 0xff50], ['End', 'End', 0xff57], ['PgUp', 'PgUp', 0xff55], ['PgDn', 'PgDn', 0xff56],
    ['Ins', 'Ins', 0xff63], ['Del', 'Del', 0xffff], ['PrtSc', 'PrtSc', 0xff61]
  ];
  for (var n = 1; n <= 12; n++) PANEL_KEYS.splice(n - 1, 0, ['F' + n, 'F' + n, 0xffbd + n]);
  var SHORTCUTS = [
    ['Copy', 'Copy', [0xffe3, 0x63]], ['Paste', 'Paste', [0xffe3, 0x76]],
    ['Alt+Tab', 'Alt+Tab', [0xffe9, 0xff09]], ['Ctrl+Alt+T', 'Ctrl+Alt+T', [0xffe3, 0xffe9, 0x74]]
  ];

  var wi = null;        // the webrtcInput instance we wrapped
  var held = {};        // our code -> keysym, down on the desktop
  var mods = { Ctrl: 0, Alt: 0, Super: 0 }; // 0 off, 1 armed (next key), 2 locked
  var pendingKd = false; // a non-modifier went down since the last one came up
  var mode = 'hidden';  // hidden | bar | panel
  var baseW = 0, baseH = 0, lastKeyboard = 280;
  var root, bar, panel, buttons = {};

  function isModifier(ks) { return ks >= 0xffe1 && ks <= 0xffee; }

  // ---- keys -------------------------------------------------------------------------------------

  function canSend() { return wi && typeof wi._sendKeyEvent === 'function'; }

  function press(code, ks) {
    if (!canSend() || held[code]) return;
    held[code] = ks;
    wi._sendKeyEvent(ks, PREFIX + code, true);
  }

  function release(code) {
    if (!held[code]) return;
    var ks = held[code];
    delete held[code];
    if (canSend()) wi._sendKeyEvent(ks, PREFIX + code, false);
  }

  function setMod(name, state) {
    if (state && !mods[name]) press(name, MOD_KEYSYM[name]);
    else if (!state && mods[name]) release(name);
    mods[name] = state;
    render();
  }

  function releaseArmed() {
    for (var name in mods) if (mods[name] === 1) setMod(name, 0);
    if (wi && '_chordKeySent' in wi) wi._chordKeySent = false;
  }

  function releaseAll() {
    for (var code in held) release(code);
    for (var name in mods) mods[name] = 0;
    pendingKd = false;
    render();
  }

  // The client already sent its key-ups (resetKeyboard); only our own state is left.
  function forget() {
    held = {};
    for (var name in mods) mods[name] = 0;
    pendingKd = false;
    render();
  }

  function combo(keysyms) {
    var codes = keysyms.map(function (ks, i) { return 'combo' + i; });
    keysyms.forEach(function (ks, i) { press(codes[i], ks); });
    for (var i = codes.length - 1; i >= 0; i--) release(codes[i]);
  }

  // ---- the client's instance ---------------------------------------------------------------------

  function observe(msg) {
    if (typeof msg !== 'string') return;
    if (msg.indexOf('kd,') === 0) {
      if (!isModifier(+msg.slice(3))) pendingKd = true;
    } else if (msg.indexOf('ku,') === 0) {
      if (pendingKd && !isModifier(+msg.slice(3))) { pendingKd = false; releaseArmed(); }
    } else if (msg.indexOf('co,end') === 0) {
      releaseArmed();
    }
  }

  function wrap(w) {
    if (w.__keyBar) return;
    w.__keyBar = true;
    var send = w.send, lost = w._releaseLostKey, reset = w.resetKeyboard;
    // Sees the Android keyboard's keys too, which is how an armed modifier knows its key came.
    w.send = function (msg) {
      var r = send.apply(this, arguments);
      if (this === wi) observe(msg);
      return r;
    };
    // _releaseDesyncedModifiers drops a modifier the real event does not report; ours is virtual.
    if (lost) w._releaseLostKey = function (code) {
      if (typeof code === 'string' && code.indexOf(PREFIX) === 0) return;
      return lost.apply(this, arguments);
    };
    if (reset) w.resetKeyboard = function () {
      var r = reset.apply(this, arguments);
      if (this === wi) forget();
      return r;
    };
  }

  function attach() {
    var w = window.webrtcInput || null;
    if (w === wi) return;
    if (wi) forget(); // disconnected: the old instance cannot be told anything
    wi = w;
    if (wi) wrap(wi);
  }

  // ---- layout ------------------------------------------------------------------------------------

  function editable(el) {
    return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
  }

  function update() {
    var vv = window.visualViewport;
    if (!vv || !root) return;
    var bottom = vv.offsetTop + vv.height;
    if (Math.abs(vv.width - baseW) > 1) { baseW = vv.width; baseH = 0; } // rotated
    baseH = Math.max(baseH, window.innerHeight, bottom);
    var keyboard = baseH - bottom;
    var open = keyboard > MIN_KEYBOARD && editable(document.activeElement);
    var next = open ? 'bar' : (mode === 'panel' ? 'panel' : 'hidden');
    if (open) lastKeyboard = keyboard;
    if (next === 'hidden' && mode !== 'hidden') releaseAll();
    mode = next;
    root.style.display = mode === 'hidden' ? 'none' : '';
    panel.style.display = mode === 'panel' ? '' : 'none';
    panel.style.height = Math.min(Math.max(lastKeyboard, 200), Math.round(vv.height * 0.6)) + 'px';
    root.style.width = vv.width + 'px';
    root.style.transform = 'translate(' + vv.offsetLeft + 'px,' + bottom + 'px) translateY(-100%)';
  }

  function render() {
    for (var name in mods) {
      var b = buttons[name];
      if (b) b.setAttribute('data-state', mods[name] === 2 ? 'locked' : mods[name] === 1 ? 'armed' : 'off');
    }
  }

  // ---- DOM ---------------------------------------------------------------------------------------

  function stop(e) { if (e.cancelable) e.preventDefault(); }

  // Pressing must not move the focus: the keyboard would close.
  function button(parent, id, label, aria, gestures) {
    var b = document.createElement('button');
    b.type = 'button';
    b.tabIndex = -1;
    b.className = 'kb-btn';
    b.setAttribute('data-key', id);
    b.setAttribute('aria-label', aria || label);
    b.textContent = label;
    var active = null;
    b.addEventListener('pointerdown', function (e) {
      stop(e);
      if (active !== null || (e.pointerType === 'mouse' && e.button !== 0)) return;
      active = e.pointerId;
      b.classList.add('kb-down');
      try { b.setPointerCapture(e.pointerId); } catch (x) { /* synthetic pointer */ }
      attach();
      if (gestures.down) gestures.down();
    });
    function end(e, ok) {
      if (e.pointerId !== active) return;
      stop(e);
      active = null;
      b.classList.remove('kb-down');
      if (ok) { if (gestures.up) gestures.up(); } else if (gestures.cancel) gestures.cancel();
    }
    b.addEventListener('pointerup', function (e) { end(e, true); });
    b.addEventListener('pointercancel', function (e) { end(e, false); });
    b.addEventListener('mousedown', stop);
    if (!gestures.click) b.addEventListener('touchstart', stop, { passive: false }); // would swallow the click
    b.addEventListener('contextmenu', stop);
    if (gestures.click) b.addEventListener('click', gestures.click);
    parent.appendChild(b);
    buttons[id] = b;
    return b;
  }

  // Held keys repeat; in the scrolling panel a key is a tap on release, so a scroll presses nothing.
  function keyButton(parent, spec, tap) {
    var id = spec[0], ks = spec[2];
    button(parent, id, spec[1], spec[3], tap ? {
      up: function () { attach(); press(id, ks); release(id); }
    } : {
      down: function () { press(id, ks); },
      up: function () { release(id); },
      cancel: function () { release(id); }
    });
  }

  function modButton(parent, spec) {
    var name = spec[0];
    button(parent, name, spec[1], spec[3], {
      up: function () { setMod(name, (mods[name] + 1) % 3); }
    });
  }

  function toggleMore() {
    if (mode === 'panel') { mode = 'hidden'; releaseAll(); update(); return; }
    mode = 'panel';
    var a = document.activeElement;
    if (editable(a)) a.blur(); // closes the keyboard
    update();
  }

  function showKeyboard() {
    var a = document.getElementById('keyboard-input-assist');
    if (a) { a.value = ''; a.focus(); }
    else if (wi && typeof wi._focusCompositionHost === 'function') wi._focusCompositionHost();
    update();
  }

  function build() {
    root = document.createElement('div');
    root.className = 'kb-root';
    root.style.display = 'none';
    bar = document.createElement('div');
    bar.className = 'kb-bar';
    bar.setAttribute('role', 'toolbar');
    bar.setAttribute('aria-label', 'Special keys');
    BAR.forEach(function (s) {
      if (s[0] === 'more') button(bar, 'more', s[1], s[3], { up: toggleMore });
      else if (MOD_KEYSYM[s[0]]) modButton(bar, s);
      else keyButton(bar, s);
    });
    panel = document.createElement('div');
    panel.className = 'kb-panel';
    panel.style.display = 'none';
    button(panel, 'keyboard', '\u2328 Keyboard', 'Show the keyboard', { click: showKeyboard });
    var grid = document.createElement('div');
    grid.className = 'kb-grid';
    SHORTCUTS.forEach(function (s) {
      button(grid, s[0], s[1], null, { up: function () { attach(); combo(s[2]); } });
    });
    PANEL_KEYS.forEach(function (s) { keyButton(grid, s, true); });
    panel.appendChild(grid);
    root.appendChild(bar);
    root.appendChild(panel);
    document.body.appendChild(root);
  }

  function start() {
    build();
    render();
    attach();
    setInterval(attach, 500);
    var vv = window.visualViewport;
    if (vv) { vv.addEventListener('resize', update); vv.addEventListener('scroll', update); }
    window.addEventListener('resize', update);
    document.addEventListener('focusin', update);
    document.addEventListener('focusout', function () { setTimeout(update, 0); });
    window.addEventListener('blur', releaseAll);
    window.addEventListener('pagehide', releaseAll);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') releaseAll();
    });
    update();
  }

  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
})();
