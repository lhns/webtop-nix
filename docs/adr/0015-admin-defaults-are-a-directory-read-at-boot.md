# 0015 — Admin defaults are a directory read at boot, one layer per kind of setting

- Status: Accepted; amends ADR 0008 (extension points)
- Date: 2026-11-10

## Context

An admin needs defaults for every desktop (time zone, language, formats, KDE settings, home-manager
settings) that each user can override. The consumer passed time zone and locale as two environment
variables, which cannot carry files and need a new pod per change. Home-manager runs after the
session starts, so it cannot carry anything Plasma reads at its start, and its KDE files are read-only
links that a settings page cannot write.

## Decision

- **One defaults directory**, `services.webtop.defaults.source` (default `/etc/webtop/defaults`; a bind
  mount, a ConfigMap or `environment.etc`), with three parts, each through the layer where the user
  already overrides that kind of setting:
  - `session.conf` (time zone, locale, language, formats), resolved per key by `webtop-locale` as
    root: module default < admin < the user's `webtop.*` (their `session.conf`) < System Settings.
    `webtop-locale` writes the result to `/etc/locale.conf` and to
    `/run/webtop/xdg-session/plasma-localerc`, a layer of Plasma's config cascade below the user's own
    file, so System Settings sees it as the default and saves only what the user changed.
  - `xdg/<file>`: KDE/XDG config, joined to `XDG_CONFIG_DIRS` by the session wrapper. KConfig merges per key.
  - `home.nix`: a home-manager module (imported by the user's flake in a later change).
- **A snapshot** (`webtop-defaults.service`) copies the directory once per boot to the root-owned
  `/run/webtop/defaults`, so a live ConfigMap update cannot change what a running desktop evaluates.
  A missing source gives an empty snapshot, and a `home.nix` that does not parse is replaced by `{ }`.
- **Defaults only.** Nothing is enforced: users can opt out, and have sudo and their own environment.
- `localeEnvironmentFiles` (`WEBTOP_TIME_ZONE`, `WEBTOP_LOCALE`) is removed; a consumer extends through
  this directory.

## Consequences

- An admin change applies at the next boot or session start, not live. A user's own System Settings
  choice holds against later admin changes; removing it restores the admin's.
- A time zone chosen in System Settings goes through timedated and is reset at the next session start.
- Rejected: home-manager `xdg.configFile` (read-only links), an overlay over `~/.config` (copy-up
  freezes most files), copy at first login (never updated), `[$i]` immutable keys (enforcement).
- The first login writes `~/.config/kdedefaults` and a colour scheme into the user's `kdeglobals`, which
  mask admin look-and-feel keys; panel and widget layout is generated at first login and cannot be
  defaulted this way.
