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
    rm -f $out/${python.sitePackages}/selkies/__pycache__/{settings,stream_server,webrtc_mode}.*.pyc
    rm -f $out/${python.sitePackages}/selkies/__pycache__/websockets_mode.*.pyc
    css=$(echo $out/${python.sitePackages}/selkies/selkies_web/assets/index-*.css)
    [ -f "$css" ] || { echo "selkies: web client stylesheet not found" >&2; exit 1; }
    cat ${./selkies/touch-handle.css} >> "$css"
    # The web client says when it reconnects in place, which claims no display (latest-owner.patch).
    core=$(echo $out/${python.sitePackages}/selkies/selkies_web/assets/selkies-core-*.js)
    substituteInPlace "$core" --replace-fail 't.tabId=C()'       't.tabId=C(),t.reconnecting=window.__selkiesSettingsSent===!0,window.__selkiesSettingsSent=!0'
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
