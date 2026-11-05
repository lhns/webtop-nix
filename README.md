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
| selkies | 2.1.0 | PyPI wheel (bundles the built web client), with three patches: [second display](pkgs/selkies/second-display-without-primary.patch), [upload path](pkgs/selkies/upload-path.patch), [latest page owns the display](pkgs/selkies/latest-owner.patch) |
| Nix | 2.34 | built from source for `nixProfile`, with [`nix profile` backends](modules/nix-profile/nix/profile-backends.patch) and [cacheable `path:` inputs](modules/nix-profile/nix/path-input-fingerprint.patch) |
| webtop-app-screen | — | this repo: keeps an app's windows on one screen ([below](#one-app-per-screen)) |

Web client edits made in `postInstall` ([selkies.nix](pkgs/selkies.nix)): a larger left padding for the sidebar and a handle at the
same edge on touch screens ([touch-handle.css](pkgs/selkies/touch-handle.css)); touchpad mode accelerates by at most 1.5x instead of 3x
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
`openFirewall`, `softwareCenter.enable` (`false`; the standalone image sets it), `softwareRendering` (`true`: `LIBGL_ALWAYS_SOFTWARE`), `kwinSoftwarePresentation` (`true`: patched KWin, see below), `seat` (`""` in containers, else `seat0`),
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
- `selkies.service` (user unit): pixelflux hosts a Wayland socket `wayland-<waylandSocketIndex>` (default `wayland-1`; stale sockets are removed at start).
- `webtop-session.service`: `startplasma-wayland` as the user (PAM `login`, `seat`), nested in that socket once its lock is held.
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
gives the user one declaration, `~/.config/home-manager/packages.json`: `nix profile add|remove|upgrade|rollback` edit it and run `home-manager switch` (a patched Nix, built from source). Commands can run at the same time, in any mix: each builds unlocked, then applies its own change to the current state under a lock ([ADR 0007](docs/adr/0007-nix-profile-commit-locks.md)).
On first boot a starter flake appears in `~/.config/home-manager`; its `nixpkgs`, `home-manager` and `webtop` inputs resolve from the image's registry. The registry also has `nixpkgs-unfree` (the image's nixpkgs with unfree allowed): `nix profile add nixpkgs-unfree#pkg` installs an unfree package and records it in `packages.json`, with no `--impure`. Your own module goes in `local.nix` beside it, which the image never writes (in a git repo, `git add` it).
While unmodified, the starter follows the image's template. An edited one is left alone with a notification: `webtop-home-manager-update` shows the difference and `--apply` takes the template, keeping backups.
A home kept across containers survives a new image: each boot (`nixProfile.fromImageStore`, on by default) moves dangling generations aside and switches, so what `packages.json` declares comes back (needs network); packages added to the profile directly do not. A consumer with its own restore sets it to `false` and runs `nixProfile.reinstall` after that.
A consumer whose home is reached through other paths sets `nixProfile.homeStoragePath`, and can receive progress with `nixProfile.progress`.

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

## Tests

`nix build .#checks.<system>.module-eval` evaluates a system with the module (not with `--no-build`: the graft is import from derivation, so evaluating builds).
`nix flake check` needs a builder for every supported system: it evaluates each system's `module-eval`.
Evaluating the system realises the stock closure first (the graft), so the checks need several GB of disk.
`checks.<system>.vm` boots the module and needs KVM to run; it also asserts that KWin composites (the gray-screen check), the runtime-settings precedence, uploads into the XDG download directory (not the home) and downloads from the home.
`checks.<system>.second-display` opens a display2 page alone in headless Chromium and asserts the [one-app-per-screen](#one-app-per-screen) path: the screen appears and streams, input arrives at the page's coordinates, the app's windows (also later ones) land on it, and it goes away with the page. CI runs its driver outside the sandbox and uploads `summary.txt`, screenshots and logs as the `second-display` artifact.
CI builds the packages and `module-eval` natively on both systems (GitHub's arm runners for aarch64); the VM tests run on x86_64 only (no KVM on the arm runners).

Update nixpkgs here first (`nix flake update nixpkgs`); kube-webtop-workspaces follows this flake's nixpkgs.
`tests/nix-profile-template-test.sh` and `tests/nix-profile-reinstall-test.sh` run the starter's template upgrade and the reinstall without Nix; `tests/nixpkgs-unfree-test.sh` checks `nixpkgs-unfree` on real Nix.
`tests/nix-profile-concurrency.sh` runs concurrent `nix profile` commands with the patched Nix and home-manager, on a temporary home.
CI also builds the image on both systems, boots it under docker (Selkies page, KWin compositing, Nix DB = store, `nix profile` into the declaration, `local.nix`) and prints its layer table; on `main` it pushes the image and the multi-arch index, signed with cosign.

Licence: Apache-2.0 (this repo); the packaged software is MPL-2.0 (the pixelflux build also links GPL-2.0-or-later libx264 and x265, so the built extension is GPL-2.0-or-later).
