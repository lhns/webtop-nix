// Stand-in for the client's webrtcInput: the methods key-bar.js touches, with the bodies the shipped
// selkies-core has (checked at build time by a grep in pkgs/selkies.nix, not by running the bundle).
window.__sent = [];
(function () {
  var NAME = { 0xffe3: 'Control', 0xffe4: 'Control', 0xffe9: 'Alt', 0xffea: 'Alt', 0xffeb: 'Meta', 0xffec: 'Meta' };
  function isChordMod(ks) { return ks in NAME; }
  class Input {
    constructor(send) {
      this.send = send;
      this._keyDownList = {};
      this._keyHeartbeatTimer = null;
      this._chordKeySent = false;
    }
    _sendKeyEvent(ks, code, down) {
      if (ks === null) return;
      if (down) this._keyDownList[code] = ks;
      else { if (!(code in this._keyDownList)) return; ks = this._keyDownList[code]; delete this._keyDownList[code]; }
      this.send((down ? 'kd,' : 'ku,') + ks);
      if (down) { this._noteChordKey(ks); this._startKeyHeartbeat(); }
      else if (Object.keys(this._keyDownList).length === 0) this._stopKeyHeartbeat();
    }
    _startKeyHeartbeat() {
      if (this._keyHeartbeatTimer === null) this._keyHeartbeatTimer = setInterval(() => {
        var v = Object.values(this._keyDownList);
        if (v.length === 0) { this._stopKeyHeartbeat(); return; }
        this.send('kh,' + v.join(','));
      }, 100);
    }
    _stopKeyHeartbeat() {
      if (this._keyHeartbeatTimer !== null) { clearInterval(this._keyHeartbeatTimer); this._keyHeartbeatTimer = null; }
    }
    _sendMomentaryKey(ks) { this._noteChordKey(ks); this.send('kd,' + ks); this.send('ku,' + ks); }
    _noteChordKey(ks) { if (!isChordMod(ks) && this._chordModifierHeld()) this._chordKeySent = true; }
    _chordModifierHeld() { for (var c in this._keyDownList) if (isChordMod(this._keyDownList[c])) return true; return false; }
    _releaseLostKey(code) { this._sendKeyEvent(this._keyDownList[code], code, false); }
    _releaseDesyncedModifiers(e) {
      for (var code in this._keyDownList) {
        var name = NAME[this._keyDownList[code]];
        if (name && !e.getModifierState(name)) this._releaseLostKey(code);
      }
    }
    resetKeyboard() {
      this._stopKeyHeartbeat();
      for (var c in this._keyDownList) this._sendKeyEvent(this._keyDownList[c], c, false);
      this._keyDownList = {};
    }
    // What the Android keyboard produces: a real key event, which reports no modifier.
    realKey(ks) {
      this._chordKeySent = false;
      this._releaseDesyncedModifiers({ getModifierState: function () { return false; } });
      this._sendMomentaryKey(ks);
    }
  }
  window.StubInput = Input;
  window.newInput = function () { return (window.webrtcInput = new Input(function (m) { window.__sent.push(m); })); };
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden' && window.webrtcInput) window.webrtcInput.resetKeyboard();
  });
})();
