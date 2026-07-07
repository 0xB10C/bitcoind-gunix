# Cross-build a full Bitcoin Core v31.0 linux-gnu release (all 10 binaries,
# incl. the Qt GUI), byte-for-byte identical to the upstream GUIX release —
# parameterized over the target. Used (via default.nix's mkLinuxCrossTarget)
# for riscv64-linux-gnu, arm-linux-gnueabihf and powerpc64-linux-gnu;
# x86_64-linux-gnu/release.nix (x86_64 cross-to-self) and aarch64-linux-gnu/release.nix
# predate it and keep their bespoke files. Structure and reasoning are
# identical to aarch64-linux-gnu/release.nix — see its comments and
# x86_64-linux-gnu/release.nix's for the full story on every flag.
{ lib
, gcc14Stdenv
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends # the target's depends tree (Qt included)
, crossInputs # cross cc/bintools (provides <hostTriple>-gcc/-objcopy/…)
, guixGcc # the unwrapped cross gcc — for header prefix-maps
, linuxHeaders # kernel headers — gcc canonicalizes the sys-include symlinks to this store path
, hostTriple # GUIX target triple, e.g. "riscv64-linux-gnu"
, dynamicLinker # the target's ELF interpreter (build.sh's glibc_dynamic_linker)
, extraCXXFLAGS ? "" # build.sh per-host extras (e.g. armhf -Wno-psabi)
, debugCanonMap ? false # gcc has the canon patch: rewrite /build→DISTSRC via env, use GUIX's literal maps
, canonDepends ? false # rewrite depends→/bitcoin via the canon env var instead of -ffile-prefix-map
                       # (an argv map that FIRES ggc-allocates each rewrite and flips var-tracking
                       # loclists in big CUs — GUIX fires no map on its real-/bitcoin depends)
# `{}` = no per-binary upstream hashes published (upstream's SHA256SUMS
# covers only the assembled archives, gated in tarball.nix) — the
# per-binary gate is skipped. Pass an attrset {bin/bitcoind=…; …} to
# re-enable it once reference hashes exist.
, expectedHashes ? { }
, pname # e.g. "bitcoind-riscv64"
}:

let
  # Match GUIX's HOST_CFLAGS/HOST_CXXFLAGS: bare `-O2 -g` plus prefix maps
  # (see x86_64-linux-gnu/release.nix for the full map reasoning). NO explicit
  # frame-pointer flags: crossInputs is the NoFp wrapper variant, so the
  # target's -O2 default applies and DW_AT_producer stays flag-free like
  # upstream's (any -m flags recorded there are DRIVER-injected from the
  # gcc's configured/seeded defaults, which mkLinuxCrossTarget makes
  # identical to GUIX's).
  # With debugCanonMap, the /build→DISTSRC rewrite happens via the gcc
  # canon env var (transparent to the file-table dedupe logic — see the
  # gcc-debug-canon-prefix-map.patch header), and the source-tree
  # -fdebug-prefix-map is spelled exactly like GUIX build.sh's, on the
  # post-canon path. Without it, both are ordinary maps from /build.
  distsrc = "/distsrc-base/distsrc-${version}-${hostTriple}";
  cflags = "-O2 -g"
    + lib.optionalString (!canonDepends)
        " -ffile-prefix-map=${depends}=/bitcoin/depends/${hostTriple}"
    + " -ffile-prefix-map=${guixGcc}/include/c++/14.3.0=/usr/include/c++"
    + " -ffile-prefix-map=${guixGcc}/${hostTriple}/sys-include=/usr/include"
    + " -ffile-prefix-map=${guixGcc}/lib/gcc=/usr/lib/gcc"
    + " -ffile-prefix-map=${linuxHeaders}/include=/usr/include"
    + (if debugCanonMap
       then " -fdebug-prefix-map=${distsrc}/src=."
       else " -fdebug-prefix-map=/build/bitcoin-${version}=${distsrc}"
          + " -fdebug-prefix-map=/build/bitcoin-${version}/src=.");

  binaries = [
    "bin/bitcoin" "bin/bitcoin-cli" "bin/bitcoind" "bin/bitcoin-tx"
    "bin/bitcoin-util" "bin/bitcoin-wallet" "bin/bitcoin-qt"
    "libexec/bitcoin-node" "libexec/bitcoin-gui" "libexec/test_bitcoin"
  ];

  # canon env pairs (first match wins; the prefixes are disjoint). The
  # /build pair must stay FIRST so ppc64's pre-canonDepends single-pair
  # behavior is unchanged.
  canonPairs =
    lib.optional debugCanonMap "/build/bitcoin-${version}=${distsrc}"
    ++ lib.optional canonDepends "${depends}=/bitcoin/depends/${hostTriple}";
in
gcc14Stdenv.mkDerivation {
  inherit pname;
  name = pname;
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  # Match GUIX's CONFIGFLAGS (contrib/guix/libexec/build.sh): leave
  # BUILD_TESTS at its default ON (builds bitcoin-tx/-util/-wallet +
  # test_bitcoin), skip bench/fuzz/gui-tests. The depends toolchain.cmake
  # auto-enables BUILD_GUI + WITH_QRENCODE because the Qt depends are
  # present, so bitcoin-qt / libexec/bitcoin-gui build too.
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
    # override the depends toolchain.cmake. Point CC/CXX at the cross
    # compiler so cmake cross-compiles.
    export CC=${hostTriple}-gcc
    export CXX=${hostTriple}-g++

    # Drop the -frandom-seed=<out-hash> appended by nixpkgs'
    # reproducible-builds hook — recorded in DW_AT_producer (see
    # bitcoind.nix).
    export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/${hostTriple}.
    ln -s ${depends} depends/${hostTriple}

    # The target's ELF interpreter; mirrors GUIX's HOST_LDFLAGS
    # (build.sh's glibc_dynamic_linker case).
    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=${dynamicLinker} -Wl,-O2 -static-libstdc++ -static-libgcc"
    )
  '';

  env = {
    CFLAGS = cflags;
    # build.sh appends per-host CXXFLAGS extras (armhf: -Wno-psabi).
    CXXFLAGS = cflags + lib.optionalString (extraCXXFLAGS != "") " ${extraCXXFLAGS}";
    NIX_DONT_SET_RPATH = "1";
    NIX_NO_SELF_RPATH = "1";
  } // lib.optionalAttrs (canonPairs != [ ]) {
    NIX_DEBUG_CANON_PREFIX_MAP = lib.concatStringsSep ":" canonPairs;
  };

  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    # New nixos-26.05 cc-wrapper defaults GUIX doesn't apply (see x86_64-linux-gnu/release.nix):
    # strictflexarrays1 is codegen-affecting; libcxxhardeningfast is libc++-only.
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Mirror GUIX build.sh's split-debug + .comment handling (same as
  # x86_64-linux-gnu/release.nix). Use the CROSS binutils 2.41 (<hostTriple>-* from
  # crossInputs) — not nixpkgs' native one — so strip/objcopy behave like
  # upstream's. All .dbg are byte-identical to upstream's (gated below),
  # so objcopy --add-gnu-debuglink computes upstream's CRC naturally —
  # no byte patches anywhere.
  postInstall = ''
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    for rel in ${toString binaries}; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      ${hostTriple}-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
      ${hostTriple}-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
      ${hostTriple}-strip --enable-deterministic-archives -p -s "$f"
      ${hostTriple}-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
      ${hostTriple}-objcopy --update-section .comment=comment.bin "$f"
    done
  '';

  # Reproducibility gate: assert every shipped binary AND every .dbg debug
  # file byte-matches the upstream GUIX release for this target
  # (the .dbg are what ship in the separate -debug.tar.gz).
  # When `expectedHashes` is empty, the gate is skipped and the binaries
  # are merely listed — upstream publishes no per-binary hashes (only the
  # assembled archives, gated in tarball.nix).
  postFixup = if expectedHashes == { } then ''
    echo "BUILT (no per-binary upstream gate — archive gates in tarball.nix): ${hostTriple}"
    for rel in ${toString binaries}; do
      f="$out/$rel"
      [ -f "$f" ] && echo "  $rel  $(sha256sum "$f" | cut -d' ' -f1)"
    done
  '' else ''
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more ${hostTriple} binaries/.dbg diverged from upstream GUIX release"; exit 1; }
    echo "OK: all ${toString (builtins.length (builtins.attrNames expectedHashes))} asserted ${hostTriple} artifacts match upstream"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
