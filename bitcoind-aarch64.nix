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
  # aarch64 frame pointers: upstream uses bare -O2, which on aarch64 KEEPS
  # the non-leaf frame pointer but OMITS the leaf one. nixpkgs' cross
  # cc-wrapper forces `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer`
  # (keep both). So we override only the leaf one back to omit — letting the
  # wrapper's -fno-omit-frame-pointer keep the non-leaf FP, matching upstream.
  # (On x86_64 the -O2 default omits both, hence bitcoind.nix uses
  # -fomit-frame-pointer there; here we must NOT, or every non-leaf function
  # loses its frame setup and the binary shrinks ~66 KB below upstream.)
  cflags = "-O2 -g -momit-leaf-frame-pointer"
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

  # Mirror GUIX build.sh's split-debug + .gnu_debuglink handling (same as
  # x86_64 bitcoind.nix). Use the CROSS binutils 2.41 (aarch64-linux-gnu-*
  # from crossInputs) — not nixpkgs' native 2.44 — so strip/objcopy behave
  # like upstream's. The .gnu_debuglink CRC is CRC32 of our bitcoind.dbg,
  # which isn't byte-reproducible (DWARF path/triple divergence, see
  # CLAUDE.md Task #2), so we overwrite it with upstream's value.
  postInstall = ''
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    f="$out/bin/bitcoind"
    aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
    aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
    aarch64-linux-gnu-strip --enable-deterministic-archives -p -s "$f"
    aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
    aarch64-linux-gnu-objcopy --update-section .comment=comment.bin "$f"

    # Overwrite the 4-byte CRC at the end of .gnu_debuglink with upstream's
    # (0xe8e5e289 → little-endian 89 e2 e5 e8).
    read -r doff dsize < <(aarch64-linux-gnu-readelf -SW "$f" | sed 's/\[[ 0-9]*\]//' \
      | awk '/\.gnu_debuglink/{print strtonum("0x"$4), strtonum("0x"$5)}')
    printf '\x89\xe2\xe5\xe8' | dd of="$f" bs=1 seek=$((doff + dsize - 4)) count=4 conv=notrunc status=none
  '';

  # Reproducibility gate: assert the cross-built aarch64 bitcoind byte-matches
  # the upstream GUIX v31.0 release (bitcoin-31.0-aarch64-linux-gnu.tar.gz).
  postFixup = ''
    expected=6f66822a44b4d4edd2a8ae1a11f63dd4db8d070e219c8eb54a3e2faa536409c2
    actual=$(sha256sum "$out/bin/bitcoind" | cut -d' ' -f1)
    if [ "$actual" = "$expected" ]; then
      echo "OK: bitcoind-aarch64 matches upstream GUIX v31.0 ($expected)"
    else
      echo "FAIL: bitcoind-aarch64 expected $expected actual $actual"
      exit 1
    fi
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
