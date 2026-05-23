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

  # Bitcoin Core's libmultiprocess bakes the depends-build-time absolute
  # path into the `mpgen` binary via the `capnp_PREFIX` string-literal
  # macro (see src/ipc/libmultiprocess/include/mp/config.h.in). At depends
  # build time that path is /build/bitcoin-<ver>/depends/x86_64-pc-linux-gnu,
  # and mpgen then execs `<capnp_PREFIX>/bin/capnp` at codegen time during
  # the bitcoind build. Since our nix build sandbox places the source at
  # /build/bitcoin-<ver>, the same `depends/x86_64-pc-linux-gnu` path
  # exists relative to PWD; symlink it to the depends output so the
  # baked-in path resolves.
  preConfigure = ''
    mkdir -p depends
    ln -s ${depends} depends/x86_64-pc-linux-gnu
  '';

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
  # (debug) variants alongside the original binary. The script is rendered
  # from contrib/devtools/split-debug.sh.in into the cmake build dir by
  # setup_split_debug_script() in cmake/module/Maintenance.cmake.
  postInstall = ''
    ./split-debug.sh \
      $out/bin/bitcoind \
      $out/bin/bitcoind-s \
      $out/bin/bitcoind-d
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
