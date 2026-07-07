# Cross-build the full Bitcoin Core v31.0 aarch64-linux-gnu release (all 10
# binaries, incl. the Qt GUI) on an x86_64 machine, byte-for-byte identical
# to the upstream GUIX release. The aarch64 analog of x86_64-linux-gnu/release.nix; kept as a
# separate file because the cross build differs structurally (cross compiler
# via CC export, aarch64 ELF interpreter, cross binutils for split-debug,
# aarch64 frame-pointer handling, per-binary hashes).
{ gcc14Stdenv
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends # the aarch64 depends tree (Qt included)
, crossInputs # aarch64 cross cc/bintools (provides aarch64-linux-gnu-gcc/-objcopy/…)
, guixGcc # the unwrapped cross gcc (crossGuixGcc.cc) — for header prefix-maps
, linuxHeaders # kernel headers — gcc canonicalizes the sys-include symlinks to this store path
}:

let
  # Match GUIX's HOST_CFLAGS/HOST_CXXFLAGS: bare `-O2 -g` plus prefix maps,
  # exactly like x86_64-linux-gnu/release.nix (see its comment for the full map reasoning).
  # NO explicit frame-pointer flags: crossInputs is the NoFp wrapper
  # variant, so the aarch64 -O2 default applies (keep the non-leaf frame
  # pointer, omit the leaf one — what the previously explicit
  # -momit-leaf-frame-pointer reproduced against the wrapper injection),
  # and DW_AT_producer stays flag-free like upstream's.
  cflags = "-O2 -g"
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/aarch64-linux-gnu"
    + " -ffile-prefix-map=${guixGcc}/include/c++/14.3.0=/usr/include/c++"
    + " -ffile-prefix-map=${guixGcc}/aarch64-linux-gnu/sys-include=/usr/include"
    + " -ffile-prefix-map=${guixGcc}/lib/gcc=/usr/lib/gcc"
    + " -ffile-prefix-map=${linuxHeaders}/include=/usr/include"
    + " -fdebug-prefix-map=/build/bitcoin-${version}=/distsrc-base/distsrc-${version}-aarch64-linux-gnu"
    + " -fdebug-prefix-map=/build/bitcoin-${version}/src=.";
in
gcc14Stdenv.mkDerivation {
  pname = "bitcoind-aarch64";
  name = "bitcoind-aarch64";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  # Match GUIX's CONFIGFLAGS (contrib/guix/libexec/build.sh), same as the
  # x86_64-linux-gnu/release.nix: leave BUILD_TESTS at its default ON (builds
  # bitcoin-tx/-util/-wallet + test_bitcoin), skip bench/fuzz/gui-tests. The
  # depends toolchain.cmake auto-enables BUILD_GUI + WITH_QRENCODE because the
  # Qt depends are present, so bitcoin-qt / libexec/bitcoin-gui build too.
  cmakeBuildDir = "build";
  # GUIX doesn't pass a build type, so bitcoin's CMakeLists defaults to
  # RelWithDebInfo; nixpkgs' cmake hook would force Release. Visible in
  # DW_AT_producer (see x86_64-linux-gnu/release.nix); same effective codegen (-O2).
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
    # override the depends toolchain.cmake. Point CC/CXX at the aarch64
    # cross compiler so cmake cross-compiles (the native build stdenv would
    # otherwise leave CC=gcc → native x86_64).
    export CC=aarch64-linux-gnu-gcc
    export CXX=aarch64-linux-gnu-g++

    # Drop the -frandom-seed=<out-hash> appended by nixpkgs'
    # reproducible-builds hook — recorded in DW_AT_producer (see
    # bitcoind.nix).
    export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')

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
    # New nixos-26.05 cc-wrapper defaults GUIX doesn't apply (see x86_64-linux-gnu/release.nix):
    # strictflexarrays1 is codegen-affecting; libcxxhardeningfast is libc++-only.
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Mirror GUIX build.sh's split-debug + .comment handling (same as
  # x86_64-linux-gnu/release.nix). Use the CROSS binutils 2.41 (aarch64-linux-gnu-*
  # from crossInputs) — not nixpkgs' native one — so strip/objcopy behave
  # like upstream's.
  #
  # NOTE: the historical .gnu_debuglink CRC32 byte-patch is GONE
  # (2026-06-11, same day as x86_64's): the aarch64 .dbg files are now
  # byte-identical to upstream's (same recipe as x86_64 — see CLAUDE.md —
  # plus the aarch64-only --with-arch=armv8-a removal and the
  # kernel-header map for libgcc's unwind-dw2.c), so objcopy
  # --add-gnu-debuglink computes upstream's CRC naturally. postFixup
  # prints the per-file hashes for the log.
  postInstall = ''
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet bin/bitcoin-qt \
      libexec/bitcoin-node libexec/bitcoin-gui libexec/test_bitcoin; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
      aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
      aarch64-linux-gnu-strip --enable-deterministic-archives -p -s "$f"
      aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
      aarch64-linux-gnu-objcopy --update-section .comment=comment.bin "$f"
    done
  '';

  # Per-binary reference hashes are not published for v31.1 — upstream's
  # noncodesigned.SHA256SUMS covers only the assembled archives, which
  # tarball.nix gates against it. Print the per-file hashes for the log
  # (they localize a tarball-gate failure to the diverging binary); the
  # per-binary gate can be re-added once reference hashes exist (e.g.
  # captured from a matched release archive).
  postFixup = ''
    echo "BUILT (no per-binary upstream gate — archive gates in tarball.nix):"
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet bin/bitcoin-qt \
      libexec/bitcoin-node libexec/bitcoin-gui libexec/test_bitcoin; do
      for f in "$out/$rel" "$out/$rel.dbg"; do
        if [ ! -f "$f" ]; then echo "FAIL: ''${f#$out/} was not built"; exit 1; fi
        echo "  ''${f#$out/}  $(sha256sum "$f" | cut -d' ' -f1)"
      done
    done
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
