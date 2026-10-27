# Prebuilt manylinux_2_28 wheel (cp313); it bundles libpulse, libFLAC etc. itself.
{ lib, buildPythonPackage, fetchPypi, autoPatchelfHook, stdenv
, libx11, libxext, libxcb, libice, libsm }:

buildPythonPackage rec {
  pname = "pcmflux";
  version = "2.2.0";
  format = "wheel";

  src = fetchPypi {
    inherit pname version format;
    dist = "cp313";
    python = "cp313";
    abi = "cp313";
    platform = "manylinux_2_28_x86_64";
    hash = "sha256-1lnwscfLyBhvfpnAtNv6yBcQ1BB6IKDJUlWvNM4vKoM=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [ stdenv.cc.cc.lib libx11 libxext libxcb libice libsm ];

  pythonImportsCheck = [ "pcmflux" ];

  meta = {
    description = "Audio capture and Opus encoding library for Selkies";
    homepage = "https://github.com/selkies-project/pcmflux";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
