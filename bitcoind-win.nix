# Cross-build the full Bitcoin Core v31.0 win64 (x86_64-w64-mingw32) release
# — the 8 PE binaries (bitcoin{,-cli,-tx,-util,-wallet,-qt,d}.exe +
# libexec/test_bitcoin.exe; NO bitcoin-node/-gui, ENABLE_IPC is OFF for WIN32)
# — byte-for-byte identical to the upstream GUIX release. Mirrors
# bitcoind-cross.nix; the mingw-specific deltas are noted inline. See
# bitcoind.nix / bitcoind-cross.nix for the full reasoning behind each flag.
{ lib
, gcc14Stdenv
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends          # the win64 depends tree (Qt included)
, crossInputs      # NoFp cross cc/bintools (x86_64-w64-mingw32-gcc/-objcopy/…)
, guixGcc          # the unwrapped cross gcc — for header prefix-maps → /usr
, mingwCrt         # the mingw-w64 CRT (msvcrt) store path — prefix-mapped → /usr
, mingwPthreads    # the winpthreads store path — prefix-mapped → /usr
, hostTriple       # "x86_64-w64-mingw32"
, expectedHashes   # rel path -> upstream sha256 (8 binaries + 8 .dbg)
, pname
}:

let
  # GUIX builds win64 at DISTSRC=/distsrc-base/distsrc-31.0-x86_64-w64-mingw32
  # (guix-build distsrc_for_host). We build at /build/bitcoin-<ver> (the Nix
  # default) and rewrite to that DISTSRC for the recorded debug paths, exactly
  # like the linux cross targets.
  distsrc = "/distsrc-base/distsrc-${version}-${hostTriple}";

  # build.sh's HOST_CFLAGS for mingw: `-O2 -g -fno-ident`, then a
  # -ffile-prefix-map={}=/usr for EVERY /gnu/store dir (the toolchain — gcc,
  # CRT — lands at /usr), then -fdebug-prefix-map=${DISTSRC}/src=.  GUIX's
  # depends live at the real /bitcoin/depends/<host> (NOT in /gnu/store, so
  # the /usr map never touches them); we map our depends store path there.
  # No frame-pointer flag (crossInputs is the NoFp wrapper → bare -O2, x86_64
  # omits the FP by default like upstream).
  # The depends→/bitcoin rewrite goes through the gcc canon env var
  # (NIX_DEBUG_CANON_PREFIX_MAP below), NOT a -ffile-prefix-map — the latter's
  # per-header ggc_alloc shifts var-tracking's loclist representative choice in
  # the biggest CUs (−44 B .debug_loclists on bitcoind/-qt/test_bitcoin). Same
  # canonDepends mechanism as the armhf/ppc64 linux targets.
  cflags = "-O2 -g -fno-ident"
    # Toolchain headers → GUIX's /usr layout (its /gnu/store→/usr maps): the
    # libstdc++ headers map VERSION-LESS (gcc's --with-gxx-include-dir), the
    # mingw CRT headers (copied into sys-include) → /usr/include, gcc builtins
    # → /usr/lib/gcc. Same scheme as bitcoind-cross.nix.
    + " -ffile-prefix-map=${guixGcc}/include/c++/14.3.0=/usr/include/c++"
    + " -ffile-prefix-map=${guixGcc}/${hostTriple}/sys-include=/usr/include"
    + " -ffile-prefix-map=${guixGcc}/lib/gcc=/usr/lib/gcc"
    # The CRT/winpthreads headers reach the bitcoin compile via the final gcc's
    # --with-native-system-header-dir = mingwLibc/include (a symlinkJoin); gcc
    # realpaths each header through the join to its REAL component output, so it
    # records ${mingwCrt.dev}/include and ${mingwPthreads}/include — NOT the
    # ${guixGcc}/sys-include the map above expects. Map the components too → /usr.
    + " -ffile-prefix-map=${mingwCrt.dev}/include=/usr/include"
    + " -ffile-prefix-map=${mingwPthreads}/include=/usr/include"
    + " -fdebug-prefix-map=/build/bitcoin-${version}=${distsrc}"
    + " -fdebug-prefix-map=/build/bitcoin-${version}/src=.";

  binaries = [
    "bin/bitcoin.exe" "bin/bitcoin-cli.exe" "bin/bitcoind.exe"
    "bin/bitcoin-tx.exe" "bin/bitcoin-util.exe" "bin/bitcoin-wallet.exe"
    "bin/bitcoin-qt.exe" "libexec/test_bitcoin.exe"
  ];
in
gcc14Stdenv.mkDerivation {
  inherit pname;
  name = pname;
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  cmakeBuildDir = "build";
  cmakeBuildType = "RelWithDebInfo";
  cmakeFlags = [
    "--toolchain=${depends}/toolchain.cmake"
    "-DBUILD_GUI_TESTS=OFF"
    "-DBUILD_BENCH=OFF"
    "-DBUILD_FUZZ_BINARY=OFF"
    "-DWITH_CCACHE=OFF"
    "-DREDUCE_EXPORTS=ON"
    "-DCMAKE_SKIP_RPATH=TRUE"
  ];

  preConfigure = ''
    # nixpkgs' cmake setup-hook passes -DCMAKE_C_COMPILER=$CC etc., which
    # override the depends toolchain.cmake. Point CC/CXX at the cross
    # compiler so cmake cross-compiles for mingw.
    export CC=${hostTriple}-gcc
    export CXX=${hostTriple}-g++

    # Drop nixpkgs' reproducible-builds -frandom-seed=<out-hash> (recorded in
    # DW_AT_producer).
    export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/${hostTriple}.
    ln -s ${depends} depends/${hostTriple}
  '';

  env = {
    CFLAGS = cflags;
    CXXFLAGS = cflags;
    # depends store path → GUIX's /bitcoin/depends/<host>, via the gcc canon
    # mechanism (malloc'd rewrite, GGC-neutral; also hooks the macro map so
    # depends __FILE__ strings still rewrite). gcc-debug-canon-prefix-map.patch
    # is applied to mingwGuixGcc.
    NIX_DEBUG_CANON_PREFIX_MAP = "${depends}=/bitcoin/depends/${hostTriple}";
    # build.sh mingw HOST_LDFLAGS (CMake reads LDFLAGS to seed the linker
    # flags). bitcoin's own CMakeLists adds -static / the subsystem-version
    # flags for MINGW, so build.sh sets no CMAKE_EXE_LINKER_FLAGS here.
    LDFLAGS = "-Wl,--no-insert-timestamp";
    NIX_DONT_SET_RPATH = "1";
    NIX_NO_SELF_RPATH = "1";
  };

  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Mirror GUIX build.sh's split-debug (contrib/devtools/split-debug.sh) with
  # the CROSS binutils 2.41 (<hostTriple>-* from crossInputs). No .comment
  # rewrite: -fno-ident already drops the ident, and PE/COFF has no .comment
  # section. All .dbg are gated byte-identical below, so --add-gnu-debuglink
  # computes upstream's CRC naturally — no byte patches.
  postInstall = ''
    for rel in ${toString binaries}; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      ${hostTriple}-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
      ${hostTriple}-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
      ${hostTriple}-strip --enable-deterministic-archives -p -s "$f"
      ${hostTriple}-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
    done
  '';

  postFixup = ''
    declare -A expected=(
${lib.concatStringsSep "\n" (lib.mapAttrsToList (rel: h: "      [${rel}]=${h}") expectedHashes)}
    )
    fail=0
    for rel in "''${!expected[@]}"; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "FAIL: $rel was not built"; fail=1; continue; fi
      actual=$(sha256sum "$f" | cut -d' ' -f1)
      if [ "$actual" = "''${expected[$rel]}" ]; then
        echo "OK:   $rel matches upstream"
      else
        echo "FAIL: $rel  expected ''${expected[$rel]}  actual $actual"
        fail=1
      fi
    done
    [ "$fail" = "0" ] || { echo "FAIL: one or more ${hostTriple} binaries/.dbg diverged from upstream GUIX v31.0"; exit 1; }
    echo "OK: all ${toString (builtins.length (builtins.attrNames expectedHashes))} asserted ${hostTriple} artifacts match upstream GUIX v31.0"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
