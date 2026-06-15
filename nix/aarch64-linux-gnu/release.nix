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
  # file byte-matches the upstream GUIX v31.0 aarch64-linux-gnu release
  # (the .dbg are what ship in the separate -debug.tar.gz).
  postFixup = ''
    declare -A expected=(
      [bin/bitcoin]=c793384c78c11b2125d0b68cc62b05fab7a96d6438f005f9e375f7d4a41bfe4c
      [bin/bitcoin-cli]=25c2743efb90ccaccbaea9f481e0a0357310af04b04f78b2320c0cc65ce12bf6
      [bin/bitcoind]=6f66822a44b4d4edd2a8ae1a11f63dd4db8d070e219c8eb54a3e2faa536409c2
      [bin/bitcoin-tx]=b41284232c62323a890bb8ba3befba1e1c4d197155461766a19618a0aaccda87
      [bin/bitcoin-util]=3a0daa1c1f840fc7f9ac18a29619aab071230ee5f9ef2690fd7f93f3b9003488
      [bin/bitcoin-wallet]=b7c2bb47030c7fb7e652c70a68c4c012cdd2e3562396423fc6c9ef01e0b589ac
      [bin/bitcoin-qt]=760c3de5ff9a54edfc6bf0c769df6dfe610aa9055d8ea0fa99edca4a62dc14d4
      [libexec/bitcoin-node]=f213271f7cec156be3d155c3c1012f4c226e2b9216a40215355a190105d1fad5
      [libexec/bitcoin-gui]=f85193a8b7f4323f612b92a5b7e19cda977f90bb9c26543d3f5277bf10c59291
      [libexec/test_bitcoin]=940fd792624130b36c1aef4fb4fc61723e622635478e7301bf37827caac9f1c5
      [bin/bitcoin.dbg]=a8e722fcb8e30edb417d354aa7dab72b0d61fb4d31e3b735226d2c627b13e3f7
      [bin/bitcoin-cli.dbg]=008409b760e5478e852ba0497fd9ea46b13b54a91dd095b39e64775c520243f9
      [bin/bitcoind.dbg]=c9874604dc0c1f064a06c4bd9205b0ba0ec003e1e33c3aae319fc9640f535317
      [bin/bitcoin-tx.dbg]=550ff80b5930b557f094a9f72ea2043ffd348cf02fa5374458c78bd80e4630f6
      [bin/bitcoin-util.dbg]=c45b2b672038b9b005c8243adee79dc6239fc16b056a619a2dd5e7ca2c0ce08e
      [bin/bitcoin-wallet.dbg]=ec150d2d38aab542e7ea1eb824adb16924c93924e78d82d23c1673c108523890
      [bin/bitcoin-qt.dbg]=2c846fa6508cd70709fc1bd962331a6c7df9664a5a8195b71e0ebaf39f03188c
      [libexec/bitcoin-node.dbg]=c17dcda063ccab62a1fb217899ad3f25c35496be38010ad0714fa894a76aa64c
      [libexec/bitcoin-gui.dbg]=e516b319336cf01cbc897681df6cac81576f92210d5db644208c6b2b55485456
      [libexec/test_bitcoin.dbg]=ae4076dcaecb75f0ba1164828c602b57823570eef6b5f4976841e5c5fb35afeb
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more aarch64 binaries/.dbg diverged from upstream GUIX v31.0"; exit 1; }
    echo "OK: all 10 aarch64 binaries and all 10 .dbg files match upstream GUIX v31.0"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
