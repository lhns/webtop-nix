# Selkies: second display without a primary page

Patch: [`pkgs/selkies/second-display-without-primary.patch`](../../pkgs/selkies/second-display-without-primary.patch)
(the lines below its `-----` header apply to `selkies-project/selkies` with `git apply`; against
2.1.0, unchanged on main `58b6c35`). Not submitted; draft PR text below.

---

**Wayland: lay out a second display when no primary page is connected**

A `#display2-<pos>` page that connects while no primary page is connected gets no stream: the
layout pass builds layouts only when a primary client is present, so it logs "Calculated total
display size is zero. Aborting reconfiguration." and the page stays black.

On Wayland the primary's screen (output 0) exists whether or not a page shows it, so the secondary
can extend it as it would beside a connected primary. This adds that case: the primary's layout
takes the screen's current size from `list_outputs`, the secondary is placed with
`compute_dual_layout`, and no capture starts for the primary, since it has no client. X11 keeps the
current behaviour.

Use case: streaming one application of a desktop session to its own browser tab (the app is moved
to the second display's screen) without keeping the full-desktop page open.

Tested in a NixOS VM (KWin 6.8 nested in pixelflux 2.2.1): the second display's screen is grown,
streamed and takes pointer and keyboard input with no primary page, and is removed when the page
closes.
