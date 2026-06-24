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
  # rc1: route the depends rewrite through the canon mechanism
  # (gcc-debug-canon-prefix-map.patch, applied to crossGuixGccX86 in
  # the toolchain.nix) instead of -ffile-prefix-map: gcc ggc-allocates
  # every fired argv map rewrite, and the depends rewrite fires on every
  # header → flips var-tracking's loclist representative choice in
  # blockmanager_tests.cpp's CU (test_bitcoin-only, hence why only
  # test_bitcoin.dbg diverged). canon rewrites are malloc'd (GGC-neutral)
  # so the depends path is observed-canonical AS IF the build ran at
  # GUIX's literal /bitcoin/depends/<triple> — no ggc poisoning. The
  # other prefix-maps stay on argv: they fire on disjoint per-CU header
  # sets and don't flip anything (riscv64/aarch64/armhf/ppc64 confirm).
  cflags = "-O2 -g"
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
    # canon-prefix-map pair (consumed by gcc-debug-canon-prefix-map.patch):
    # rewrite the depends path AS IF the build observed the canonical
    # GUIX prefix throughout — argv -ffile-prefix-map fires on the
    # canonicalized name (matches nothing → no ggc allocations on header
    # rewrites), the macro/file tables record the canon path, and DWARF
    # comes out spelled exactly like upstream's.
    NIX_DEBUG_CANON_PREFIX_MAP = "${depends}=/bitcoin/depends/x86_64-linux-gnu";
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
  # file byte-matches the upstream GUIX v31.1rc1 x86_64-linux-gnu release
  # (the .dbg are what ship in the separate -debug.tar.gz). Any divergence
  # (or a missing file) fails the build — this derivation is a
  # reproducibility test, not a best-effort build.
  postFixup = ''
    declare -A expected=(
      [bin/bitcoin]=caa9c4cb517df25ce634542ef93823632641a063c96beb2d1544dfbaab160ca7
      [bin/bitcoin-cli]=6abd14456bd756226ac9b104301f024e162432b0ef25eac81a64df52b7e61b08
      [bin/bitcoind]=6affd25017d18116746f3a99a96162ed93c3b138ce0d5cc54095563dc9637b21
      [bin/bitcoin-tx]=7d614b4ba22ffdd8934fbf49fa0fbdb5eea051addfaaede38a785d5d00c9d412
      [bin/bitcoin-util]=2d0b1828cac470db1f574525f9df21f904cb6fb314dbe28a2ce531d20b77f4a3
      [bin/bitcoin-wallet]=d04185a69379e1dd06c547982908402532fe71549d6aaf01febdfc8fa7044bbb
      [bin/bitcoin-qt]=161d9b2dd1dfcd579bbdd0a1192ed224aa1233347c5a7330566cddbd1b7bd89b
      [libexec/bitcoin-node]=720ca74ddea34791719f2843f60b7f09b5c54d28512a7d1f6534fbd3c44d11c9
      [libexec/bitcoin-gui]=4ddd713b632ca9872a8e4e73458742134001264829bcdac51f6c18c869490579
      [libexec/test_bitcoin]=d891b01337f5ec686b8bd5c4e6a17b41abd046699f94e4af48652064f67b4d2e
      [bin/bitcoin.dbg]=2eef35daa53d1c00bbca4d60d60cbaf8269064311d26b34b25b48a9d61cec60f
      [bin/bitcoin-cli.dbg]=9608165f11519daf158c74b03da482233694766cde5d8b43cf75ed0fd627ae4b
      [bin/bitcoind.dbg]=2fcbbf09b000e1c1ca1b691828aa8db1053798b0eb168917803420571b177bb7
      [bin/bitcoin-tx.dbg]=abdcbd55707b1576bbf2832a75413c5d992a6df7170e2f714e1086f044becb11
      [bin/bitcoin-util.dbg]=a32afd02c42e20c9aa4d6121d5b7be6188641f5aa3ef829ab1ff5d1236cf085f
      [bin/bitcoin-wallet.dbg]=76e775c8143569f1bbe0f3c3bf647a6860c1332a3f37e4b61092be1f8c6efd68
      [bin/bitcoin-qt.dbg]=70975de048d64f9509847976d272cbe34f85edd50bcb8eb3578bf183acd1e56c
      [libexec/bitcoin-node.dbg]=a9446c27d432a9974ffde4cd35899a75b361ed9b5245da6152d212747a8f9240
      [libexec/bitcoin-gui.dbg]=4c193356b96c6fa7199d69d5f85d1ae2b0d1598a996616f3a3634f244928a603
      [libexec/test_bitcoin.dbg]=025542e41cdbcc6c09e503e8b3ef07e60483622f3f09fe259f1c30e8ea0e4b1b
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more binaries/.dbg diverged from upstream GUIX v31.1rc1"; exit 1; }
    echo "OK: all 10 binaries and all 10 .dbg files match upstream GUIX v31.1rc1"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
