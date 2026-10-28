# webtop-nix

Nix packages and a NixOS module for a browser-streamed Plasma 6 desktop: [Selkies](https://github.com/selkies-project/selkies)
(with its pixelflux Wayland compositor/encoder and pcmflux audio) streams a KWin session to a web page.
Nothing here is site-specific; deployment wiring belongs in the consuming repo.

## Packages

`packages.x86_64-linux.{pixelflux,pcmflux,selkies}` and `overlays.default` (adds the same three
attributes, and the packages in `pythonPackagesExtensions`; the wheels are cp313, so only `python313Packages` builds).

| package | version | source |
| --- | --- | --- |
| pixelflux | 2.2.1 | PyPI cp313 manylinux_2_28 wheel, `autoPatchelfHook` |
| pcmflux | 2.2.0 | PyPI cp313 manylinux_2_28 wheel, `autoPatchelfHook` |
| selkies | 2.1.0 | PyPI wheel (bundles the built web client) |

Status: prebuilt wheels now; building pixelflux/pcmflux/selkies from source is planned.

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
`openFirewall`, `softwareRendering` (`true`: KWin QPainter and `LIBGL_ALWAYS_SOFTWARE`), `seat` (`""` in containers, else `seat0`),
`waylandSocketIndex` (`1`), `package`, `extraEnvironment` (extra `SELKIES_*` settings).

What the module sets up:

- Plasma 6, no display manager; the user is lingered so its manager starts at boot.
- `selkies.service` (user unit): pixelflux hosts a Wayland socket `wayland-<waylandSocketIndex>` (default `wayland-1`; stale sockets are removed at start); basic auth is off, so put
  an authenticating proxy in front.
- `webtop-session.service`: `startplasma-wayland` as the user (PAM `login`, `seat`), nested in that socket once its lock is held.
- PipeWire with PulseAudio for pcmflux and a null sink `output` (default sink; Selkies streams `output.monitor`), upower, polkit rule for power-off/reboot/suspend,
  Firefox, fonts.
- `/etc/xdg` defaults, overridable per user: PowerDevil idle action "nothing", session restore
  "restore previous session".

## Tests

`nix flake check --no-build` evaluates everything, including `checks.x86_64-linux.module-eval`.
`checks.x86_64-linux.vm` boots the module and needs KVM to run.

Licence: Apache-2.0 (this repo); the packaged software is MPL-2.0.
