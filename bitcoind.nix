{
  gcc14Stdenv # GCC 14, ideally with glibc 2.31 wired in via default.nix
, fetchurl
# build-inputs
, pkg-config
, cmake
#
, version
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

  # Match GUIX's HOST_CFLAGS / HOST_CXXFLAGS from
  # contrib/guix/libexec/build.sh. GUIX builds bitcoin inside a chroot
  # rooted at /bitcoin and adds -ffile-prefix-map={store-path}=/usr for
  # every /gnu/store entry, plus -fdebug-prefix-map=${DISTSRC}/src=. to
  # strip the build directory.
  #
  # In our Nix sandbox bitcoin's source root is /build/bitcoin-${version}
  # and the depends live at ${depends} under /nix/store. The depends
  # symlink we set up in preConfigure also exposes them as
  # depends/x86_64-pc-linux-gnu/ relative to the source root. We map
  # both to match upstream's recorded paths:
  #
  #   - ${depends} -> /bitcoin/depends/x86_64-linux-gnu
  #     (so __FILE__ references in boost/etc. headers end up as
  #      /bitcoin/depends/x86_64-linux-gnu/boost/include/boost/...,
  #      matching the upstream binary)
  #   - /build/bitcoin-${version} -> /bitcoin
  #     (so any leak of the build dir maps to /bitcoin)
  # Path mappings to match upstream's recorded file paths.
  #
  # GCC applies -ffile-prefix-map maps in command-line order and the LAST
  # matching one wins, so the more specific src=. must come AFTER the
  # broader /build/...=/bitcoin fallback.
  #
  #   - boost headers: /nix/store/<hash>-bitcoin-31.0-depends/boost/include/...
  #     -> /bitcoin/depends/x86_64-linux-gnu/boost/include/... (matches upstream)
  #
  #   - bitcoin source: /build/bitcoin-31.0/src/<file>.cpp
  #     -> ./<file>.cpp (matches upstream's relative paths)
  #
  #   - any other build-dir path: /build/bitcoin-31.0/...
  #     -> /bitcoin/... (general fallback)
  env.CFLAGS = "-O2 -g -fcf-protection=full -ffile-prefix-map=${depends}=/bitcoin/depends/x86_64-linux-gnu -ffile-prefix-map=/build/bitcoin-${version}=/bitcoin -ffile-prefix-map=/build/bitcoin-${version}/src=.";
  env.CXXFLAGS = "-O2 -g -fcf-protection=full -ffile-prefix-map=${depends}=/bitcoin/depends/x86_64-linux-gnu -ffile-prefix-map=/build/bitcoin-${version}=/bitcoin -ffile-prefix-map=/build/bitcoin-${version}/src=.";

  # Tell nixpkgs' gcc-wrapper not to inject -rpath flags into the link line.
  # Upstream GUIX-built bitcoind has no RUNPATH; the binary uses the
  # standard /lib64/ld-linux-x86-64.so.2 interpreter to find libc / libm in
  # the system's standard library search paths. Without this, the wrapper
  # adds RUNPATH entries pointing at /nix/store/<glibc>/lib (where it
  # actually links against), which fixupPhase then can't remove because the
  # binary genuinely references those libraries — they're just findable via
  # the dynamic linker without RUNPATH.
  env.NIX_DONT_SET_RPATH = "1";
  env.NIX_NO_SELF_RPATH = "1";

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
