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

  # preConfigure does two things:
  #
  # 1. Symlink the depends output into ./depends/x86_64-pc-linux-gnu so the
  #    absolute path baked into mpgen via the `capnp_PREFIX` macro resolves.
  #    libmultiprocess's mpgen execs `<capnp_PREFIX>/bin/capnp` at codegen
  #    time, where capnp_PREFIX is the depends-build-time absolute path
  #    (/build/bitcoin-<ver>/depends/x86_64-pc-linux-gnu, baked in via
  #    src/ipc/libmultiprocess/include/mp/config.h.in). The Nix sandbox
  #    places our source at /build/bitcoin-<ver>, so this symlink makes
  #    that path resolve through to ${depends}.
  #
  # 2. Append -DCMAKE_EXE_LINKER_FLAGS via cmakeFlagsArray (rather than
  #    cmakeFlags) so the space-separated linker-flag value survives the
  #    nixpkgs cmake hook's word splitting. Mirror GUIX's full
  #    HOST_LDFLAGS + static-libstdc++/libgcc — see
  #    contrib/guix/libexec/build.sh:
  #
  #      HOST_LDFLAGS="-Wl,--as-needed
  #                    -Wl,--dynamic-linker=$glibc_dynamic_linker
  #                    -Wl,-O2"
  #      CMAKE_EXE_LINKER_FLAGS="${HOST_LDFLAGS} -static-libstdc++ -static-libgcc"
  #
  #    The dynamic-linker path (`/lib64/ld-linux-x86-64.so.2`) makes the
  #    resulting binary use the standard FHS interpreter rather than
  #    Nix's glibc store path, matching upstream. The binary then won't
  #    run on NixOS without nix-ld/buildFHSEnv, which is fine — the goal
  #    is byte-for-byte parity with the GUIX release.
  preConfigure = ''
    mkdir -p depends
    ln -s ${depends} depends/x86_64-pc-linux-gnu

    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 -Wl,-O2 -static-libstdc++ -static-libgcc"
    )
  '';

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
