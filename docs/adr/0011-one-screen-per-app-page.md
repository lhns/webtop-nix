# 0011 — One screen per app page

- Status: Accepted
- Date: 2026-11-05

## Context

A Selkies second-display page streams a KWin screen of the running session, which gives an app correct
input, dialogs and resizing. Selkies 2.1.0 drives one secondary display at a time, and its web client
knows only `#display2`. Each app needs its own stream at once, while the main page keeps owning the
primary display.

## Decision

- A page of `#display<n>` (n >= 2) has its own screen `SELKIES-<n>`, capture and input. A small server
  patch lays several out on Wayland, a checked `sed` generalizes the web client, both in this repo;
  the primary's code paths and X11 are unchanged.
- Screens sit in a row right of the primary from x=4096 and keep their place. Moving an output recreates
  it, so a resize of the primary or the close of a neighbour must not move the others.
- The caller picks `<n>` and tells `webtop-app-screen focus` which tab was activated: there is one
  keyboard seat, and Selkies does not know about apps. Any cap on screens is the caller's too.

## Consequences

- Each visible screen costs a capture and an encoder (README, "Cost of app screens").
- Two more edits to carry against the Selkies wheel; a new wheel fails the build until they are redone.
- A second page of the same `<n>` takes that screen over.
