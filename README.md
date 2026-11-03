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
| selkies | 2.1.0 | PyPI wheel (bundles the built web client), with [one patch](pkgs/selkies/second-display-without-primary.patch) |
| webtop-app-screen | — | this repo: keeps an app's windows on one screen ([below](#one-app-per-screen)) |

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
`openFirewall`, `softwareRendering` (`true`: `LIBGL_ALWAYS_SOFTWARE`), `kwinSoftwarePresentation` (`true`: patched KWin, see below), `seat` (`""` in containers, else `seat0`),
`lockScreen` (`false`: autolock off and locking disabled via `/etc/xdg`), `waylandSocketIndex` (`1`), `clipboard` (`"true"`; also `"in"`, `"out"`, `"false"`),
`fileTransfers` (`[ "upload" "download" ]`; `[ ]` disables), `fileManagerPath` (`~`: downloads are served from the whole home), `uploadPath` (`null`: the user's XDG download directory, see below), `environmentFiles` (`[ ]`), `userSettings` (allowlist, see below), `browserCursors` (`true`), `package`, `extraEnvironment` (extra `SELKIES_*` settings).

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
- Only the account's declaration uses `user`: units, lingering and the polkit rule go by `uid` and the
  group `webtop`, so a deployment may rename the account at runtime (e.g. in an activation script after `users`).
- `selkies.service` (user unit): pixelflux hosts a Wayland socket `wayland-<waylandSocketIndex>` (default `wayland-1`; stale sockets are removed at start).
- `webtop-session.service`: `startplasma-wayland` as the user (PAM `login`, `seat`), nested in that socket once its lock is held.
- No `SELKIES_SUBFOLDER`: behind a path-prefixing gateway that strips the prefix, the web client derives it from the page URL.
- PipeWire with PulseAudio for pcmflux and a null sink `output` (default sink; Selkies streams `output.monitor`), upower, polkit rule for power-off/reboot/suspend,
  Firefox, fonts, and `webtop-app-screen` on the system path.
- `/etc/xdg` defaults, overridable per user: PowerDevil idle action "nothing", session restore
  "restore previous session".

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

A Selkies second-display page (`/#display2-<left|right|up|down>`) grows a KWin screen sized to the
page, named `SELKIES-<n>` (`SELKIES-2` for display2), and streams it; closing the page removes it.
Two patches make that work here: KWin announces per-output `kde_output_device_v2` globals again,
which pixelflux needs to confirm the screen (in the patched KWin, so it needs `kwinSoftwarePresentation`;
[ADR 0004](docs/adr/0004-patched-kwin-grafted-in-for-gpu-less-hosts.md)),
and Selkies lays out a second display while no primary page is connected
([patch](pkgs/selkies/second-display-without-primary.patch), [for upstream](docs/upstream/selkies-second-display-without-primary.md)).

To show one app on such a page, run as the desktop user inside the session:

```sh
webtop-app-screen place <app-id> <screen>   # e.g. place org.kde.dolphin SELKIES-2
webtop-app-screen release <app-id>
```

`place` loads a KWin script (`pkgs/app-screen/app-screen.js`) that moves every window of the app
(matched by Wayland app id, X11 class or desktop file name, with or without `.desktop`) and its
dialogs to the screen, makes normal windows fullscreen (maximized if they cannot be) and activates
them. It stays loaded: windows opened later are moved too, so none stays on the primary screen that
nobody may be watching, and if the screen goes and comes back (page reload) they return. `place`
can run before the app starts or the screen exists; running it again replaces the previous one.
`release` unloads it and leaves the windows where they are. Both need `DBUS_SESSION_BUS_ADDRESS`
and `XDG_RUNTIME_DIR`; exit status 2 is a usage error, 1 means KWin refused the script.

Starting the app is the caller's job. Only `display2` exists in Selkies' web client, so one app at a
time; audio plays on the primary page only.

## Tests

`nix build .#checks.<system>.module-eval` evaluates a system with the module (not with `--no-build`: the graft is import from derivation, so evaluating builds).
`nix flake check` needs a builder for every supported system: it evaluates each system's `module-eval`.
Evaluating the system realises the stock closure first (the graft), so the checks need several GB of disk.
`checks.<system>.vm` boots the module and needs KVM to run; it also asserts that KWin composites (the gray-screen check), the runtime-settings precedence, uploads into the XDG download directory (not the home) and downloads from the home.
`checks.<system>.second-display` opens a display2 page alone in headless Chromium and asserts the [one-app-per-screen](#one-app-per-screen) path: the screen appears and streams, input arrives at the page's coordinates, the app's windows (also later ones) land on it, and it goes away with the page. CI runs its driver outside the sandbox and uploads `summary.txt`, screenshots and logs as the `second-display` artifact.
CI builds the packages and `module-eval` natively on both systems (GitHub's arm runners for aarch64); the VM tests run on x86_64 only (no KVM on the arm runners).

Update nixpkgs here first (`nix flake update`); kube-webtop-workspaces then follows the same rev.

Licence: Apache-2.0 (this repo); the packaged software is MPL-2.0 (the pixelflux build also links GPL-2.0-or-later libx264 and x265, so the built extension is GPL-2.0-or-later).
