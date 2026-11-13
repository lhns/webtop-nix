# Built from source: the Python package and its web client, which the wheel ships pre-built.
{ lib, buildPythonPackage, fetchFromGitHub, fetchurl, applyPatches, buildNpmPackage, nodejs, pythonOlder
, setuptools
, pixelflux, pcmflux
, prometheus-client, msgpack, psutil, watchdog, pillow, pulsectl-asyncio
, dnspython, cffi, cryptography, google-crc32c, pyee, pylibsrtp, pyopenssl
, aiohttp, aiofiles, uvloop, nvidia-ml-py
}:

let
  version = "2.1.0";

  src = applyPatches {
    name = "selkies-${version}-src";
    src = fetchFromGitHub {
      owner = "selkies-project";
      repo = "selkies";
      # The commit that released the version on PyPI.
      rev = "6ee68a7a815956e6745e916741f13335e0b3ff53";
      hash = "sha256-XZ+pi+r2Avck1RnAPQCmPIkYBYse+sVjI1/lfCwgkAs=";
    };
    patches = [
      # A second display page can connect without the primary page (single-app streaming); for upstream.
      ./selkies/second-display-without-primary.patch
      # A separate upload directory (upload_path), so downloads can serve the whole home; for upstream.
      ./selkies/upload-path.patch
      # The page opened last owns the primary display, the ones before stay beside it; for upstream.
      ./selkies/latest-owner.patch
      # Several second displays at once, one per app screen, and pages of any #displayN.
      ./selkies/several-second-displays.patch
      # Touchpad mode is far too fast: acceleration capped at 1.5x instead of 3x, slower speeds allowed.
      ./selkies/touchpad-speed.patch
      # Special-key bar for touch screens and the touch sidebar styles, bundled with the client.
      ./selkies/key-bar.patch
      ./selkies/gamecontrollerdb-file.patch
    ];
    postPatch = ''
      mkdir addons/selkies-dashboard/src/webtop
      cp ${./selkies/key-bar.js} addons/selkies-dashboard/src/webtop/key-bar.js
      cp ${./selkies/key-bar.css} addons/selkies-dashboard/src/webtop/key-bar.css
      cp ${./selkies/touch-handle.css} addons/selkies-dashboard/src/webtop/touch-handle.css
    '';
  };

  # The database upstream's build fetched when it built the 2.1.0 wheel (its jsdb/ is identical).
  gamecontrollerdb = fetchurl {
    url = "https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/ff333823a85ae896e73f4c53670932cf0f728adb/gamecontrollerdb.txt";
    hash = "sha256-xlh8xleJU55h7DdarVvbwU+XRQi1firodzCsdcREXbo=";
  };

  # The streaming core, with the gamepad database and the WASM Opus codec beside it.
  web-core = buildNpmPackage {
    pname = "selkies-web-core";
    inherit version src;
    sourceRoot = "${src.name}/addons/selkies-web-core";
    npmDepsHash = "sha256-f9kHTDjHJpKcaS3bwrJ8Wg23zwwOXlSgIFBm3YCENyE=";
    env.SELKIES_GAMECONTROLLERDB = gamecontrollerdb;
    # Upstream's touch gesture checks, the touchpad speed among them.
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      node ../../tests/tools/touch_gesture_audit.mjs
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      [ -n "$(ls dist/jsdb/linux)" ] || { echo "selkies: no gamepad database built" >&2; exit 1; }
      cp -r dist $out
      runHook postInstall
    '';
  };

  # The classic dashboard with the core. The wheel does not ship the Wish dashboard, so it is not built.
  web = buildNpmPackage {
    pname = "selkies-web";
    inherit version src;
    sourceRoot = "${src.name}/addons/selkies-dashboard";
    npmDepsHash = "sha256-x1/mxivJ5gMDbVJeadxEYa9bHnmPNmLW+kOIiGAEM9g=";
    env.SELKIES_INJECT = "1";
    # Only sourceRoot is made writable.
    preBuild = ''
      chmod u+w ../selkies-web-core ../../src/selkies
      cp -r --no-preserve=mode ${web-core} ../selkies-web-core/dist
    '';
    # Upstream's own assembly into selkies_web: scripts/ci/build-web.sh from the step after the builds.
    installPhase = ''
      runHook preInstall
      cd ../..
      sed -n '/^mkdir -p addons\/selkies-dashboard\/dist\/src$/,$p' scripts/ci/build-web.sh > $TMPDIR/assemble.sh
      [ -s $TMPDIR/assemble.sh ] || { echo "selkies: build-web.sh has no assembly step" >&2; exit 1; }
      sh -eux $TMPDIR/assemble.sh
      cp -r src/selkies/selkies_web $out
      cd addons/selkies-dashboard
      runHook postInstall
    '';
    # key-bar.js drives these webrtcInput methods; several-second-displays.patch must leave no #display2
    # but the sidebar's own button. Both fail on an upstream change the patches still apply over.
    doInstallCheck = true;
    installCheckPhase = ''
      for m in _sendKeyEvent _releaseLostKey resetKeyboard _chordModifierHeld _startKeyHeartbeat; do
        grep -q "^ *$m(" ../selkies-web-core/lib/input.js || { echo "selkies: web client has no $m, key-bar.js needs it" >&2; exit 1; }
      done
      ! grep -q display2 $out/assets/selkies-core-*.js || { echo "selkies: display2 left in the web client core" >&2; exit 1; }
      [ "$(cat $out/assets/index-*.js | grep -o display2 | wc -l)" = 1 ] || { echo "selkies: unexpected display2 in the web client" >&2; exit 1; }
    '';
  };
in
buildPythonPackage {
  pname = "selkies";
  inherit version src;
  pyproject = true;
  disabled = pythonOlder "3.9"; # requires-python

  postPatch = ''
    substituteInPlace pyproject.toml --replace-fail 'version = "0.0.0.dev0"' 'version = "${version}"'
    cp -r --no-preserve=mode ${web} src/selkies/selkies_web
  '';

  build-system = [ setuptools ];

  dependencies = [
    pixelflux pcmflux
    prometheus-client msgpack psutil watchdog pillow pulsectl-asyncio
    dnspython cffi cryptography google-crc32c pyee pylibsrtp pyopenssl
    aiohttp aiofiles uvloop nvidia-ml-py
  ];

  # The web client's build toolchain stays out of the runtime closure.
  disallowedReferences = [ nodejs ];

  pythonImportsCheck = [ "selkies" ];

  passthru = { inherit src web; };

  meta = {
    description = "Low-latency remote desktop streaming to a browser (Selkies, websockets mode)";
    homepage = "https://github.com/selkies-project/selkies";
    license = lib.licenses.mpl20;
    mainProgram = "selkies";
    platforms = lib.platforms.linux;
  };
}
