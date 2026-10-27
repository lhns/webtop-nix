# Prebuilt manylinux_2_28 wheel (cp313); a source build can replace it later.
{ lib, buildPythonPackage, fetchPypi, autoPatchelfHook, stdenv
, libgbm, libdrm, pixman, libxkbcommon, libGL, wayland, libx11, libxcb, libxext
, libxfixes, libxrandr, libxcursor, libxtst, libva, libinput, systemdLibs, seatd
, libpulseaudio, libxshmfence, pipewire, vulkan-loader
}:

buildPythonPackage rec {
  pname = "pixelflux";
  version = "2.2.1";
  format = "wheel";

  src = fetchPypi {
    inherit pname version format;
    dist = "cp313";
    python = "cp313";
    abi = "cp313";
    platform = "manylinux_2_28_x86_64";
    hash = "sha256-mQ4cTJ3lvq74atI0L4nYLCXzKoUr054v2qQqj9pa1dM=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    stdenv.cc.cc.lib libgbm libdrm pixman libxkbcommon libGL wayland libx11 libxcb
    libxext libxfixes libxrandr libxcursor libxtst libva libinput systemdLibs seatd
    libpulseaudio libxshmfence
  ];

  # dlopen()ed at runtime (EGL/GBM/VA-API/PipeWire/Vulkan), invisible to autoPatchelf.
  runtimeDependencies = [
    libGL libgbm libva pipewire vulkan-loader wayland libx11 libxkbcommon pixman libxcb
  ];

  pythonImportsCheck = [ "pixelflux" ];

  meta = {
    description = "Pixel capture and encoding library for Selkies (Wayland compositor, X11 capture)";
    homepage = "https://github.com/selkies-project/pixelflux";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
