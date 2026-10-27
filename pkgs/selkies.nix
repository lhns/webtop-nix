# The wheel already bundles the built web client (selkies/selkies_web).
{ lib, buildPythonPackage, fetchPypi
, pixelflux, pcmflux
, prometheus-client, msgpack, psutil, watchdog, pillow, pulsectl-asyncio
, dnspython, cffi, cryptography, google-crc32c, pyee, pylibsrtp, pyopenssl
, aiohttp, aiofiles, uvloop, nvidia-ml-py
}:

buildPythonPackage rec {
  pname = "selkies";
  version = "2.1.0";
  format = "wheel";

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


  pythonImportsCheck = [ "selkies" ];

  meta = {
    description = "Low-latency remote desktop streaming to a browser (Selkies, websockets mode)";
    homepage = "https://github.com/selkies-project/selkies";
    license = lib.licenses.mpl20;
    mainProgram = "selkies";
    platforms = [ "x86_64-linux" ];
  };
}
