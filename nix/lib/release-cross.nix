# Cross-build a Bitcoin Core linux-gnu release, byte-for-byte identical to
# the upstream GUIX build — parameterized over the target triple AND over
# which of upstream's TWO build passes this is.
#
# At the v32.x branch-off upstream split contrib/guix/libexec/build.sh into
# per-platform scripts, and each platform now builds twice, in two separate
# guix containers, from two separate depends trees:
#
#   build_linux.sh      depends NO_QT=1, cmake -DBUILD_GUI=OFF,
#                       `cmake --build build` + `cmake --install build`
#                       → bin/{bitcoin,bitcoind,bitcoin-cli,bitcoin-tx,
#                              bitcoin-util,bitcoin-wallet}
#                         libexec/{bitcoin-node,test_bitcoin}
#   build_linux_gui.sh  depends WITH Qt, cmake with every non-GUI target
#                       OFF, `--target bitcoin-gui bitcoin-qt`,
#                       `--install --component bitcoin-{gui,qt}`
#                       → bin/bitcoin-qt, libexec/bitcoin-gui
#
# Both install into the SAME prefix; libexec/package.sh then splits debug
# info and tars the merged tree. This file is ONE pass (`guiOnly` selects
# which); nix/lib/package.nix runs package.sh over the merged tree and
# nix/lib/artifact.nix gates each published archive.
#
# Used for every linux target via nix/lib/linux-cross-target.nix and the
# bespoke x86_64/aarch64 toolchain.nix wirings. See
# nix/x86_64-linux-gnu/toolchain.nix and CLAUDE.md for the full story on
# every flag.
{ lib
, gcc14Stdenv
, pkg-config
, cmake
, python3
, version
, src
, depends # the target's depends tree (Qt-less for pass 1, with Qt for pass 2)
, crossInputs # cross cc/bintools (provides <hostTriple>-gcc/-objcopy/…)
, guixGcc # the unwrapped cross gcc — for header prefix-maps
, linuxHeaders # kernel headers — gcc canonicalizes the sys-include symlinks to this store path
, hostTriple # GUIX target triple, e.g. "riscv64-linux-gnu"
, extraCXXFLAGS ? "" # per-host extras (e.g. armhf -Wno-psabi)
, debugCanonMap ? false # gcc has the canon patch: rewrite /build→DISTSRC via env, use GUIX's literal maps
, canonDepends ? false # rewrite depends→/bitcoin via the canon env var instead of -ffile-prefix-map
                       # (an argv map that FIRES ggc-allocates each rewrite and flips var-tracking
                       # loclists in big CUs — GUIX fires no map on its real-/bitcoin depends)
# false = upstream's build_linux.sh pass (everything except the GUI);
# true  = its build_linux_gui.sh pass (ONLY bitcoin-gui + bitcoin-qt).
, guiOnly ? false
# build_linux.sh adds -Wl,--fatal-warnings to HOST_LDFLAGS for every target
# EXCEPT riscv64 (boostorg/test#345).
, fatalLinkWarnings ? true
, pname # e.g. "bitcoind-riscv64"
}:

let
  # Match GUIX's HOST_CFLAGS/HOST_CXXFLAGS: bare `-O2 -g` plus prefix maps
  # (see x86_64-linux-gnu/toolchain.nix for the full map reasoning). NO
  # explicit frame-pointer flags: crossInputs is the NoFp wrapper variant,
  # so the target's -O2 default applies and DW_AT_producer stays flag-free
  # like upstream's (any -m flags recorded there are DRIVER-injected from
  # the gcc's configured/seeded defaults, which the toolchain wiring makes
  # identical to GUIX's).
  # With debugCanonMap, the /build→DISTSRC rewrite happens via the gcc
  # canon env var (transparent to the file-table dedupe logic — see the
  # gcc-debug-canon-prefix-map.patch header), and the source-tree
  # -fdebug-prefix-map is spelled exactly like upstream's, on the
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

  # canon env pairs (first match wins; the prefixes are disjoint). The
  # /build pair must stay FIRST so ppc64's pre-canonDepends single-pair
  # behavior is unchanged.
  canonPairs =
    lib.optional debugCanonMap "/build/bitcoin-${version}=${distsrc}"
    ++ lib.optional canonDepends "${depends}=/bitcoin/depends/${hostTriple}";
  # build_linux.sh's HOST_LDFLAGS + the -static-libstdc++/-static-libgcc it
  # passes through CMAKE_EXE_LINKER_FLAGS. The ELF interpreter itself is
  # NOT written out here: preConfigure asks upstream's own
  # glibc_dynamic_linker (libexec/setup.sh) for it.
  ldflagsAround = {
    before = "-Wl,--as-needed -Wl,--dynamic-linker=";
    after = " -Wl,-O2"
      + lib.optionalString fatalLinkWarnings " -Wl,--fatal-warnings"
      + " -static-libstdc++ -static-libgcc";
  };
in
gcc14Stdenv.mkDerivation ({
  inherit pname;
  name = pname;
  inherit src;

  # manifest_gui.scm puts python-minimal in the GUI pass's container (for
  # package.sh), and build_linux_gui.sh configures with -Werror=dev, which
  # turns CMakeLists' "Minimum required Python not found" warning into a
  # hard error. manifest_build.scm has no python, so pass 1 stays without.
  nativeBuildInputs = [ pkg-config cmake ] ++ lib.optional guiOnly python3 ++ crossInputs;

  cmakeBuildDir = "build";
  # GUIX passes no build type, so bitcoin's CMakeLists defaults to
  # RelWithDebInfo; nixpkgs' cmake hook would force Release. Visible in
  # DW_AT_producer; same effective codegen (-O2).
  cmakeBuildType = "RelWithDebInfo";
  # Exactly upstream's per-pass cmake flags (build_linux.sh /
  # build_linux_gui.sh). Note NEITHER pass passes -DBUILD_GUI=ON: in the
  # GUI pass the depends toolchain.cmake turns it on because Qt is present
  # in that depends tree.
  cmakeFlags = [
    "--toolchain=${depends}/toolchain.cmake"
    "-DBUILD_BENCH=OFF"
    "-DBUILD_FUZZ_BINARY=OFF"
    "-DBUILD_GUI_TESTS=OFF"
    "-DCMAKE_SKIP_RPATH=TRUE"
    "-DREDUCE_EXPORTS=ON"
    "-DWITH_CCACHE=OFF"
  ] ++ (if guiOnly then [
    "-DBUILD_BITCOIN_BIN=OFF"
    "-DBUILD_CLI=OFF"
    "-DBUILD_DAEMON=OFF"
    "-DBUILD_TESTS=OFF"
    "-DBUILD_TX=OFF"
    "-DBUILD_UTIL=OFF"
    "-DBUILD_WALLET_TOOL=OFF"
    "-Werror=dev"
  ] else [
    "-DBUILD_GUI=OFF"
  ]);

  preConfigure = ''
    # nixpkgs' cmake setup-hook passes -DCMAKE_C_COMPILER=$CC etc., which
    # override the depends toolchain.cmake. Point CC/CXX at the cross
    # compiler so cmake cross-compiles.
    export CC=${hostTriple}-gcc
    export CXX=${hostTriple}-g++

    # Drop the -frandom-seed=<out-hash> appended by nixpkgs'
    # reproducible-builds hook — recorded in DW_AT_producer.
    export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/${hostTriple}.
    ln -s ${depends} depends/${hostTriple}

    # The HOST → ELF-interpreter table lives in upstream's
    # libexec/setup.sh (glibc_dynamic_linker). Ask it rather than keeping
    # our own copy of the paths. setup.sh is the PACKAGING environment —
    # it also sets TAR_OPTIONS, OUTDIR, INSTALLPATH and a umask — so it is
    # sourced in a throwaway subshell in a temp dir; the exports here only
    # satisfy its required-variable check, and the empty stand-in archive
    # stops it reaching for `git archive`. See nix/lib/guix-setup.sh for
    # the two lines the Nix sandbox forces out of it.
    dynamic_linker=$(
      set -e
      upstream_setup=$PWD/contrib/guix/libexec/setup.sh
      tmp=$(mktemp -d)
      cd "$tmp"
      export HOST=${hostTriple}
      export DISTNAME=bitcoin-${version}
      export JOBS=1
      export DISTSRC=$tmp
      export OUTDIR=$tmp/output
      export DIST_ARCHIVE_BASE=$tmp/dist-archive
      mkdir -p "$DIST_ARCHIVE_BASE"
      : > "$DIST_ARCHIVE_BASE/$DISTNAME.tar.gz"
      bash ${./guix-setup.sh} "$upstream_setup" ./setup.sh
      source ./setup.sh > /dev/null
      glibc_dynamic_linker ${hostTriple}
    )
    [ -n "$dynamic_linker" ] || {
      echo "setup.sh's glibc_dynamic_linker has no entry for ${hostTriple}"; exit 1; }
    echo "ELF interpreter for ${hostTriple}: $dynamic_linker"

    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=${ldflagsAround.before}$dynamic_linker${ldflagsAround.after}"
    )
  '';

  env = {
    CFLAGS = cflags;
    # build_linux.sh appends per-host CXXFLAGS extras (armhf: -Wno-psabi).
    CXXFLAGS = cflags + lib.optionalString (extraCXXFLAGS != "") " ${extraCXXFLAGS}";
    NIX_DONT_SET_RPATH = "1";
    NIX_NO_SELF_RPATH = "1";
  } // lib.optionalAttrs (canonPairs != [ ]) {
    NIX_DEBUG_CANON_PREFIX_MAP = lib.concatStringsSep ":" canonPairs;
  };

  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    # nixos-26.05 cc-wrapper defaults GUIX doesn't apply:
    # strictflexarrays1 is codegen-affecting; libcxxhardeningfast is libc++-only.
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Split-debug, the extras and the archives all happen ONCE over the
  # merged install tree, by upstream's own libexec/package.sh — see
  # nix/lib/package.nix.
  dontStrip = true;
  # Upstream ships man pages UNCOMPRESSED, and package.sh archives the
  # install tree as-is; nixpkgs' fixup would gzip them.
  dontGzipMan = true;
  doCheck = false;
  enableParallelBuilding = true;
} // lib.optionalAttrs guiOnly {
  # build_linux_gui.sh builds and installs ONLY these two targets.
  buildFlags = [ "bitcoin-gui" "bitcoin-qt" ];
  installPhase = ''
    runHook preInstall
    cmake --install . --component bitcoin-gui
    cmake --install . --component bitcoin-qt
    runHook postInstall
  '';
})
