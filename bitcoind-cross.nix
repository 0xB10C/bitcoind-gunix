# Cross-build a full Bitcoin Core v31.0 linux-gnu release (all 10 binaries,
# incl. the Qt GUI), byte-for-byte identical to the upstream GUIX release —
# parameterized over the target. Used (via default.nix's mkLinuxCrossTarget)
# for riscv64-linux-gnu, arm-linux-gnueabihf and powerpc64-linux-gnu;
# bitcoind.nix (x86_64 cross-to-self) and bitcoind-aarch64.nix predate it
# and keep their bespoke files. Structure and reasoning are identical to
# bitcoind-aarch64.nix — see its comments and bitcoind.nix's for the full
# story on every flag.
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
, expectedHashes # rel path -> upstream sha256 for every asserted artifact (binaries + byte-matching .dbg)
, debuglinkCrcs ? { } # rel path -> upstream's 4 .gnu_debuglink CRC bytes (hex, file order) for binaries whose .dbg diverges
, pname # e.g. "bitcoind-riscv64"
}:

let
  # Match GUIX's HOST_CFLAGS/HOST_CXXFLAGS: bare `-O2 -g` plus prefix maps
  # (see bitcoind.nix for the full map reasoning). NO explicit
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
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/${hostTriple}"
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
  # DW_AT_producer (see bitcoind.nix); same effective codegen (-O2).
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
  } // lib.optionalAttrs debugCanonMap {
    NIX_DEBUG_CANON_PREFIX_MAP = "/build/bitcoin-${version}=${distsrc}";
  };

  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    # New nixos-26.05 cc-wrapper defaults GUIX doesn't apply (see bitcoind.nix):
    # strictflexarrays1 is codegen-affecting; libcxxhardeningfast is libc++-only.
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Mirror GUIX build.sh's split-debug + .comment handling (same as
  # bitcoind.nix). Use the CROSS binutils 2.41 (<hostTriple>-* from
  # crossInputs) — not nixpkgs' native one — so strip/objcopy behave like
  # upstream's. Where the .dbg files are byte-identical (gated below),
  # objcopy --add-gnu-debuglink computes upstream's CRC naturally; for
  # the binaries listed in debuglinkCrcs (their .dbg differ from
  # upstream's in .debug_loclists — see CLAUDE.md's loclists status),
  # the 4 CRC bytes at the end of .gnu_debuglink are overwritten with
  # upstream's so the RUNTIME binary still byte-matches.
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
  '' + lib.optionalString (debuglinkCrcs != { }) ''

    declare -A crcs=(
${lib.concatStringsSep "\n" (lib.mapAttrsToList (rel: v: "      [${rel}]=${v}") debuglinkCrcs)}
    )
    for rel in "''${!crcs[@]}"; do
      f="$out/$rel"
      off=$(${hostTriple}-readelf -SW "$f" | awk '$2==".gnu_debuglink" {print strtonum("0x"$5) + strtonum("0x"$6) - 4}')
      [ -n "$off" ] || { echo "FAIL: no .gnu_debuglink in $rel"; exit 1; }
      printf "%b" "$(echo "''${crcs[$rel]}" | sed 's/../\\x&/g')" | dd of="$f" bs=1 seek=$off count=4 conv=notrunc status=none
      echo "patched debuglink CRC of $rel at offset $off to ''${crcs[$rel]}"
    done
  '';

  # Reproducibility gate: assert every shipped binary AND every .dbg debug
  # file byte-matches the upstream GUIX v31.0 release for this target
  # (the .dbg are what ship in the separate -debug.tar.gz).
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
