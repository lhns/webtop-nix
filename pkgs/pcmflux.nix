{ lib, buildPythonPackage, fetchFromGitHub, rustPlatform, setuptools, setuptools-rust
, pkg-config, cmake, libpulseaudio }:

buildPythonPackage (finalAttrs: {
  pname = "pcmflux";
  version = "2.2.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "selkies-project";
    repo = "pcmflux";
    # The commit that released the version on PyPI.
    rev = "c5070c8e0a2fc34e2024a0a091901c6e49847201";
    hash = lib.fakeHash;
  };

  # The crate sits in a subdirectory; setup.py reads its Cargo.toml.
  cargoRoot = "pcmflux";
  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) pname version src cargoRoot;
    hash = lib.fakeHash;
  };

  build-system = [ setuptools setuptools-rust ];

  nativeBuildInputs = [ rustPlatform.cargoSetupHook rustPlatform.rust.cargo rustPlatform.rust.rustc pkg-config cmake ];
  # opusic-sys builds its vendored libopus with cmake.
  dontUseCmakeConfigure = true;
  buildInputs = [ libpulseaudio ];

  pythonImportsCheck = [ "pcmflux" ];

  meta = {
    description = "Audio capture and Opus encoding library for Selkies";
    homepage = "https://github.com/selkies-project/pcmflux";
    license = lib.licenses.mpl20;
    platforms = [ "x86_64-linux" ];
  };
})
