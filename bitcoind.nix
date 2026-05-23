{
  gcc14Stdenv # The GUIX builds for Bitcoin Core v31.0 use GCC 14.2.0
, fetchurl
# build-inputs
, pkg-config
, cmake
#
, url
, sha256
, depends
}:

gcc14Stdenv.mkDerivation rec {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ];

  # Match the GUIX cmake invocation: build out-of-tree under ./build/ with
  # the depends-provided toolchain. Skip the GUI, tests, bench, and fuzz
  # binary; mirror the upstream-release flags (REDUCE_EXPORTS, SKIP_RPATH).
  cmakeBuildDir = "build";
  cmakeFlags = [
    "--toolchain=${depends}/toolchain.cmake"
    "-DBUILD_GUI=OFF"
    "-DBUILD_TESTS=OFF"
    "-DBUILD_BENCH=OFF"
    "-DBUILD_FUZZ_BINARY=OFF"
    "-DWITH_CCACHE=OFF"
    "-DREDUCE_EXPORTS=ON"
    "-DCMAKE_SKIP_RPATH=TRUE"
  ];

  # Match GUIX's -O2 -g (cmake otherwise uses RelWithDebInfo defaults from
  # the depends toolchain, which is fine — but enforce the same compile
  # flags to keep us reproducibility-adjacent).
  env.CFLAGS = "-O2 -g";
  env.CXXFLAGS = "-O2 -g";

  # GUIX runs split-debug.sh after install to produce -s (stripped) and -d
  # (debug) variants alongside the original binary.
  postInstall = ''
    ./contrib/devtools/split-debug.sh \
      $out/bin/bitcoind \
      $out/bin/bitcoind-s \
      $out/bin/bitcoind-d
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
