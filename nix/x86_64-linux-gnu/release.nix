# Build the full Bitcoin Core v31.0 x86_64-linux-gnu release through the
# GUIX-style cross-to-self toolchain (default.nix's crossGuixGccX86 — the
# x86_64-linux-gnu-triple cross gcc/glibc/binutils), byte-for-byte identical
# to the upstream GUIX release. The x86_64 sibling of aarch64-linux-gnu/release.nix.
#
# This replaced the original native-stdenv bitcoind.nix on 2026-06-10 (it
# produces the same 10 upstream hashes; the cross-to-self triple is also
# the prerequisite for fixing the .dbg divergence — see CLAUDE.md "Task #2
# finding"). Structure notes:
# - compiles via the prefixed cross compiler (CC=x86_64-linux-gnu-gcc
#   export, like the aarch64 file), not the build stdenv's native gcc;
# - split-debug uses the explicit prefixed cross binutils 2.41 (the
#   unprefixed objcopy/strip on PATH belong to the plain build stdenv =
#   binutils 2.46, whose behavior diverges);
# - vs aarch64-linux-gnu/release.nix: x86_64 frame pointers (omit BOTH at -O2 — see
#   the aarch64 file's note), the x86-64 ELF interpreter, and the x86_64
#   per-binary CRCs/hashes.
{ gcc14Stdenv # plain native build stdenv (native helper tools only)
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends # the cross-built x86_64-linux-gnu depends tree (Qt included)
, crossInputs # x86_64-linux-gnu cross cc/bintools (x86_64-linux-gnu-gcc/-objcopy/…)
, guixGcc # the unwrapped cross gcc (crossGuixGccX86.cc) — for header prefix-maps
, linuxHeaders # kernel headers — gcc canonicalizes the sys-include symlinks to this store path
}:

let
  # Match GUIX's HOST_CFLAGS/HOST_CXXFLAGS (build.sh): bare `-O2 -g` plus
  # prefix maps. NO explicit frame-pointer flags: the x86_64 -O2 default
  # omits both, and any explicit -f/-m flag is recorded in DW_AT_producer
  # (upstream's producer has none — required for .dbg parity). That only
  # works because crossInputs is the NoFp wrapper variant (default.nix),
  # which doesn't inject -fno-omit-frame-pointer.
  #
  # The maps (gcc applies them in command-line order, LAST matching wins,
  # so the specific src=. map comes after the broader build-dir map):
  # - depends → /bitcoin/depends/… is ffile (runtime-relevant: boost
  #   header paths in assert strings; GUIX's depends really lives at
  #   /bitcoin/depends in its container, unmapped).
  # - the build dir → /distsrc-base/distsrc-<ver>-<triple> is fdebug
  #   (DWARF-only): GUIX builds bitcoind from a dist copy at that REAL
  #   path (build.sh's ${DISTSRC}), so upstream's DW_AT_comp_dir is
  #   /distsrc-base/distsrc-31.0-x86_64-linux-gnu/build/src. No runtime
  #   string ever used this map (the binary matched upstream even when it
  #   mapped to /bitcoin).
  # - src=. is fdebug, exactly GUIX's `-fdebug-prefix-map=${DISTSRC}/src=.`
  #   → DW_AT_name "./addrdb.cpp" etc.
  # The gcc-store maps reproduce what GUIX's `-ffile-prefix-map=
  # /gnu/store/<item>=/usr` (one per store item, build.sh) does to the
  # compiler's header paths in the DWARF line tables — with the layout
  # difference that GUIX's gcc installs the C++ headers WITHOUT a version
  # subdir (--with-gxx-include-dir), so /usr/include/c++ maps our
  # include/c++/14.3.0; glibc headers resolve from the cross gcc's baked
  # sys-include copy, upstream spells them /usr/include.
  cflags = "-O2 -g"
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/x86_64-linux-gnu"
    + " -ffile-prefix-map=${guixGcc}/include/c++/14.3.0=/usr/include/c++"
    + " -ffile-prefix-map=${guixGcc}/x86_64-linux-gnu/sys-include=/usr/include"
    + " -ffile-prefix-map=${guixGcc}/lib/gcc=/usr/lib/gcc"
    + " -ffile-prefix-map=${linuxHeaders}/include=/usr/include"
    + " -fdebug-prefix-map=/build/bitcoin-${version}=/distsrc-base/distsrc-${version}-x86_64-linux-gnu"
    + " -fdebug-prefix-map=/build/bitcoin-${version}/src=.";
in
gcc14Stdenv.mkDerivation {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  # Match GUIX's CONFIGFLAGS (contrib/guix/libexec/build.sh): leave
  # BUILD_TESTS at its default ON (that's what builds bitcoin-tx/-util/
  # -wallet + test_bitcoin), skip bench/fuzz/gui-tests; the depends
  # toolchain.cmake auto-enables BUILD_GUI + WITH_QRENCODE because the Qt
  # depends are present.
  cmakeBuildDir = "build";
  # GUIX doesn't pass a build type, so bitcoin's CMakeLists defaults to
  # RelWithDebInfo; nixpkgs' cmake hook would force Release. The choice is
  # visible in DW_AT_producer: RelWithDebInfo = toolchain _INIT "-O2" +
  # cmake's own "-O2 -g" + env CFLAGS "-O2 -g" = the "-g -g -O2 -O2 -O2"
  # upstream records. Same effective codegen (-O2) either way.
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
    # compiler (the native build stdenv would otherwise leave CC=gcc →
    # the unprefixed native toolchain).
    export CC=x86_64-linux-gnu-gcc
    export CXX=x86_64-linux-gnu-g++

    # Drop the -frandom-seed=<out-hash> that nixpkgs' reproducible-builds
    # stdenv hook appends to NIX_CFLAGS_COMPILE: it's recorded in
    # DW_AT_producer (upstream has no such flag) and its value is our
    # store hash — both diverge the .dbg. Codegen is unaffected here
    # (the seed only matters for LTO/coverage symbol naming).
    export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/x86_64-linux-gnu.
    ln -s ${depends} depends/x86_64-linux-gnu

    # Mirror GUIX's HOST_LDFLAGS + static-libstdc++/libgcc (build.sh:
    # "-Wl,--as-needed -Wl,--dynamic-linker=$glibc_dynamic_linker
    # -Wl,-O2" + "-static-libstdc++ -static-libgcc"). Set via
    # cmakeFlagsArray so the space-separated value survives the nixpkgs
    # cmake hook's word splitting. The dynamic-linker flag pins the
    # standard FHS x86-64 interpreter instead of the Nix glibc store path
    # (the binary then won't run on NixOS without nix-ld, which is fine —
    # the goal is byte parity with the GUIX release).
    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 -Wl,-O2 -static-libstdc++ -static-libgcc"
    )
  '';

  env = {
    CFLAGS = cflags;
    CXXFLAGS = cflags;
    NIX_DONT_SET_RPATH = "1";
    NIX_NO_SELF_RPATH = "1";
  };

  # Drop the nixpkgs hardenings GUIX's toolchain doesn't apply (full
  # per-flag reasoning in CLAUDE.md's "Workarounds" section; bitcoin's
  # CMake re-adds the ones it wants for core_interface targets, so the
  # nixpkgs globals would diverge e.g. secp256k1 from upstream).
  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Mirror GUIX build.sh's split-debug + .comment handling (same as
  # aarch64-linux-gnu/release.nix). Use the CROSS binutils 2.41 (x86_64-linux-gnu-*
  # from crossInputs) — the unprefixed objcopy on PATH is the plain build
  # stdenv's 2.46.
  #
  # NOTE: the historical .gnu_debuglink CRC32 byte-patch is GONE (2026-06-11):
  # the .dbg files are now byte-identical to upstream's (cross-to-self
  # triple + GUIX .drv-0 debug-prefix-maps + store→/usr header maps +
  # kernel headers 6.1.119 + unstripped toolchain members + compressed
  # debug sections), so objcopy --add-gnu-debuglink computes upstream's
  # CRC naturally. The postFixup gate asserts the .dbg hashes too.
  postInstall = ''
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet bin/bitcoin-qt \
      libexec/bitcoin-node libexec/bitcoin-gui libexec/test_bitcoin; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      x86_64-linux-gnu-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
      x86_64-linux-gnu-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
      x86_64-linux-gnu-strip --enable-deterministic-archives -p -s "$f"
      x86_64-linux-gnu-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
      x86_64-linux-gnu-objcopy --update-section .comment=comment.bin "$f"
    done
  '';

  # Reproducibility gate: assert every shipped binary AND every .dbg debug
  # file byte-matches the upstream GUIX v31.0 x86_64-linux-gnu release
  # (the .dbg are what ship in the separate -debug.tar.gz). Any divergence
  # (or a missing file) fails the build — this derivation is a
  # reproducibility test, not a best-effort build.
  postFixup = ''
    declare -A expected=(
      [bin/bitcoin]=eb5670aebd2b32c79215e578d2a7162fd1c98181bc558cfb8d29a4240e736521
      [bin/bitcoin-cli]=3e92883f97850bc445ac033d26d55902dcb035fdf64f78c2c03c83216f083c5d
      [bin/bitcoind]=dae69848ae9aaadcc3aa697d1c92b1283273a59c8d87b220b29ddc2813e25eb6
      [bin/bitcoin-tx]=ce3b159c9985eca941b3071c4dc573a4cf92ed9ee27fc1cf68a28d8afe893b6c
      [bin/bitcoin-util]=1d18ee4b1539110f784288462b8173d2d35d3b768ecbc3df83ebaa2781eb4306
      [bin/bitcoin-wallet]=7d8382b86cce7fde4214f295f7e134a873f176556ee98bc6dcbf9b347a25acaf
      [bin/bitcoin-qt]=3480af8fad820759a6299ea94bb3bb66f490b87c10ba44b1d0f671af382ff178
      [libexec/bitcoin-node]=01c212ee592f4ecc649b7a13c8fc0976f2d823900c66cd11460edaa59bba21ca
      [libexec/bitcoin-gui]=416e79bbebec5506ac786557519f3f5fc3fb1936a4a6074685d5f0aa24e01801
      [libexec/test_bitcoin]=c7a2a9062256920fa4b92e330857dc12e7f89882f8a3930ecdc3350acf922f8f
      [bin/bitcoin.dbg]=1384716d43d5ef52c3eaecb403a0444234e6a4ae0d267df91ddbe38670be98c4
      [bin/bitcoin-cli.dbg]=4bdbc47dd91a3e91ab123941685ede45781df639db46239dc503612e8c32a241
      [bin/bitcoind.dbg]=901020a02b461d240ed9cf7414a8471611dc165c75a11fac7485aa99d68395ca
      [bin/bitcoin-tx.dbg]=1195f5acc2833d85c304bafb968fa4b49137df0803a2ba7c4a98435f53504832
      [bin/bitcoin-util.dbg]=6eca7984de4ca310006b63f5a2880abf66361dc115cf0fb0a4bdaf34ed212bce
      [bin/bitcoin-wallet.dbg]=940cc698354eb7a19fa0430744ecc628eae34f7e4bfe5c90d201e9c1c1426d58
      [bin/bitcoin-qt.dbg]=7ad32394e2b1523ba0a8ffb46467d88d62fac48807129456da47e45545ce3d14
      [libexec/bitcoin-node.dbg]=feb4c6c54bd77eabc4cda2c54026a347b2dd738d1099d3257814ef1bb99d917d
      [libexec/bitcoin-gui.dbg]=b044673d04bf6a078541e52aa73cac910e18a74f5561ac485ac74213f11b9992
      [libexec/test_bitcoin.dbg]=1e01a9acd06e0ecb8190d39797730695e9ef47b941ace7f62dbd24b951714d9a
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more binaries/.dbg diverged from upstream GUIX v31.0"; exit 1; }
    echo "OK: all 10 binaries and all 10 .dbg files match upstream GUIX v31.0"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
