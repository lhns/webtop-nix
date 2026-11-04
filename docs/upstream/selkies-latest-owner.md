# Selkies: the page opened last owns the primary display

Draft for upstream; not posted. Patch: `pkgs/selkies/latest-owner.patch` (against 2.1.0).

The first page owns the primary display and only the owner's window sets the desktop size; a later
page of another tab joins beside it. A small window left open elsewhere therefore pins the desktop
small until it is found and closed.

A socket's first SETTINGS for the primary, from a page of another tab holding full permissions, now
takes the display. The owner is not killed: it moves into `co_controllers`, keeping its audio and
pause state, and is told the size with the reset and keyframe a joining page gets. A later SETTINGS
from a page beside the owner never takes the display. When the owner leaves, promotion works as
before; a former owner's next SETTINGS counts as a first one so that its window sizes the desktop.

A dropped `r,` from a page beside the owner now answers with the display's `stream_resolution`: the
web client has by then fitted its canvas to its window, and nothing else would put it back. This also
fixes pages that joined beside the owner.

Reconnects in place would otherwise take the display from a background page after a network blip, and
the server cannot tell them from a reload: both name the same tab, and the old socket may still look
open. The web client now sends `reconnecting: true` in the first SETTINGS of every socket but its page's
first, and such a page joins beside the owner. Here that is one expression substituted into the built
bundle (`pkgs/selkies.nix`); upstream it belongs in the client source.

Upstream may prefer this behind an option: a page opened on a phone now resizes the desktop of
whoever is working at it.
