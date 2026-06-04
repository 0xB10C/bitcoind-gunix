# aarch64 cross-compile SPIKE (work in progress): cross-build bitcoind for
# aarch64-linux-gnu using the aarch64 depends tree, to measure how close we
# get to the upstream aarch64 release before investing in the GUIX-exact
# toolchain. Intentionally minimal — no split-debug, no .gnu_debuglink CRC
# patch, no reproducibility gate, no GUI (depends is NO_QT). Once the gap
# is understood this should fold into a parameterized bitcoind.nix.
{ gcc14Stdenv
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends # the aarch64 depends tree
, crossInputs # aarch64 cross cc/bintools (provides aarch64-linux-gnu-gcc)
}:

let
  cflags = "-O2 -g -fomit-frame-pointer -momit-leaf-frame-pointer"
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/aarch64-linux-gnu"
    + " -ffile-prefix-map=/build/bitcoin-${version}=/bitcoin"
    + " -ffile-prefix-map=/build/bitcoin-${version}/src=.";
in
gcc14Stdenv.mkDerivation {
  pname = "bitcoind-aarch64";
  name = "bitcoind-aarch64";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  cmakeBuildDir = "build";
  cmakeFlags = [
    "--toolchain=${depends}/toolchain.cmake"
    "-DBUILD_TESTS=OFF" # spike: just bitcoind, for speed
    "-DBUILD_BENCH=OFF"
    "-DBUILD_FUZZ_BINARY=OFF"
    "-DWITH_CCACHE=OFF"
    "-DREDUCE_EXPORTS=ON"
    "-DCMAKE_SKIP_RPATH=TRUE"
  ];

  preConfigure = ''
    # nixpkgs' cmake setup-hook passes -DCMAKE_C_COMPILER=$CC etc., which
    # override the depends toolchain.cmake. Point CC/CXX at the aarch64
    # cross compiler so cmake cross-compiles (the native build stdenv would
    # otherwise leave CC=gcc → native x86_64). AR/RANLIB/STRIP from the
    # native binutils are multi-target and handle aarch64 objects fine.
    export CC=aarch64-linux-gnu-gcc
    export CXX=aarch64-linux-gnu-g++

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/aarch64-linux-gnu.
    ln -s ${depends} depends/aarch64-linux-gnu

    # aarch64 ELF interpreter is /lib/ld-linux-aarch64.so.1 (vs the x86-64
    # /lib64/ld-linux-x86-64.so.2). Mirrors GUIX's HOST_LDFLAGS.
    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=/lib/ld-linux-aarch64.so.1 -Wl,-O2 -static-libstdc++ -static-libgcc"
    )
  '';

  env = {
    CFLAGS = cflags;
    CXXFLAGS = cflags;
    NIX_DONT_SET_RPATH = "1";
    NIX_NO_SELF_RPATH = "1";
  };

  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
  ];

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
