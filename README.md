# webtop-nix

Nix packages and a NixOS module for a browser-streamed Plasma 6 desktop: [Selkies](https://github.com/selkies-project/selkies)
(with its pixelflux Wayland compositor/encoder and pcmflux audio) streams a KWin session to a web page.
Nothing here is site-specific; deployment wiring belongs in the consuming repo.

## Packages

`packages.<system>.{pixelflux,pcmflux,selkies,webtop-app-screen,kwin}` for `x86_64-linux` and `aarch64-linux`, and `overlays.default` (adds the same
attributes, `kwin` as `kwinSoftwarePresentation`, and the Python packages in `pythonPackagesExtensions`; the top-level Python
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
- `webtop-session.service`: `startplasma-wayland` as the user (PAM `login`, `seat`), nested in that socket once its lock is held. Log Out ends it and it starts again; any stop of it (restart, crash, Log Out) also stops `graphical-session.target` in the user manager, so KWin and Plasma always start in the new logind session, also after a Log Out in a session's first seconds. Selkies and `webtop-lock-guard` keep running.
- No `SELKIES_SUBFOLDER`: behind a path-prefixing gateway that strips the prefix, the web client derives it from the page URL.
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
While unmodified, the starter follows the image's template. An edited one is left alone with a notification: `webtop-home-manager-update` shows the difference and `--apply` takes the template, keeping backups.
A home kept across containers survives a new image: each boot (`nixProfile.fromImageStore`, on by default) moves dangling generations aside and switches, so what `packages.json` declares comes back (needs network); packages added to the profile directly do not. A consumer with its own restore sets it to `false` and runs `nixProfile.reinstall` after that.
`services.webtop.softwareCenter.enable` also writes `/etc/nsc/system-manifest.json` (name, version and store path of each `environment.systemPackages` entry) and points the session's `NSC_SYSTEM_MANIFEST` at it, so the software center shows those apps as "Included with desktop" instead of Install. It is matched by package name, read at startup, and a user's own install wins.
A consumer whose home is reached through other paths sets `nixProfile.homeStoragePath`, and can receive progress with `nixProfile.progress`.

## Time zone and locale

The session's time zone and locale come from, in order: the user's `webtop.timeZone` / `webtop.locale` (home-manager options of the `packages` home module, or alone as `webtop.homeModules.timeLocale`; they write `timeZone=` and `locale=` to `~/.config/webtop/session.conf`), then `WEBTOP_TIME_ZONE` / `WEBTOP_LOCALE` from `services.webtop.localeEnvironmentFiles` (kube-webtop-workspaces passes its chart values this way), then `services.webtop.timeZone` / `services.webtop.locale`. With none set, `time.timeZone` and `i18n.defaultLocale` apply.
Before each start of `webtop-session.service`, as root, `webtop-locale` takes the first valid value of each: a zone must resolve to a TZif file under `/etc/zoneinfo` (no `..`, no link out of it), a locale must be in the image. It then relinks `/etc/localtime` and rewrites `/etc/locale.conf` (`LANG` only), which `timedatectl` and `localectl` report and the session wrapper loads, so Plasma, its user services and terminals see them. An invalid value is logged to the journal and the next source is used; the session starts regardless. The user's file is read as the user (a link is followed: home-manager's is one into the store; what the user cannot open is not read), a file over 64 KiB is ignored, and other keys are skipped with one journal line per start. The format is the gateway's: `key=value`, blanks around either ignored, `#` comment lines.
A change is applied by restarting the desktop session (or at the next boot). A time zone set in KDE's settings goes through `timedated` to `/etc/localtime` and holds until then. The module sets `i18n.imperativeLocale` (as a default), so `/etc/locale.conf` is a plain file that `localectl` reads and NixOS no longer exports `LANG` itself, and a `time.timeZone` of the system is not combined with these options (`timedatectl` would keep reporting the declared zone).
`services.webtop.locales` lists the locales built into the image (default: en_US, en_GB, de_DE, fr_FR, es_ES, it_IT, nl_NL, pl_PL, pt_PT, all UTF-8, and C.UTF-8). Any other needs a package in the user's profile that provides one, and is not selectable with `webtop.locale`.

## Sign out at the login provider

Home-manager options `webtop.ssoLogout.onLogout` and `webtop.ssoLogout.onLock` (`null`, the default, leaves the choice to the deployment): when the desktop's session is signed out (`onLogout`) or locked (`onLock`), the browser is also signed out at the login provider. With either set, `~/.config/webtop/session.conf` gets the matching `onLogout=true|false` / `onLock=true|false` lines, which a [kube-webtop-workspaces](https://github.com/lhns/kube-webtop-workspaces) gateway reads at event time. It only has an effect behind a gateway with a logout URL configured; standalone, the options are harmless no-ops. The options come with the `packages` home module, or alone as `webtop.homeModules.ssoLogout`.

## Lock screen

The greeter of KDE's screen locker cannot be used here (gray, and no password to enter), so a lock never stays: `webtop-lock-guard` (a user service) sees `org.freedesktop.ScreenSaver` `ActiveChanged`, writes the time to `$XDG_RUNTIME_DIR/webtop/lock` and unlocks through logind at once ([ADR 0010](docs/adr/0010-a-lock-is-recorded-and-cleared-at-once.md)). The session and its processes are not touched; only the marker tells that Lock was used, for a gateway to act on (`webtop.ssoLogout.onLock`). Whether Lock is offered in Plasma is chosen at each session start: `services.webtop.lockScreen` (`false`) is the default and `WEBTOP_LOCK_SCREEN=true|false` in a file of `services.webtop.lockEnvironmentFiles` overrides it. Off, the Lock action is hidden and blocked in `/etc/xdg/kdeglobals` (a user's own `~/.config/kdeglobals` can still override that, and the guard still clears the lock). Autolock and lock on resume are off in every case. Clearing needs KWin's screen locker on the current logind session, which holds because KWin starts again with every start of `webtop-session` (above).

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
docker run --rm --privileged --cgroupns=private --shm-size=1g -p 127.0.0.1:8082:8082 ghcr.io/lhns/webtop-nix:main
```

Then open http://127.0.0.1:8082. Selkies' own authentication is off: publish the port on loopback,
or put an authenticating proxy in front.

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
- The container module and its options (below, [0008](docs/adr/0008-container-module-and-options-for-standalone-use.md)); the layered image builder `lib.buildImage` ([0005](docs/adr/0005-image-builder-with-a-layer-split-from-the-closure.md)); module defaults for cursors (`XCURSOR_*`), a 30 fps start and DrKonqi's crash pickup without a runtime limit.

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
| `services.webtop.storeOverlay.enable` | `false` | the Nix daemon uses a `local-overlay` store: the image's store (`lowerRoot`, `/.lower`) is read-only below, a volume (`upperLayer`) above. The entrypoint must mount overlayfs on `/nix/store` before systemd runs; the daemon alone opens the store, clients go through it. `trusted-users`, `fsync-store-paths` and `sandbox` stay with the consumer |
| `services.webtop.journalRelay.enable` | `false` | writes the journal to the fifo `path` (`/run/webtop/console`) for the entrypoint to copy to the container log |
| `services.webtop.adminTools.enable` | `false` | ps, ip, lsof, git, jq, curl, wget, htop and a few more in the system (the standalone image sets it) |
| `services.webtop.sudo.enable` | `false` | the desktop user joins `wheel` with an empty password and passwordless sudo; only where the container is the user's own |

Not in this flake because they need Kubernetes or its daemon: the entrypoint that mounts the overlay, the agent (power actions and
boot progress reported to a controller) and the restore around an image update, including `webtop-session-save`, which writes the
Plasma session when a pod is deleted. A standalone container stopped from outside loses the unsaved session unless the user logs out first.
The software restore's progress (`nixProfile.progress`, default `webtop-restore-progress`) is written to `/run/webtop/restore/progress.json`
(`active`, `done`, `total`, `current`, `failed`, `message`) with the Nix log beside it; this flake shows none of it, the consumer's agent does.

## Tests

`nix build .#checks.<system>.module-eval` evaluates a system with the module (not with `--no-build`: the graft is import from derivation, so evaluating builds).
`nix flake check` needs a builder for every supported system: it evaluates each system's `module-eval`.
Evaluating the system realises the stock closure first (the graft), so the checks need several GB of disk.
`checks.<system>.vm` boots the module and needs KVM to run; it also asserts that KWin composites (the gray-screen check), the runtime-settings precedence, uploads into the XDG download directory (not the home) and downloads from the home.
`checks.<system>.app-screens` runs three apps on three pages and asserts each page's stream and input reach only its app, focus, dialogs, no overlap with the main screen, the main page beside them, closing the middle one, reopening, reload, takeover and stopping Selkies with pages open; it also measures the cost at 1, 2 and 4 screens into `summary.txt` (artifact `app-screens`).
`checks.<system>.second-display` opens a display2 page alone in headless Chromium and asserts the [one-app-per-screen](#one-app-per-screen) path: the screen appears and streams, input arrives at the page's coordinates, the app's windows (also later ones) land on it, and it goes away with the page. CI runs its driver outside the sandbox and uploads `summary.txt`, screenshots and logs as the `second-display` artifact.
CI builds the packages and `module-eval` natively on both systems (GitHub's arm runners for aarch64); the VM tests run on x86_64 only (no KVM on the arm runners).

Update nixpkgs here first (`nix flake update nixpkgs`); kube-webtop-workspaces follows this flake's nixpkgs.
`tests/nix-profile-template-test.sh` and `tests/nix-profile-reinstall-test.sh` run the starter's template upgrade and the reinstall without Nix; `tests/nixpkgs-unfree-test.sh` checks `nixpkgs-unfree` on real Nix.
`tests/nix-profile-concurrency.sh` runs concurrent `nix profile` commands with the patched Nix and home-manager, on a temporary home.
CI also builds the image on both systems, boots it under docker (Selkies page, KWin compositing, Nix DB = store, `nix profile` into the declaration, `local.nix`) and prints its layer table; on `main` it pushes the image and the multi-arch index, signed with cosign.

Licence: Apache-2.0 (this repo); the packaged software is MPL-2.0 (the pixelflux build also links GPL-2.0-or-later libx264 and x265, so the built extension is GPL-2.0-or-later).
