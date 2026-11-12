# webtop-nix

Nix packages and a NixOS module for a browser-streamed Plasma 6 desktop: [Selkies](https://github.com/selkies-project/selkies)
(with its pixelflux Wayland compositor/encoder and pcmflux audio) streams a KWin session to a web page.
Nothing here is site-specific; deployment wiring belongs in the consuming repo.

## Packages

`packages.<system>.{pixelflux,pcmflux,selkies,webtop-app-screen,kwin,kguiaddons,kded}` for `x86_64-linux` and `aarch64-linux`, and `overlays.default` (adds the same
attributes, `kwin` as `kwinSoftwarePresentation` and `kguiaddons` as `kguiaddonsClipboardFix`, `kded` as `kdedStartupSigterm`, and the Python packages in `pythonPackagesExtensions`; the top-level Python
ones come from `python3Packages`, nixpkgs' default interpreter).

| package | version | source |
| --- | --- | --- |
| pixelflux | 2.2.1 | built from source (Rust, `setuptools-rust`), GPL flavor with libx264/x265 |
| pcmflux | 2.2.0 | built from source (Rust, `setuptools-rust`) |
| selkies | 2.1.0 | PyPI wheel (bundles the built web client), with four patches: [second display](pkgs/selkies/second-display-without-primary.patch), [upload path](pkgs/selkies/upload-path.patch), [latest page owns the display](pkgs/selkies/latest-owner.patch), [several second displays](pkgs/selkies/several-second-displays.patch) |
| Nix | 2.34 | built from source for `nixProfile`, with [`nix profile` backends](modules/nix-profile/nix/profile-backends.patch), [cacheable `path:` inputs](modules/nix-profile/nix/path-input-fingerprint.patch) and [no kill of a builder that closes its output early](modules/nix-profile/nix/daemon-eof-wait.patch) (`builder-exit-timeout`) |
| webtop-app-screen | — | this repo: keeps an app's windows on one screen ([below](#one-app-per-screen)) |

Web client edits made in `postInstall` ([selkies.nix](pkgs/selkies.nix)): a larger left padding for the sidebar and a handle at the
same edge on touch screens ([touch-handle.css](pkgs/selkies/touch-handle.css)); a special-key bar above the on-screen keyboard
([key-bar.js](pkgs/selkies/key-bar.js), [key-bar.css](pkgs/selkies/key-bar.css)); touchpad mode accelerates by at most 1.5x instead of 3x
and offers speeds down to 0.1 (stock: 0.25 to 4 and a 3x cap), because the stock pointer was too fast even at 0.5; a saved speed keeps
working. The changed assets are renamed by content hash so browsers do not reuse stale copies.

Status: pixelflux and pcmflux build from source at the commits that released the PyPI wheels; selkies is still the prebuilt wheel, building it from source is planned.

## Usage

```nix
{
  inputs.webtop-nix.url = "github:lhns/webtop-nix";
  outputs = { nixpkgs, webtop-nix, ... }: {
    nixosConfigurations.desktop = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        webtop-nix.nixosModules.webtop   # also adds the overlay
        { services.webtop.enable = true; }
      ];
    };
  };
}
```

Options (`services.webtop.*`): `enable`, `user` (`"user"`), `uid` (`1000`), `port` (`8082`), `address` (`127.0.0.1`; Selkies auth is off, so expose it only behind an authenticating proxy),
`openFirewall`, `softwareCenter.enable` (`false`; the standalone image sets it), `softwareRendering` (`true`: `LIBGL_ALWAYS_SOFTWARE`), `kwinSoftwarePresentation` (`true`: patched KWin, see below), `seat` (`""`: none; a seat needs a VT),
`lockScreen` (`false`: Lock hidden and blocked, see "Lock screen"; autolock is always off), `waylandSocketIndex` (`1`), `clipboard` (`"true"`; also `"in"`, `"out"`, `"false"`),
`fileTransfers` (`[ "upload" "download" ]`; `[ ]` disables), `fileManagerPath` (`~`: downloads are served from the whole home), `uploadPath` (`null`: the user's XDG download directory, see below), `environmentFiles` (`[ ]`), `userSettings` (allowlist, see below), `browserCursors` (`true`), `sudo.enable` (`false`, see "Container module"), `package`, `extraEnvironment` (extra `SELKIES_*` settings).

File transfers: downloads (`/api/files/`) are served from `fileManagerPath`. Uploads go to `uploadPath` (`SELKIES_UPLOAD_PATH`,
a patch in [pkgs/selkies](pkgs/selkies/upload-path.patch)). `null` resolves `xdg-user-dir DOWNLOAD` at each start of `selkies.service`, so
`~/.config/user-dirs.dirs` and localized names count; it falls back to `$HOME/Downloads` when unset. A value (`"~/Inbox"`, an absolute path) is used as is.

Runtime settings, lowest to highest precedence: the module (options and `extraEnvironment`) < `environmentFiles` (systemd `EnvironmentFile=`
entries read in order, later wins, `-` prefix = optional, e.g. `"-/run/webtop/selkies.env"`) < the user's `~/.config/webtop/selkies.env`.
The user file takes `KEY=VALUE` lines whose key is in `userSettings` (stream quality and input feel; no auth, transfers, paths, ports,
clipboard or audit); other lines are skipped with a journal message, and the file must be a regular file under 64 KiB. Effective values:
`xargs -0 -n1 < /proc/$(systemctl --user show -p MainPID --value selkies)/environ | grep ^SELKIES_`; skipped lines:
`journalctl --user -u selkies | grep webtop:`.

What the module sets up:

- Plasma 6, no display manager; the user is lingered so its manager starts at boot.
- `selkies.service` (user unit): pixelflux hosts a Wayland socket `wayland-<waylandSocketIndex>` (default `wayland-1`; stale sockets are removed at start).
- `webtop-session.service`: `startplasma-wayland` as the user (PAM `login`, `seat`), nested in that socket once its lock is held. Log Out ends it and it starts again; any stop of it (restart, crash, Log Out) also stops `graphical-session.target` in the user manager, so KWin and Plasma always start in the new logind session, also after a Log Out in a session's first seconds. The Plasma splash screen is off (`Engine=none` in `/etc/xdg/ksplashrc`, immutable so a user's `ksplashrc` cannot re-enable it): it only animates loading and delays each start. Selkies and `webtop-lock-guard` keep running.
- No `SELKIES_SUBFOLDER`: behind a reverse proxy that strips a path prefix, the web client derives it from the page URL.
- PipeWire with PulseAudio for pcmflux and a null sink `output` (default sink; Selkies streams `output.monitor`), upower, polkit rule for power-off/reboot/suspend,
  Firefox, fonts, and `webtop-app-screen` on the system path.
- `/etc/xdg` defaults, overridable per user: PowerDevil idle action "nothing", session restore
  "restore previous session".

### Left out

Plasma's optional parts a streamed desktop rarely uses, about 2 GiB of closure. Each switch is at
priority 900, so an ordinary definition turns it back on:

| left out | brings back |
| --- | --- |
| KDE PIM (Akonadi with MariaDB, KMail, Kontact, Merkuro) | `programs.kde-pim.enable = true;` |
| Orca, and speech-dispatcher with its voices (mbrola, ~700 MiB) | `services.orca.enable = true;` (it enables `services.speechd` too); speech alone: `services.speechd.enable = true;` |
| fwupd, and Discover, which Plasma installs only with fwupd or Flatpak | `services.fwupd.enable = true;` |
| geoclue | `services.geoclue2.enable = true;` |
| Qt 5 integration (KF5, Breeze for Qt 5): Qt 5 apps run with the default style | `services.desktopManager.plasma6.enableQt5Integration = true;` |
| `/share/doc` of every package (man pages stay) | `documentation.doc.enable = true;` |
| extra wallpapers (the default one is in Breeze), Elisa, KHelpCenter, KRdp | add the package, e.g. `environment.systemPackages = [ pkgs.kdePackages.elisa ];`, or a user installs it |

Apps can also be installed per user (Nix profile, home-manager); system services like Orca or
speech-dispatcher need the system options above.

## Software

`services.webtop.nixProfile.enable` (`false`; the standalone image sets it, [ADR 0006](docs/adr/0006-software-installation-in-this-flake.md))
gives the user one declaration, `~/.config/home-manager/packages.json`: `nix profile add|remove|upgrade|rollback` edit it and run `home-manager switch` (a patched Nix, built from source). Commands can run at the same time, in any mix: each builds unlocked, then applies its own change to the current state under a lock ([ADR 0007](docs/adr/0007-nix-profile-commit-locks.md)). Applying it takes one more lock shared with every `home-manager` run, so a cancelled or killed command is finished by the next one ([ADR 0009](docs/adr/0009-one-apply-lock-and-an-applied-marker.md)).
On first boot a starter flake appears in `~/.config/home-manager`; its `nixpkgs`, `home-manager` and `webtop` inputs resolve from the image's registry. The registry also has `nixpkgs-unfree` (the image's nixpkgs with unfree allowed): `nix profile add nixpkgs-unfree#pkg` installs an unfree package and records it in `packages.json`, with no `--impure`. Your own module goes in `local.nix` beside it, which the image never writes (in a git repo, `git add` it).

Settings for an installed package are home-manager config that reads `webtop.packages.installed` ([ADR 0016](docs/adr/0016-settings-for-installed-packages-are-home-manager-config.md)): its keys are flake ref and attribute without `flake:` and `packages.<system>.` (`nixpkgs#firefox`; `nixpkgs-unfree#x` is another key; `nix eval ~/.config/home-manager#homeConfigurations.$USER.config.webtop.packages.installed` lists them, and a key that matches none is silently off), so a mapping in `local.nix` or the admin's `home.nix` applies only while the package is installed:

```nix
{ config, lib, ... }:
lib.mkIf (config.webtop.packages.installed ? "nixpkgs#firefox") {
  programs.firefox = { enable = true; policies.DisableTelemetry = true; };
  # home-manager installs its own wrapped firefox: leave the declared one out, else they collide.
  webtop.packages.replaced = [ "nixpkgs#firefox" ];
}
```

Not `packages.json`: Nix rewrites it. `nix profile remove firefox` turns the mapping off, also when its values no longer evaluate; a mapping that sets an option that does not exist fails every switch, `mkIf` or not, until it is fixed.

The starter also imports the admin's `home.nix` (below) through its `defaults` input, `path:/run/webtop/defaults`, a non-flake input: delete the `"${defaults}/home.nix"` line (and the input) to opt out. What the admin set is a default: give a value a plain assignment in `home.nix` or `local.nix` and it wins over the admin's `lib.mkDefault`. A list the admin merges into (`home.packages`) cannot be reduced by the user, so an admin puts it behind an option (`site.packages`) that the user reassigns (`site.packages = [ ];` replaces the admin's list). A `local.nix` that sets an option the admin later removes fails its switch until the line goes. A new snapshot (a desktop start after the admin changed the file) changes the input's hash: the setup unit relocks it and switches, so the change applies during the first session after it, in the background. Until then a manual `home-manager switch` or `nix profile add` still evaluates the previous module (the lock holds while its copy is in the store; once collected, they fail on the hash); `nix flake update --flake ~/.config/home-manager defaults` relocks by hand. A `home.nix` that does not parse is replaced by `{ }` (a notification tells the user); one that parses but does not evaluate fails every user's switch, like a broken `local.nix`, so an admin tries it first as a `local.nix` on one desktop.
While unmodified, the starter follows the image's template. An edited one is left alone with a notification: `webtop-home-manager-update` shows the difference and `--apply` takes the template, keeping backups.
A home kept across containers survives a new image: each boot (`nixProfile.fromImageStore`, on by default) moves dangling generations aside and switches, so what `packages.json` declares comes back (needs network); packages added to the profile directly do not. A consumer with its own restore sets it to `false` and runs `nixProfile.reinstall` after that.
`services.webtop.softwareCenter.enable` also writes `/etc/nsc/system-manifest.json` (name, version and store path of each `environment.systemPackages` entry) and points the session's `NSC_SYSTEM_MANIFEST` at it, so the software center shows those apps as "Included with desktop" instead of Install. It is matched by package name, read at startup, and a user's own install wins.
The software center's "Run without installing" builds the package into the store with no GC root and starts its app or program; nothing is added to the profile or `packages.json`.
A consumer whose home is reached through other paths sets `nixProfile.homeStoragePath`, and can receive progress with `nixProfile.progress`.

## Time zone and locale

Time zone, language and formats resolve per key, each from the first valid of: the user's `~/.config/webtop/session.conf` (the home-manager options `webtop.timeZone`, `webtop.locale`, `webtop.language` and `webtop.formats.<LC_x>` of the `packages` home module, or alone `webtop.homeModules.timeLocale`), then the admin's `session.conf` in the defaults directory ("Admin defaults" below), then `services.webtop.timeZone` / `services.webtop.locale`. Keys: `timeZone`, `locale` (`LANG`), `language` (`LANGUAGE`, a `:` list) and `LC_TIME`, `LC_NUMERIC`, `LC_MONETARY`, `LC_MEASUREMENT`, `LC_PAPER`, `LC_COLLATE`, `LC_ADDRESS`, `LC_NAME`, `LC_TELEPHONE`. With none set, `time.timeZone` and `i18n.defaultLocale` apply.
Before each start of `webtop-session.service`, as root, `webtop-locale` takes the first valid value of each key: a zone must resolve to a TZif file under `/etc/zoneinfo` (no `..`, no link out of it), a locale must be in the image, `language` is a `:` list of catalog names. It then relinks `/etc/localtime`, rewrites `/etc/locale.conf` (`LANG`, `LANGUAGE` and the resolved `LC_*`), which `timedatectl` and `localectl` report and the session wrapper loads, so Plasma, its user services and terminals see them, and writes `/run/webtop/xdg-session/plasma-localerc` with the same values (`[Formats]`, `[Translations]`). That file is the highest system layer of Plasma's config cascade: `startplasma` and System Settings (Region & Language) see the resolved values as the system default, and a key saved in `~/.config/plasma-localerc` beats it. The chain for formats is therefore module default < admin < `webtop.*` < System Settings; removing the System Settings key brings the others back. An invalid value is logged to the journal and the next source is used; the session starts regardless. The user's file is read as the user (a link is followed: home-manager's is one into the store; what the user cannot open is not read), a file over 64 KiB is ignored, and other keys are skipped with one journal line per start (keys in `services.webtop.sessionConfKeys` without it). The format is the consumer's: `key=value`, blanks around either ignored, `#` comment lines.
A change is applied by restarting the desktop session (or at the next boot). A time zone set in KDE's settings goes through `timedated` to `/etc/localtime` and holds until then; only `webtop.timeZone` persists. The module sets `i18n.imperativeLocale` (as a default), so `/etc/locale.conf` is a plain file that `localectl` reads and NixOS no longer exports `LANG` itself, and a `time.timeZone` of the system is not combined with these options (`timedatectl` would keep reporting the declared zone). Terminals outside Plasma see `/etc/locale.conf`, not a format the user chose in System Settings.
`services.webtop.locales` lists the locales built into the image (default: en_US, en_GB, de_DE, fr_FR, es_ES, it_IT, nl_NL, pl_PL, pt_PT, sv_SE, all UTF-8, and C.UTF-8). Any other needs a package in the user's profile that provides one, and is not selectable with `webtop.locale` or the formats. ISO dates with 24 h are a locale choice, not a format string: `sv_SE.UTF-8` as `LC_TIME` gives `2026-11-09 15:05` in Qt and glibc (month and weekday names then come in Swedish in long dates); `en_DK.UTF-8` is ISO only in glibc, Qt shows `09/11/2026 15.05`.

### Admin defaults

`services.webtop.defaults.source` (default `/etc/webtop/defaults`; a bind mount, a ConfigMap or `environment.etc`; it may be missing) is a directory of defaults for every desktop. All of it is a default the user can override, none of it is enforced, and every user can read it, so it holds no secrets:

| entry | what | user override |
| --- | --- | --- |
| `session.conf` | `key=value`, the keys above | `webtop.*` options (`~/.config/webtop/session.conf`), per key |
| `xdg/<file>` | KDE/XDG config (`kdeglobals`, `kwinrc`, ...) as ini text, read by every KConfig reader | System Settings, `kwriteconfig6` or plasma-manager (`~/.config/<file>`), per key |
| `home.nix` | a home-manager module, imported by every starter flake through its `defaults` input ("Software") | plain assignments in the user's `home.nix` or `local.nix` over the admin's `lib.mkDefault`; a user's own list option |

`webtop-defaults.service` copies the directory once per boot to the root-owned `/run/webtop/defaults` (links followed, so ConfigMap mounts work), which keeps its content fixed while the desktop runs: a change in the source applies after `systemctl restart webtop-defaults` (or a reboot) and a session start. Only `session.conf`, `xdg/` and `home.nix` are kept. A missing source gives an empty snapshot; a `home.nix` that does not parse (`nix-instantiate --parse`) is replaced by `{ }` and logged, since it would fail every user's switch, and `webtop-defaults-notice.service` (with `nixProfile`) sends the user a notification once Plasma is up. `xdg/plasma-localerc` is dropped: `webtop-locale` owns that layer.
The session wrapper sets `XDG_CONFIG_DIRS` to `/run/webtop/xdg-session`, `/run/webtop/defaults/xdg`, then the previous value (`/etc/xdg` if unset), and the module puts the same two dirs first in `environment.sessionVariables.XDG_CONFIG_DIRS`, because NixOS's `/etc/profile` and `/etc/bashrc` rebuild the variable from it and a terminal would otherwise lose them; `startplasma` puts `~/.config/kdedefaults` in front, and Nix's wrappers of the Plasma programs put their packages' `etc/xdg` before everything (the admin layers stay above `/etc/xdg`). KConfig merges per key, so `~/.config/<file>` holds only what the user changed, and an admin change reaches every key the user has not written. Limits: do not manage KDE rc files with `xdg.configFile` (store links are read-only, so a KCM write fails or replaces the link); the keys a global theme sets cannot be defaulted one by one (next paragraph); panel and widget layout (`plasma-org.kde.plasma.desktop-appletsrc`) is generated at first login and is not cascaded; running plasmashell and KWin read config at start, so admin changes apply at the next session start.
The global theme is defaulted as a whole: `[KDE] LookAndFeelPackage=<id>` in `xdg/kdeglobals`, the id of an installed global theme (e.g. `org.kde.breezedark.desktop`; Plasma's own default is `org.kde.breeze.desktop`). At each session start `startplasma` compares it with `~/.config/kdedefaults/package` and, when they differ, rewrites `~/.config/kdedefaults` (`kdeglobals`, `kwinrc`, `ksplashrc`, `plasmarc`, `kcminputrc`) from that theme and applies its colours to `~/.config/kdeglobals`, so a change reaches existing homes at their next session start. A theme the user picks in System Settings, Global Theme, wins. Its Defaults button then Apply bring the admin's theme back. Like other settings pages built on KConfigSkeleton, it saves the admin's value into the user's own file rather than removing the user's entry. So at each session start `webtop-follow-defaults` removes every entry of the user's file that is the same line, in the same group, as in the admin's file of that name in `xdg/`, for `kdeglobals` and `*rc` files only (the ones KConfig cascades over the user's). A user whose value equals the admin's then follows the admin's later changes, whichever way they set it. It skips links, such as home-manager's, and anything written differently (spacing, `[$...]` flags). An unknown id gives Plasma's default, Breeze. For any key in `xdg/`, `kwriteconfig6 --delete` hides the admin's value too: KConfig writes `<key>[$d]`. Since `~/.config/kdedefaults` sits above the admin's layer, a key the theme's `contents/defaults` sets has no effect in `xdg/` (Breeze: colour scheme, widget style, icon theme, Plasma style, cursor theme, window decoration, splash screen; a theme may also set fonts, window switcher and placement); keys it does not set do.
`webtop-home-manager.sh` relocks any root input of the starter that is locked as `type = path`, not only the registry's: when `nix hash path --sri <path>` differs from the lock's `narHash`, or the path is gone, it runs `nix flake update` for that input and switches. A relative path input is left alone.
`tests/defaults.nix` (`checks.<system>.defaults`) covers this in a VM and prints the results for the assumptions it rests on as `RESULT` lines.

## Consumer keys: sign out at the login provider

Home-manager options `webtop.ssoLogout.onLogout` and `webtop.ssoLogout.onLock` (`null`, the default, leaves the choice to the deployment): when the desktop's session is signed out (`onLogout`) or locked (`onLock`), the browser is also signed out at the login provider. With either set, `~/.config/webtop/session.conf` gets the matching `onLogout=true|false` / `onLock=true|false` lines, which a consumer's gateway can read at event time. The desktop itself only skips them in `webtop-locale`, so standalone the options are harmless no-ops. The options come with the `packages` home module, or alone as `webtop.homeModules.ssoLogout`.

## Notices

`/run/webtop/notices/` is a channel for messages to the user that come from outside the session ([ADR 0019](docs/adr/0019-notices-are-files-in-a-root-owned-directory.md)).
It is owned by root and the desktop user cannot write it, so no app of the session can forge a notice. A notice is a file `<id>.json`:

```json
{"title": "Updates are ready", "body": "Restart your desktop to apply them.", "urgency": "normal", "action": "restart"}
```

`urgency` is `low`, `normal` (default) or `critical`. `action` is optional and `restart` is the only one: a button that runs Plasma's own Restart, with its confirmation; any other value gives a notice without a button. There are no URL actions and no commands. The title is up to 200 and the body up to 2000 characters, plain text (the body is escaped, so markup and links show as typed); the file is at most 16 KiB. Write a temporary name that does not end in `.json` in the directory, then rename it; remove the file to withdraw the notice.

`webtop-notices` (a user service) shows each file as a KDE notification that stays until dismissed. It scans the directory at start, on every change and every 30 s. A notice is shown once per content: if the user dismisses it, it stays dismissed until the next login; if the file changes, it is shown again in place; if the file is removed, it is closed. Files that are invalid, too large or not regular files are skipped with a line in `journalctl --user -u webtop-notices`. On a standalone desktop an admin can drop files there (`/run` is cleared at boot); `tests/notices.nix` (`checks.<system>.notices`) covers it in a VM.

## Lock screen

The greeter of KDE's screen locker cannot be used here (gray, and no password to enter), so a lock never stays: `webtop-lock-guard` (a user service) sees `org.freedesktop.ScreenSaver` `ActiveChanged`, writes the time to `$XDG_RUNTIME_DIR/webtop/lock` and unlocks through logind at once ([ADR 0010](docs/adr/0010-a-lock-is-recorded-and-cleared-at-once.md)). The session and its processes are not touched; only the marker tells that Lock was used, for a consumer to act on (`webtop.ssoLogout.onLock`). Whether Lock is offered in Plasma is chosen at each session start: `services.webtop.lockScreen` (`false`) is the default and `WEBTOP_LOCK_SCREEN=true|false` in a file of `services.webtop.lockEnvironmentFiles` overrides it. Off, the Lock action is hidden and blocked in `/etc/xdg/kdeglobals` (a user's own `~/.config/kdeglobals` can still override that, and the guard still clears the lock). Autolock and lock on resume are off in every case. Only the user's graphical logind session (`Class=user`) is unlocked, so no failure is logged for the manager session. Clearing needs KWin's screen locker on the current logind session, which holds because KWin starts again with every start of `webtop-session` (above).

## KWin without a GPU

KWin 6.8 removed QPainter compositing, and nested under Selkies' CPU-only compositor it finds no
render device (gray screen). With `kwinSoftwarePresentation` (default on) the module grafts
`packages.<system>.kwin` over `kdePackages.kwin` using `system.replaceDependencies`: KWin plus
[LinuxServer's patch](pkgs/kwin/kwin-6.8-software-shm-presentation.patch), which renders with llvmpipe into
memfd buffers and presents over `wl_shm` ([finishing each frame first](pkgs/kwin/kwin-6.8-shm-presentation-finish.patch));
with a GPU nothing changes. Plasma's other packages are
not rebuilt, but evaluating the system builds the stock one first. The patch targets KWin 6.8.x and
`pkgs/kwin.nix` fails the evaluation on other minor versions; on Plasma 6.7 set the option to `false`
([ADR 0004](docs/adr/0004-patched-kwin-grafted-in-for-gpu-less-hosts.md)).

The module grafts `packages.<system>.kguiaddons` the same way, always: KGuiAddons with
[a patch](pkgs/kguiaddons/kguiaddons-clipboard-thread-interruptible-lock.patch) to its Wayland clipboard
thread, which could deadlock plasmashell's exit when the session was stopped in its first seconds. Likewise
`packages.<system>.kded`: kded6 with [a patch](pkgs/kded/kded-sigterm-during-startup.patch) that keeps a stop
coming during its startup, which it otherwise ignored until its 5 s stop timeout.

## One app per screen

A Selkies second-display page (`/#display<n>-<left|right|up|down>`, n >= 2) grows a KWin screen sized
to the page, named `SELKIES-<n>`, and streams it; closing the page removes it. Several can be open at
once, each with its own screen, stream and input
([ADR 0011](docs/adr/0011-one-screen-per-app-page.md)).
Two patches make that work here: KWin announces per-output `kde_output_device_v2` globals again,
which pixelflux needs to confirm the screen (in the patched KWin, so it needs `kwinSoftwarePresentation`;
[ADR 0004](docs/adr/0004-patched-kwin-grafted-in-for-gpu-less-hosts.md)),
and Selkies lays out a second display while no primary page is connected
([patch](pkgs/selkies/second-display-without-primary.patch), [for upstream](docs/upstream/selkies-second-display-without-primary.md)).

To show one app on such a page, run as the desktop user inside the session:

```sh
webtop-app-screen place <app-id> <screen>   # e.g. place org.kde.dolphin SELKIES-2
webtop-app-screen release <app-id>
webtop-app-screen focus <screen>|main       # the keyboard goes to the top window there
webtop-app-screen screens                   # lists the SELKIES-<n> screens
```

`place` loads a KWin script (`pkgs/app-screen/app-screen.js`) that moves every window of the app
(matched by Wayland app id, X11 class or desktop file name, with or without `.desktop`) and its
dialogs to the screen, makes normal windows fullscreen (maximized if they cannot be) and activates
them. It stays loaded: windows opened later are moved too, so none stays on the primary screen that
nobody may be watching, and if the screen goes and comes back (page reload) they return. `place`
can run before the app starts or the screen exists; running it again replaces the previous one.
When the screen goes (page closed) the script puts the windows it changed back on the main screen (any
screen that is not a `SELKIES-<n>`) and restores their state, so the panel is reachable; a window the
user had fullscreened before stays fullscreen. `release` unloads the script, then runs a one-shot
script that sends the app's windows on a `SELKIES-<n>` screen to the main screen and un-fullscreens
and un-maximizes them (prior state is gone with the unloaded script); with no main screen it moves
nothing. `place` is a no-op while the same script already runs, so the windows keep their prior state. All need `DBUS_SESSION_BUS_ADDRESS`
and `XDG_RUNTIME_DIR`; exit status 2 is a usage error, 1 means KWin refused the script.

Starting the app is the caller's job, and so is telling `focus` which tab was activated: there is one
keyboard seat, so a key goes to KWin's active window whichever page sent it. A second page of the same
`<n>` takes the screen over and the first shows "Connection Terminated". Hidden tabs stop their capture.
Audio plays on the primary page only.

Screens sit in a row from x=4096, right of any auto-sized primary (the web client caps a page at 4080),
and stay put when the primary resizes or a neighbour closes (moving an output recreates it). Each one is
a KWin output plus a capture and encoder: see "Cost of app screens".

### Cost of app screens

From `checks.app-screens` (CI VM, 4 vCPUs shared with the test's browser, llvmpipe, JPEG since the headless
browser has no H.264; each screen 1024x640; session processes without the apps themselves):

| app screens | memory | CPU, apps idle | CPU, every app repainting all pixels at 30 fps |
| --- | --- | --- | --- |
| 0 | 1980 MiB | 1% of a core | |
| 1 | 2076 MiB | 2% | 136% |
| 2 | 2185 MiB | 5% | 160% |
| 4 | 2418 MiB | 7% | 127% |

So about 110 MiB and 2% of a core per screen at rest. Under full repaint the Selkies process grows by
10-15% of a core per screen (17%, 27%, 46%), while the total is limited by the shared VM rather than
growing with the count, so it is no per-screen figure; expect a busy screen to cost more than one core
on software rendering. x264 was not measured.

## Several pages on one desktop

The page opened last owns the primary display: the desktop takes that page's window size, and the
pages before it stay connected beside it, streaming and playing audio, with their input working and
their own resizes ignored ([patch](pkgs/selkies/latest-owner.patch), [for upstream](docs/upstream/selkies-latest-owner.md)).
A reload counts as opening the page. A page cut off that reconnects by itself claims nothing, and a
page beside the owner never takes the display by itself; when the owner leaves, the page opened last
beside it (one with full permissions first) takes over, so closing a phone returns the desktop to the monitor, not the laptop. Second displays, viewers and `SELKIES_ENABLE_SHARING=false` work as in stock Selkies.

## Image

`packages.<system>.image` is the module as a container, systemd as PID 1 ([image/container.nix](image/container.nix)),
published on `main` as `ghcr.io/lhns/webtop-nix:main` (and `sha-<sha7>`), amd64 and arm64:

```sh
docker run --rm --privileged --cgroupns=private --shm-size=1g -p 127.0.0.1:8082:8082 \
  -v webtop-persist:/persist -v webtop-home:/home ghcr.io/lhns/webtop-nix:main
```

Then open http://127.0.0.1:8082. Selkies' own authentication is off: publish the port on loopback,
or put an authenticating proxy in front.

The entrypoint ([image/webtop-entrypoint](image/webtop-entrypoint)) mounts the [store overlay](#store-overlay)
on `/persist` (the image declares it a `VOLUME`; without `-v` docker makes an anonymous one) and the `/sys/power`
stand-in that lets [Sleep](#sleep-and-session-save) be offered. Software installed with `nix profile` lives in
`/persist` and the home in `/home`: keep them together. A home that outlives its store (a new `/persist`) gets the reinstall once at its next boot: declared packages come back, a package only in the old profile does not. `docker stop` saves the session; `docker kill` does not.

`lib.buildImage { name; nixos; copyToRoot ? []; config ? {}; extraGroups ? []; reference ?; tag ?; }` builds
such an image from any NixOS system with nix2container ([ADR 0005](docs/adr/0005-image-builder-with-a-layer-split-from-the-closure.md)).
The layers are a split of the system's closure ([image/default.nix](image/default.nix)), from stable to volatile:
base, toolkits, data, KDE, Firefox, webtop packages, the KWin graft, then the caller's `extraGroups`
(e.g. sources it bakes in), its own packages and config; the Nix DB and `copyToRoot` form the top layer.
Paths not in the standalone image's closure (`reference`; `null` to classify by the system alone)
go to the caller's groups, so its own packages never move the stack's layers. The build prints the
table (`nix build .#image.layerSplit`, `table.txt`); `nix run .#layer-report -- <image json> <groups.json> --previous <ref>`
shows which layers are new against a published image. Push with zstd at the level CI uses
(`nix run .#image.copyTo -- --dest-compress-format zstd --dest-compress-level 6 docker://…`), so unchanged layers keep their blob.

## Features and third-party changes

What this flake provides, all without Kubernetes:

- Selkies + pixelflux + pcmflux stream a nested KWin/Plasma 6 session over HTTP ([ADR 0001](docs/adr/0001-selkies-with-kwin-nested-in-pixelflux.md)); a real logind session with standard power management ([0003](docs/adr/0003-a-real-logind-session-with-standard-power-management.md)); a null audio sink, clipboard, file upload and download, per-user Selkies settings (`userSettings`), several pages on one desktop, one app per screen.
- GPU-less rendering through a patched KWin ([0004](docs/adr/0004-patched-kwin-grafted-in-for-gpu-less-hosts.md)).
- Software installation from one declaration (`nixProfile`, the Software Center; [0006](docs/adr/0006-software-installation-in-this-flake.md), [0007](docs/adr/0007-nix-profile-commit-locks.md)).
- The container module and its options (below, [0008](docs/adr/0008-container-module-and-options-for-standalone-use.md)); Sleep that freezes the session and the session save on an external stop ([0012](docs/adr/0012-sleep-freezes-the-session-an-external-stop-saves-it.md)); the Nix store overlay that survives image updates ([0013](docs/adr/0013-the-store-overlay-survives-image-updates.md)); the layered image builder `lib.buildImage` ([0005](docs/adr/0005-image-builder-with-a-layer-split-from-the-closure.md)); module defaults for cursors (`XCURSOR_*`), a 30 fps start and DrKonqi's crash pickup without a runtime limit.

Every change to a third-party program, and why:

| what | change | why |
| --- | --- | --- |
| KWin 6.8 | [software presentation](pkgs/kwin/kwin-6.8-software-shm-presentation.patch) (LinuxServer's, vendored) and [finishing each frame](pkgs/kwin/kwin-6.8-shm-presentation-finish.patch) | KWin 6.8 has no QPainter compositing; without a GPU, nested in Selkies, it shows a gray screen |
| KWin 6.7 | [output device globals](pkgs/kwin/kwin-6.7-output-device-globals.patch) (LinuxServer's, vendored) | pixelflux confirms a second display by a `kde_output_device_v2` global |
| Selkies | [second display without primary](pkgs/selkies/second-display-without-primary.patch) | a page for one app's screen connects on its own |
| Selkies | [upload path](pkgs/selkies/upload-path.patch) | downloads serve the whole home while uploads land in one inbox |
| Selkies | [several second displays](pkgs/selkies/several-second-displays.patch), plus a [web client edit](pkgs/selkies/display-n.sed) for `#display<n>` | Selkies drives one secondary at a time; each app page needs its own |
| Selkies | [latest page owns the display](pkgs/selkies/latest-owner.patch), plus a web client edit that tells a reconnect from a new page | with several pages open, the one opened last drives the primary display |
| Selkies web client | sidebar padding and handle for touch ([css](pkgs/selkies/touch-handle.css)); a special-key bar above the on-screen keyboard on touch screens ([js](pkgs/selkies/key-bar.js), [css](pkgs/selkies/key-bar.css), [test](tests/key-bar-test.py)); touchpad acceleration capped at 1.5x, speeds down to 0.1; changed assets renamed by hash | the stock sidebar crowds the handle on touch and the stock touchpad is too fast; the on-screen keyboard has no Esc, Tab, Ctrl, arrows or F-keys; stale browser copies would hide the change |
| Nix 2.34 | [`nix profile` backends](modules/nix-profile/nix/profile-backends.patch) | `nix profile` edits `packages.json` and runs home-manager |
| Nix 2.34 | [cacheable `path:` inputs](modules/nix-profile/nix/path-input-fingerprint.patch) | a locked `path:` input (the registry's nixpkgs) otherwise copies all of nixpkgs into the store on each evaluation; drop it once upstream has a fingerprint |
| Nix Software Center | [fork `lhns/nix-software-center`](pkgs/nix-software-center.nix), pinned | no network probe (`onlineCheckUrl = ""`), no system package set (`systemPackages = false`), unfree apps through the `nixpkgs-unfree` registry flake, apps of the image shown as "Included with desktop" |
| pixelflux, pcmflux | none | built from source at the commits that released the PyPI wheels |

## Container module

`nixosModules.container` is the desktop as a container with systemd as PID 1 (runtime-owned `resolv.conf`/`hosts`, no consoles,
no core dumps, no rtkit or oomd); the standalone image is `webtop` plus this ([ADR 0008](docs/adr/0008-container-module-and-options-for-standalone-use.md)). It sets no `services.webtop.*` and no `stateVersion`.

| option | default | what |
| --- | --- | --- |
| `services.webtop.storeOverlay.enable` | `false` | the Nix daemon uses a `local-overlay` store: the image's store (`lowerRoot`, `/.lower`) is read-only below, a volume (`persistPath`, `/persist/nix`; `upperLayer`) above. The entrypoint mounts it before systemd runs with `storeOverlay.init` ("Store overlay"); the daemon alone opens the store, clients go through it. `fsync-store-paths` is on by default (the update below relies on it); `trusted-users` and `sandbox` stay with the consumer; needs `nixProfile.enable` |
| `services.webtop.journalRelay.enable` | `false` | writes the journal to the fifo `path` (`/run/webtop/console`) for the entrypoint to copy to the container log |
| `services.webtop.adminTools.enable` | `false` | ps, ip, lsof, git, jq, curl, wget, htop and a few more in the system (the standalone image sets it) |
| `services.webtop.sudo.enable` | `false` | the desktop user joins `wheel` with an empty password and passwordless sudo; only where the container is the user's own |

In a container the `webtop` module defaults `sleep.mode` to `freeze` and `sessionSave.enable` to on ("Sleep and session save"; ADR 0008: the defaults sit in `webtop.nix`, keyed on `boot.isContainer`, the container module sets no `services.webtop.*`).

Not in this flake: whatever reports to or is driven by an orchestrator, such as an agent that reports power actions and boot progress, or a tray job that shows the restore.
The software restore's progress (`nixProfile.progress`, default `webtop-restore-progress`) is written to `/run/webtop/restore/progress.json`
(`active`, `done`, `total`, `current`, `failed`, `message`) with the Nix log beside it (the restore's copy phase counts roots, the reinstall's counts packages; a new phase restarts the file); this flake shows none of it; a consumer's agent can.

## Sleep and session save

Sleep (`systemd-suspend.service`, what the desktop's Sleep action and `systemctl suspend` start) cannot suspend a container ([ADR 0012](docs/adr/0012-sleep-freezes-the-session-an-external-stop-saves-it.md)).
`services.webtop.sleep.mode`:

| mode | what Sleep does | default |
| --- | --- | --- |
| `systemd` | systemd's own suspend | outside containers |
| `freeze` | `webtop-power suspend` freezes the session (`plasma-*` in `session.slice`, everything in `app.slice`) with the cgroup freezer and waits; a Selkies session that was not there at Sleep (a new id, or more sessions than the fewest seen since) thaws it. Selkies, the session bus, audio and `background.slice` keep running. Hibernation variants are off | in containers |
| `poweroff` | saves the session, writes `/run/webtop/stop-reason` (containing `suspend`) and powers off | |

A freeze that fails is thawed again and falls back to `poweroff`. `WEBTOP_SUSPEND_MODE=freeze|poweroff` in a file of `sleep.environmentFiles` switches between the two at each Sleep (it does not turn `systemd` into `freeze`); `WEBTOP_HTTP_PORT` in such a file names Selkies' port if it is not `port`.
`sleep.hooks` are commands run as root with `asleep` right after the freeze and `awake` right after the thaw (best effort, 10 s each): a consumer reports the state with them. The frozen units are listed in `/run/webtop/frozen-units` while asleep.
Logind offers Sleep only if `/sys/power/state` is writable: a container's entrypoint runs `sleep.init` (`bin/webtop-sys-power`, static busybox, needs `/run`), which binds a stand-in over it. Without that Sleep is never offered.

`sessionSave.enable` (on in containers) adds `webtop-session-save.service`, stopped before the session. When the stop comes from outside (`docker stop`, a pod deletion: SIGRTMIN+3 queues `halt.target`) or from Sleep's `poweroff`, it thaws what Sleep froze, asks ksmserver to save and copies the "saved by user" group of `ksmserverrc` to "saved at previous logout", which Plasma restores. A shutdown from inside the desktop saves by itself, `systemctl poweroff` does not (as on a real machine). `sessionSave.command` is the package with `bin/webtop-power save-session` for a consumer's own stop.
`webtop-power` is a small Go program ([pkgs/webtop-power](pkgs/webtop-power)): `suspend`, `thaw`, `save-session`.

## Store overlay

With `storeOverlay.enable` the user's Nix store survives the container and image updates ([ADR 0013](docs/adr/0013-the-store-overlay-survives-image-updates.md)). `/nix/store` is an overlayfs: the image's store below (bound read-only at `/.lower`), the volume above. `storeOverlay.init` is a package of static busybox scripts for the entrypoint to run as root, with `/run` mounted, mounts private and the volume in place, before `exec /sbin/init` ([image/webtop-entrypoint](image/webtop-entrypoint) is an example): `webtop-store-init` mounts the overlay and binds `var` on `/nix/var/nix`. It needs `/webtop-image-stamp` in the image: a hash of the image's store (the standalone image builds it from the system's closure, see [flake.nix](flake.nix)). `fsync-store-paths` is on by default (`mkDefault`): the update below keeps upper paths by their database rows.

Layout under `persistPath` (`/persist/nix`), fixed for existing volumes (`tests/store-overlay-layout-test.sh` pins it):

| path | what |
| --- | --- |
| `upper`, `work` | the overlay's upper and work directories |
| `var` | `/nix/var/nix` of the overlay store: its database (the upper paths and the lower paths they reference), GC roots, profiles |
| `lower-stamp`, `lower-paths` | the stamp and path list of the image's store the upper was built with |
| `reinstall/` | after an update: each user's profile manifest, and the markers `pending` (the reinstall is due) and `restore` (the restore is due) |
| `trash-*/` | what an update moved out of the overlay, until the restore has copied the users' paths from it |

On an image whose store differs from the stamp, `webtop-nix-lower` first records each user's Nix profile manifest (`WEBTOP_HOMES_ROOT`, default the directory of `nixProfile.homeStoragePath`, names the homes; `webtop-nix-restore` reads the same variable), then `webtop-nix-partial` invalidates, with Nix's own GC, only the upper paths whose closure the new store breaks. If that fails the overlay is reset: it moves to `trash-*` and the markers are set. `storeOverlay.enable` requires `nixProfile.enable` (an assertion): the module then runs `webtop-nix-restore` (copies the users' paths from `trash-*`, substitutes what only the old image had), `webtop-nix-trash` and `webtop-nix-reinstall` (what did not come back, from the manifest), and `webtop-home-manager` waits for `pending` to go. `nixProfile.fromImageStore` defaults to off then. `tests/lower-swap-test.sh` runs this end to end on the image. A fresh volume under a home that already has a Nix profile (the store volume lost or not mounted) sets `reinstall/pending` on its first boot, so the reinstall runs once and the declared packages come back.

## Extension points

A consumer (a deployment that builds its own system from these modules; [kube-webtop-workspaces](https://github.com/lhns/kube-webtop-workspaces) is one) extends the desktop only
through what this section lists. The module's units are not an interface: their commands, files and
ordering may change between commits, so set an option instead of overriding a unit.

| option | default | what |
| --- | --- | --- |
| `services.webtop.environmentFiles` | `[ ]` | `EnvironmentFile=` of the Selkies user service: `SELKIES_*` settings (above, "Runtime settings") |
| `services.webtop.sessionEnvironmentFiles` | `[ ]` | `EnvironmentFile=` of `webtop-session.service`: environment for Plasma and the apps it starts |
| `services.webtop.sessionStopCommands` | `[ ]` | `ExecStopPost=` lines of `webtop-session.service`, run after each end of the session (Log Out, crash, restart, shutdown) once Plasma is stopped; `+` runs one as root, `-` ignores its failure, `$SERVICE_RESULT` and `$EXIT_CODE` tell how the session ended |
| `services.webtop.defaults.source` | `/etc/webtop/defaults` | the admin's defaults directory: `session.conf`, `xdg/`, `home.nix` ("Time zone and locale", "Admin defaults") |
| `services.webtop.lockEnvironmentFiles` | `[ ]` | `WEBTOP_LOCK_SCREEN=true\|false` ("Lock screen") |
| `services.webtop.sessionConfKeys` | `[ ]` | keys of the user's `~/.config/webtop/session.conf` that the consumer reads; the desktop skips them instead of logging them as unknown |
| `services.webtop.nixProfile.templateEnvironmentFiles` | `[ ]` | `EnvironmentFile=` of `webtop-home-manager-template.service`: `WEBTOP_HOME_PATHS`, the space-separated `/home/<name>` paths this home has been mounted at, so a starter rendered for an earlier login name still counts as unmodified |
| `services.webtop.nixProfile.homeStoragePath`, `.fromImageStore`, `.progress` | | "Software" |
| `services.webtop.sleep.mode`, `.environmentFiles`, `.hooks`, `.init` | `freeze` in containers | Sleep: `WEBTOP_SUSPEND_MODE=freeze|poweroff` and `WEBTOP_HTTP_PORT` in the env files, commands told `asleep` / `awake`, the `/sys/power` stand-in for an entrypoint ("Sleep and session save") |
| `services.webtop.sessionSave.enable`, `.command` | on in containers | the session save on an external stop; `bin/webtop-power save-session` ("Sleep and session save") |
| `services.webtop.storeOverlay.persistPath`, `.init` | `/persist/nix` | the overlay's state on the volume, and the scripts for an entrypoint; `WEBTOP_HOMES_ROOT` names the homes whose profile manifests an update records and the restore reads ("Store overlay") |

All env files are read at each start of their unit, so a consumer can write them at boot without a
rebuild; a `-` prefix makes one optional, later files win.

Files and commands a consumer can use:

| what | contract |
| --- | --- |
| `~/.config/webtop/session.conf` | the user's `key=value` file (blanks around either ignored, `#` comment lines, at most 64 KiB); the desktop reads `timeZone`, `locale`, `language` and the `LC_*` formats, a consumer its `sessionConfKeys` |
| `/run/webtop/defaults/` | the snapshot of the defaults directory, root-owned, taken once per boot by `webtop-defaults.service`; its `home.nix` is the starter flake's `defaults` input, which `webtop-home-manager.service` relocks when the snapshot changes ("Admin defaults", "Software") |
| `~/.config/webtop/selkies.env` | the user's Selkies settings, limited to `userSettings` |
| `$XDG_RUNTIME_DIR/webtop/lock` | written (the time) each time the session is locked ("Lock screen") |
| `/run/webtop/restore/progress.json` | the software restore's progress ("Container module") |
| `/run/webtop/frozen-units`, `/run/webtop/stop-reason` (containing `suspend`) | exist while Sleep has the session frozen, and once Sleep chose to power off ("Sleep and session save") |
| `/persist/nix/reinstall/{pending,restore}` | exist while an image update's reinstall or restore is due ("Store overlay") |
| `nixProfile.notify` | `webtop-notify TITLE BODY [ICON]`: a notification in the session |
| `nixProfile.reinstall` | `webtop-nix-reinstall MANIFEST`: bring the user's packages back after the store lost them |
| `webtop-template` | on the system path with `nixProfile`: update a file the image wrote into the home only while unmodified |

Units a consumer may order its own against: `webtop-defaults.service`, `webtop-session.service`, `webtop-home-manager-template.service`,
`webtop-home-manager.service`, `webtop-session-save.service`, `webtop-nix-restore.service`, `webtop-nix-reinstall.service` and the user service `selkies.service`.

## Tests

`nix build .#checks.<system>.module-eval` evaluates a system with the module (not with `--no-build`: the graft is import from derivation, so evaluating builds).
`nix flake check` needs a builder for every supported system: it evaluates each system's `module-eval`.
Evaluating the system realises the stock closure first (the graft), so the checks need several GB of disk.
`checks.<system>.vm` boots the module and needs KVM to run; it also asserts that KWin composites (the gray-screen check), the runtime-settings precedence, uploads into the XDG download directory (not the home) and downloads from the home.
`checks.<system>.app-screens` runs three apps on three pages and asserts each page's stream and input reach only its app, focus, dialogs, no overlap with the main screen, the main page beside them, closing the middle one, reopening, reload, takeover and stopping Selkies with pages open; it also measures the cost at 1, 2 and 4 screens into `summary.txt` (artifact `app-screens`).
`checks.<system>.power` boots the module with `sleep.mode = "freeze"` and asserts that Sleep freezes the session's units (not Selkies), runs the hooks, is woken by a new Selkies client but not by one that was there, that an external stop thaws before it saves, and that a `poweroff` Sleep saves the session. `checks.<system>.store-overlay-layout` runs the overlay scripts on a scratch directory and pins the names on the volume; `tests/store-overlay-docker.sh` runs `webtop-nix-restore` and `webtop-nix-lower`/`-partial` against real overlay stores in privileged containers (crash, failure and pause cases through the `WEBTOP_TEST_*` hooks of the scripts), and `tests/lower-swap-test.sh` (CI, on the image) is the update end to end. `go test ./...` in [pkgs/webtop-power](pkgs/webtop-power) runs with the package build.
`checks.<system>.software-center-run` runs the software center backend's "Run without installing" (`nsc-backend-smoke --run`) on two offline fixture packages, an app with a desktop entry and a program, and asserts both start, and that the profile, `packages.json` and the GC roots are unchanged and the built paths are garbage. Needs KVM.
`checks.<system>.second-display` opens a display2 page alone in headless Chromium and asserts the [one-app-per-screen](#one-app-per-screen) path: the screen appears and streams, input arrives at the page's coordinates, the app's windows (also later ones) land on it, and it goes away with the page. CI runs its driver outside the sandbox and uploads `summary.txt`, screenshots and logs as the `second-display` artifact.
CI builds the packages and `module-eval` natively on both systems (GitHub's arm runners for aarch64); the VM tests run on x86_64 only (no KVM on the arm runners).

Update nixpkgs here first (`nix flake update nixpkgs`); consumers follow this flake's nixpkgs.
`tests/nix-profile-template-test.sh` and `tests/nix-profile-reinstall-test.sh` run the starter's template upgrade and the reinstall without Nix; `tests/nixpkgs-unfree-test.sh` checks `nixpkgs-unfree` on real Nix. `tests/nix-profile-image-test.sh` runs the `nix profile` backends, hooks, rollback, settings mappings and the template lifecycle (including an earlier template, `tests/previous-template`) on the image.
`tests/defaults-input-test.sh` runs the starter's `defaults` input and the relock on real Nix, stock and patched: a non-store `path:` input with `flake = false` locks and evaluates purely, a changed directory keeps evaluating the locked content (and fails on the narHash once that copy is gone from the store), and the setup script relocks it.
`tests/nix-profile-concurrency.sh` runs concurrent `nix profile` commands with the patched Nix and home-manager, on a temporary home.
CI also builds the image on both systems, boots it under docker (the admin's `home.nix` switched in, overridden and removed, Selkies page, KWin compositing, the lower store's DB = its store, the overlay, Sleep, `nix profile` into the declaration, `local.nix`, a restart on the same volumes) and prints its layer table; on `main` it pushes the image and the multi-arch index, signed with cosign.

Licence: Apache-2.0 (this repo); the packaged software is MPL-2.0 (the pixelflux build also links GPL-2.0-or-later libx264 and x265, so the built extension is GPL-2.0-or-later).
