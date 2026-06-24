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
  # --add-gnu-debuglink computes upstream's CRC naturally. The postFixup
  # gate asserts the .dbg hashes too.
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

  # Reproducibility gate: assert every shipped binary AND every .dbg debug
  # file byte-matches the upstream GUIX v31.1rc1 aarch64-linux-gnu release.
  postFixup = ''
    declare -A expected=(
      [bin/bitcoin]=347ca9d7291dccb728f5f5ae79228106c8d97b63237f6bf928aa4e35add33079
      [bin/bitcoin-cli]=93eed022dba9e1c2de1630931d2a3ed61d6476ef72dc4a3840833832cb5eb3f3
      [bin/bitcoind]=7df45d8bf3b013ec0b7a9c617f2007ad33fb220449e03e69ffcfccc1943b5116
      [bin/bitcoin-tx]=fd1844e290149ae3c7dadf3ef8afbf3a95ca4f08554716c73ce6c07eb34fea56
      [bin/bitcoin-util]=37ae6248570deb0f838ff391d1339757dc455fdd88cda45b1eb52bdf7dd81f48
      [bin/bitcoin-wallet]=d6f2bfcf96716de133a24bff46555fcbf37257dd56a9f87a1ee45499f09745c7
      [bin/bitcoin-qt]=d0b5b571ee4f9817eb1d61e3eaa2247c8c4c92d40944b53bee22d71446778d2c
      [libexec/bitcoin-node]=e20aab227423625a498316d929ced4ec8fb68afdcf3953823da574fe69463ed9
      [libexec/bitcoin-gui]=937b9128a6a61c30b0791fb750fa88be340bc573317ba356530a508306573550
      [libexec/test_bitcoin]=e6489ead290b4dc6eb07a6f7365659341ca460208c5da2c58ecf835bef41065b
      [bin/bitcoin.dbg]=4b3110e489bf59f259c34c45d992d13d703c5676fb4b2c2ac23196ec764910c8
      [bin/bitcoin-cli.dbg]=f6a2abff38c27d27a1d24792d6263a3bb823a4616e1f5feee2705b9de1e6e90a
      [bin/bitcoind.dbg]=2db574b0832bbe0eac555c386efda2e16b70616987ce397f8d705db897904bc7
      [bin/bitcoin-tx.dbg]=928cdcb4e2ca9f841a6916aed5ba5a3a36e98b852f72c5f52113c1a31939a8fd
      [bin/bitcoin-util.dbg]=dc44bc74dc18208781f12891731e4175b7c529adf115af5525440bad9c286be9
      [bin/bitcoin-wallet.dbg]=82e814b3b46ce5271cbcd01dbc928061333969d834e6f4919e0e4e5939e5c5f8
      [bin/bitcoin-qt.dbg]=21600762626c3efd0ab1eb11f383ec4b50c223e2fe31e6208ea6b291dc75ae46
      [libexec/bitcoin-node.dbg]=5dc2f9ab3f9737618dcce5f898df4e59abdba9cae03f193b9a9e4c8e4adc52fd
      [libexec/bitcoin-gui.dbg]=716dd26289b8bce010c2ece77f63a020870c579782064fadaad385f5e0c8356d
      [libexec/test_bitcoin.dbg]=d39bb2352ff6f08cd4a9343b68784a5c07e53152f38043d603794eb1fb763cab
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more aarch64 binaries/.dbg diverged from upstream GUIX v31.1rc1"; exit 1; }
    echo "OK: all 10 aarch64 binaries and all 10 .dbg files match upstream GUIX v31.1rc1"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
