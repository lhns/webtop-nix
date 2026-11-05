# The wheel already bundles the built web client (selkies/selkies_web).
{ lib, buildPythonPackage, fetchPypi, pythonOlder, python
, pixelflux, pcmflux
, prometheus-client, msgpack, psutil, watchdog, pillow, pulsectl-asyncio
, dnspython, cffi, cryptography, google-crc32c, pyee, pylibsrtp, pyopenssl
, aiohttp, aiofiles, uvloop, nvidia-ml-py
}:

buildPythonPackage rec {
  pname = "selkies";
  version = "2.1.0";
  format = "wheel";
  disabled = pythonOlder "3.9"; # the wheel's requires-python

  src = fetchPypi {
    inherit pname version format;
    dist = "py3";
    python = "py3";
    abi = "none";
    platform = "any";
    hash = "sha256-i95iB8qSHLLzjDIE+v4Y1AtVeBZYlIGK4cqeRvynuWY=";
  };

  dependencies = [
    pixelflux pcmflux
    prometheus-client msgpack psutil watchdog pillow pulsectl-asyncio
    dnspython cffi cryptography google-crc32c pyee pylibsrtp pyopenssl
    aiohttp aiofiles uvloop nvidia-ml-py
  ];

  # A second display page can connect without the primary page (single-app streaming); for upstream.
  postInstall = ''
    patch -p2 -d $out/${python.sitePackages} < ${./selkies/second-display-without-primary.patch}
    # A separate upload directory (upload_path), so downloads can serve the whole home; for upstream.
    patch -p2 -d $out/${python.sitePackages} < ${./selkies/upload-path.patch}
    # The page opened last owns the primary display, the ones before stay beside it; for upstream.
    patch -p2 -d $out/${python.sitePackages} < ${./selkies/latest-owner.patch}
    # Several second displays at once, one per app screen.
    patch -p2 -d $out/${python.sitePackages} < ${./selkies/several-second-displays.patch}
    rm -f $out/${python.sitePackages}/selkies/__pycache__/{settings,stream_server,webrtc_mode}.*.pyc
    rm -f $out/${python.sitePackages}/selkies/__pycache__/websockets_mode.*.pyc
    css=$(echo $out/${python.sitePackages}/selkies/selkies_web/assets/index-*.css)
    [ -f "$css" ] || { echo "selkies: web client stylesheet not found" >&2; exit 1; }
    cat ${./selkies/touch-handle.css} >> "$css"
    # The web client says when it reconnects in place, which claims no display (latest-owner.patch).
    core=$(echo $out/${python.sitePackages}/selkies/selkies_web/assets/selkies-core-*.js)
    substituteInPlace "$core" --replace-fail 't.tabId=C()'       't.tabId=C(),t.reconnecting=window.__selkiesSettingsSent===!0,window.__selkiesSettingsSent=!0'
    # Touchpad mode is far too fast: cap its acceleration at 1.5x instead of 3x and allow slower speeds.
    substituteInPlace "$core" --replace-fail 'return 1+2*t*t*(3-2*t)}' 'return 1+.5*t*t*(3-2*t)}'       --replace-fail 'st=.25,ct=4' 'st=.1,ct=4'
    js=$(echo $out/${python.sitePackages}/selkies/selkies_web/assets/index-*.js)
    # Pages of any #displayN. The only display2 left is the sidebar's own button; a new wheel fails here.
    sed -E -i -f ${./selkies/display-n.sed} "$core" "$js"
    ! grep -q 'display2' "$core" || { echo "selkies: display2 left in the web client core" >&2; exit 1; }
    [ "$(grep -o 'display2' "$js" | wc -l)" = 1 ] || { echo "selkies: unexpected display2 in the web client" >&2; exit 1; }
    substituteInPlace "$js" --replace-fail '[.5,.75,1,1.5,2,3]' '[.1,.25,.5,.75,1,1.5,2,3]'
    # The bundler's file names no longer match the content, so browsers would keep the old files: rename by content hash.
    web=$out/${python.sitePackages}/selkies/selkies_web
    for f in "$css" "$core" "$js"; do
      old=$(basename "$f"); new="''${old%.*}-$(sha256sum "$f" | cut -c1-10).''${old##*.}"
      mv "$f" "$(dirname "$f")/$new"
      grep -rlF "$old" "$web" | xargs -r sed -i "s/$old/$new/g"
      grep -rqF "$new" "$web" || { echo "selkies: no reference to $old found" >&2; exit 1; }
      ! grep -rqF "$old" "$web" || { echo "selkies: $old still referenced" >&2; exit 1; }
    done
  '';

  pythonImportsCheck = [ "selkies" ];

  meta = {
    description = "Low-latency remote desktop streaming to a browser (Selkies, websockets mode)";
    homepage = "https://github.com/selkies-project/selkies";
    license = lib.licenses.mpl20;
    mainProgram = "selkies";
    platforms = lib.platforms.linux;
  };
}
