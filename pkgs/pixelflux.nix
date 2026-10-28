# Prebuilt manylinux_2_28 wheel (cp313); a source build can replace it later.
{ lib, buildPythonPackage, fetchPypi, autoPatchelfHook, pythonOlder, pythonAtLeast, stdenv
, libgbm, pixman, libxkbcommon, libGL, wayland, libx11, libxcb, libva, vulkan-loader
}:

buildPythonPackage rec {
  pname = "pixelflux";
  version = "2.2.1";
  format = "wheel";
  disabled = pythonOlder "3.13" || pythonAtLeast "3.14"; # cp313 wheel

  src = fetchPypi {
    inherit pname version format;
    dist = "cp313";
    python = "cp313";
    abi = "cp313";
    platform = "manylinux_2_28_x86_64";
    hash = "sha256-mQ4cTJ3lvq74atI0L4nYLCXzKoUr054v2qQqj9pa1dM=";
  };

  nativeBuildInputs = [ autoPatchelfHook ];
  # The extension's DT_NEEDED libraries.
  buildInputs = [ stdenv.cc.cc.lib libgbm pixman libxkbcommon ];

  # dlopen()ed at runtime (EGL, VA-API, Vulkan, wayland-server, X11), invisible to autoPatchelf.
  runtimeDependencies = [ libGL libva vulkan-loader wayland libx11 libxcb ];

  pythonImportsCheck = [ "pixelflux" ];

  meta = {
    description = "Pixel capture and encoding library for Selkies (Wayland compositor, X11 capture)";
    homepage = "https://github.com/selkies-project/pixelflux";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
