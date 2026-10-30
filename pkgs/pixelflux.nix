# Built with the GPL flavor (libx264 and x265 as the software H.264/H.265 encoders), like the PyPI wheels.
{ lib, buildPythonPackage, fetchFromGitHub, rustPlatform, setuptools, setuptools-rust, patchelf
, pkg-config, cmake, nasm, python
, libgbm, pixman, libxkbcommon, libdrm, libinput, systemdLibs, wayland, libx11, libxcb, libxext, libxfixes
, libGL, libva, vulkan-loader
, x264, x265, libvpx, svt-av1, dav1d, libde265
}:

buildPythonPackage (finalAttrs: {
  pname = "pixelflux";
  version = "2.2.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "selkies-project";
    repo = "pixelflux";
    # The commit that released the version on PyPI.
    rev = "67b6d833fc8eba87f9b15fb4cb3382d923a2fe56";
    hash = "sha256-NusvXgm2HMvsQbNnV5mLOxwWRH9WHMNv3DnyAGjYo2c=";
  };

  # The crate sits in a subdirectory; setup.py reads its Cargo.toml.
  cargoRoot = "pixelflux";
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src cargoRoot;
    hash = lib.fakeHash;
  };

  build-system = [ setuptools setuptools-rust ];

  nativeBuildInputs = [
    rustPlatform.cargoSetupHook rustPlatform.rust.cargo rustPlatform.rust.rustc
    rustPlatform.bindgenHook pkg-config cmake nasm patchelf
  ];
  # turbojpeg-sys builds its vendored libjpeg-turbo with cmake.
  dontUseCmakeConfigure = true;

  buildInputs = [
    libgbm pixman libxkbcommon libdrm libinput systemdLibs wayland libx11 libxcb libxext libxfixes
    x264 x265 libvpx svt-av1 dav1d libde265
  ];

  # dlopen()ed at runtime (EGL, VA-API, Vulkan, wayland-server, X11): found through the extension's RUNPATH.
  postFixup = ''
    for so in $out/${python.sitePackages}/pixelflux*.so; do
      patchelf --add-rpath ${lib.makeLibraryPath [ libGL libva vulkan-loader wayland libx11 libxcb ]} "$so"
    done
  '';

  pythonImportsCheck = [ "pixelflux" ];

  meta = {
    description = "Pixel capture and encoding library for Selkies (Wayland compositor, X11 capture)";
    homepage = "https://github.com/selkies-project/pixelflux";
    # MPL-2.0 sources; the GPL flavor links libx264 and x265, so the built extension is GPL-2.0-or-later.
    license = with lib.licenses; [ mpl20 gpl2Plus ];
    platforms = [ "x86_64-linux" ];
  };
})
