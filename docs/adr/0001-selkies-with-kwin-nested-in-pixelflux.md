# 0001 — Selkies, with KWin nested in pixelflux's compositor

- Status: Accepted
- Date: 2026-10-28

## Context

The goal is a full KDE Plasma desktop in a browser tab, Wayland-native, with audio, clipboard and
file transfer, working in every current browser including Firefox on Android. Candidates were
Selkies (pixelflux capture and encode, pcmflux audio, WebSocket transport), KasmVNC (an X server,
so X11 only) and KDE's own RDP server (KRdp) behind an HTML5 RDP client such as Guacamole.

## Decision

- **Selkies** is the remote-desktop stack. pixelflux runs a headless Wayland compositor in
  process; **KWin runs nested inside it** as a Wayland client (`WAYLAND_DISPLAY` points at
  pixelflux's socket), the shape LinuxServer's webtop images use. X11 applications run through
  Xwayland.
- Selkies' own authentication is off. Authentication belongs to whatever fronts the port.

## Consequences

- Wayland-native Plasma with audio, clipboard and uploads; no X11-only server in the path.
- Without a GPU, encoding is on the CPU; the browser needs WebCodecs.
- The nesting is the part most likely to break on Plasma or Selkies upgrades; KWin's own socket is
  separate from pixelflux's, and tools that talk to the compositor must pick the right one.
- Selkies upstream is short of maintainers; LinuxServer maintaining pixelflux and pcmflux softens
  that.
