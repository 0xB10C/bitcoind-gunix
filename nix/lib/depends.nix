{ lib
, gcc14Stdenv # The GUIX builds for Bitcoin Core v31.0 use GCC 14.2.0
, fetchurl
# build-inputs
, pkg-config
, python3
, libtool
, autoconf
, automake
, cmake # needed by boost, libevent, zeromq, capnp
, which # invoked by upstream depends build scripts
, bison # libxkbcommon generates its parser with bison/yacc
, flex # companion lexer generator for the Qt/X11 deps
, gperf # fontconfig regenerates a gperf hash header
#
, version
, url
, sha256
# Target triple for the depends build. Native x86_64 by default; set to
# e.g. "aarch64-linux-gnu" to cross-compile (depends then uses
# <hostTriple>-gcc, which crossInputs must provide on PATH).
, hostTriple ? "x86_64-linux-gnu"
# Build the Qt GUI dependency tree. Disabled for the aarch64 spike.
, buildQt ? true
# Extra nativeBuildInputs providing the `<hostTriple>-gcc`/`-ar`/… cross
# toolchain when cross-compiling (empty for a native build). When
# non-empty, the build also unsets the Nix-exported CC/CXX/… so Bitcoin's
# depends derives the host_toolchain-prefixed cross tools instead of the
# native `gcc` (hosts/default.mk add_host_tool_func treats an
# environment-set CC as the host compiler). For darwin hosts the inputs
# are the UNPREFIXED clang/lld/llvm-* tools instead — darwin.mk resolves
# them via `command -v clang` etc. from PATH.
, crossInputs ? [ ]
# Extracted macOS SDK (a directory containing
# Xcode-<ver>-<build>-extracted-SDK-with-libcxx-headers/), required for
# *-apple-darwin hostTriples; passed to make as SDK_PATH. A store-path
# derivation (not an in-build extraction) so the -isysroot recorded in
# the generated toolchain.cmake stays valid for the later bitcoind build.
, darwinSdk ? null
, runCommand
}:

let
  dependsDir = "bitcoin-${version}/depends";

  isDarwin = lib.hasInfix "-apple-darwin" hostTriple;
  isMingw = lib.hasInfix "mingw" hostTriple;

  # GUIX build.sh:81 exports LIBRARY_PATH=$NATIVE_GCC/lib for the whole
  # mingw DEPENDS build ("Required for native packages"). NATIVE_GCC is
  # GUIX's gcc-toolchain — a UNION of gcc AND glibc. Unlike darwin (whose
  # ld64.lld chokes on glibc's unversioned compat symlinks, so those are
  # removed — see darwinLibraryPathDir), the mingw native tools link with
  # the ordinary GNU ld on the build host, which needs those linker-name
  # symlinks (libpthread.so → .so.0 etc.) to resolve -lpthread. So this is
  # the FULL gcc+glibc lib union with nothing removed.
  nativeLibraryPathDir = runCommand "guix-gcc-toolchain-lib-union-full" { } ''
    mkdir -p $out/lib
    for f in ${gcc14Stdenv.cc.cc.lib}/lib/*; do
      ln -sfn "$f" "$out/lib/$(basename "$f")"
    done
    for f in ${gcc14Stdenv.cc.libc}/lib/*; do
      ln -sfn "$f" "$out/lib/$(basename "$f")"
    done
  '';

  # The LIBRARY_PATH dir for the darwin depends build (see the env block
  # below for why LIBRARY_PATH is set at all). GUIX points it at ONE dir:
  # $NATIVE_GCC/lib, the gcc-toolchain UNION of gcc's and glibc's lib/.
  # We can't use our gcc/glibc lib dirs raw: nixpkgs' glibc additionally
  # installs unversioned COMPAT SYMLINKS for the libraries glibc 2.34
  # merged into libc (libpthread.so -> libpthread.so.0 etc.) which
  # vanilla glibc — GUIX's — does not ship. Those links point at ELF
  # stub shared objects, so any darwin target link passing -lpthread
  # (capnp's tools via CMake Threads) finds the ELF and ld64.lld hard-
  # errors ("unhandled file type"), while in GUIX the same -lpthread
  # falls through to the SDK's tbd. Build the union minus exactly those
  # nixpkgs-only compat links; everything vanilla glibc ships (incl. the
  # load-bearing ASCII libc.so linker script that fails capnp's -lc
  # fibers check) stays.
  darwinLibraryPathDir = runCommand "guix-gcc-toolchain-lib-union" { } ''
    mkdir -p $out/lib
    for f in ${gcc14Stdenv.cc.cc.lib}/lib/*; do
      ln -s "$f" "$out/lib/$(basename "$f")"
    done
    for f in ${gcc14Stdenv.cc.libc}/lib/*; do
      b=$(basename "$f")
      case "$b" in
        libpthread.so|librt.so|libdl.so|libutil.so|libanl.so) continue ;;
      esac
      ln -sfn "$f" "$out/lib/$b"
    done
  '';

  # `downloadFile` is the name on the remote server (defaults to `file`). It
  # only differs from `file` when the upstream depends Makefile renames the
  # tarball locally (e.g. capnp's `capnproto-c++` -> `capnproto-cxx`).
  #
  # Each source falls back to https://bitcoincore.org/depends-sources/ —
  # Bitcoin Core's canonical depends-source mirror (the depends Makefile's own
  # FALLBACK_DOWNLOAD_PATH). Several upstream hosts have since moved or 404'd
  # (xorg.freedesktop.org reorganized its proto/lib archives, savannah's
  # freetype mirror flakes), so the primary URL alone is no longer reliable;
  # the mirror keeps the exact tarballs (same sha256), making the build
  # reproducible regardless of upstream churn.
  mkFetchSource = {urlPrefix, file, sha256, downloadFile ? file}:
    fetchurl {
      urls = [
        "${urlPrefix}/${downloadFile}"
        "https://bitcoincore.org/depends-sources/${downloadFile}"
      ];
      inherit sha256;
    };

  # Nix builds are pure. We can't access the Internet during builds - so we
  # make the depends sources avaliable beforehand.
  dependsSources = {
    boost = {
      urlPrefix = "https://github.com/boostorg/boost/releases/download/boost-1.90.0";
      file = "boost-1.90.0-cmake.tar.gz";
      sha256 = "913ca43d49e93d1b158c9862009add1518a4c665e7853b349a6492d158b036d4";
    };
    libevent = {
      urlPrefix = "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable";
      file = "libevent-2.1.12-stable.tar.gz";
      sha256 = "92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb";
    };
    systemtap = {
      urlPrefix = "https://sourceware.org/ftp/systemtap/releases/";
      file = "systemtap-5.3.tar.gz";
      sha256 = "966a360fb73a4b65a8d0b51b389577b3c4f92a327e84aae58682103e8c65a69a";
    };
    sqlite = {
      urlPrefix = "https://sqlite.org/2025";
      file = "sqlite-autoconf-3500400.tar.gz";
      sha256 = "a3db587a1b92ee5ddac2f66b3edb41b26f9c867275782d46c3a088977d6a5b18";
    };
    zeromq = {
      urlPrefix = "https://github.com/zeromq/libzmq/releases/download/v4.3.5";
      file = "zeromq-4.3.5.tar.gz";
      sha256 = "6653ef5910f17954861fe72332e68b03ca6e4d9c7160eb3a8de5a5a913bfab43";
    };
    # Cap'n Proto: used by Bitcoin Core's multiprocess IPC support (new in v29+).
    # Upstream depends downloads the tarball as `capnproto-c++-X.Y.Z.tar.gz`
    # and renames it locally to `capnproto-cxx-X.Y.Z.tar.gz`.
    capnp = {
      urlPrefix = "https://capnproto.org";
      downloadFile = "capnproto-c++-1.3.0.tar.gz";
      file = "capnproto-cxx-1.3.0.tar.gz";
      sha256 = "098f824a495a1a837d56ae17e07b3f721ac86f8dbaf58896a389923458522108";
    };

    # --- Qt GUI depends (for bitcoin-qt / bitcoin-gui) ---
    # Versions/hashes mirror bitcoin/depends/packages/*.mk + qt_details.mk.
    qtbase = {
      urlPrefix = "https://download.qt.io/archive/qt/6.8/6.8.3/submodules";
      file = "qtbase-everywhere-src-6.8.3.tar.xz";
      sha256 = "56001b905601bb9023d399f3ba780d7fa940f3e4861e496a7c490331f49e0b80";
    };
    qttranslations = {
      urlPrefix = "https://download.qt.io/archive/qt/6.8/6.8.3/submodules";
      file = "qttranslations-everywhere-src-6.8.3.tar.xz";
      sha256 = "c3c61d79c3d8fe316a20b3617c64673ce5b5519b2e45535f49bee313152fa531";
    };
    qttools = {
      urlPrefix = "https://download.qt.io/archive/qt/6.8/6.8.3/submodules";
      file = "qttools-everywhere-src-6.8.3.tar.xz";
      sha256 = "02a4e219248b94f1333df843d25763f35251c1074cdc4fb5bda67d340f8c8b3a";
    };
    # Qt's top-level cmake files are fetched individually from the qt5 repo
    # and staged with a "-<version>" suffix (see qt.mk fetch_file calls).
    qt-top-cmakelists = {
      urlPrefix = "https://raw.githubusercontent.com/qt/qt5/refs/heads/6.8.3";
      downloadFile = "CMakeLists.txt";
      file = "CMakeLists.txt-6.8.3";
      sha256 = "54e9a4e554da37792446dda4f52bc308407b01a34bcc3afbad58e4e0f71fac9b";
    };
    qt-top-ecmoptionaladdsubdirectory = {
      urlPrefix = "https://raw.githubusercontent.com/qt/qt5/refs/heads/6.8.3/cmake";
      downloadFile = "ECMOptionalAddSubdirectory.cmake";
      file = "ECMOptionalAddSubdirectory.cmake-6.8.3";
      sha256 = "97ee8bbfcb0a4bdcc6c1af77e467a1da0c5b386c42be2aa97d840247af5f6f70";
    };
    qt-top-qttoplevelhelpers = {
      urlPrefix = "https://raw.githubusercontent.com/qt/qt5/refs/heads/6.8.3/cmake";
      downloadFile = "QtTopLevelHelpers.cmake";
      file = "QtTopLevelHelpers.cmake-6.8.3";
      sha256 = "e11581b2101a6836ca991817d43d49e1f6016e4e672bbc3523eaa8b3eb3b64c2";
    };
    expat = {
      urlPrefix = "https://github.com/libexpat/libexpat/releases/download/R_2_7_3";
      file = "expat-2.7.3.tar.gz";
      sha256 = "821ac9710d2c073eaf13e1b1895a9c9aa66c1157a99635c639fbff65cdbdd732";
    };
    libxcb = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "libxcb-1.17.0.tar.gz";
      sha256 = "2c69287424c9e2128cb47ffe92171e10417041ec2963bceafb65cb3fcf8f0b85";
    };
    xcb_proto = {
      urlPrefix = "https://xorg.freedesktop.org/archive/individual/proto";
      file = "xcb-proto-1.17.0.tar.gz";
      sha256 = "392d3c9690f8c8202a68fdb89c16fd55159ab8d65000a6da213f4a1576e97a16";
    };
    libXau = {
      urlPrefix = "https://xorg.freedesktop.org/releases/individual/lib";
      file = "libXau-1.0.12.tar.gz";
      sha256 = "2402dd938da4d0a332349ab3d3586606175e19cb32cb9fe013c19f1dc922dcee";
    };
    xproto = {
      urlPrefix = "https://xorg.freedesktop.org/releases/individual/proto";
      file = "xproto-7.0.31.tar.gz";
      sha256 = "6d755eaae27b45c5cc75529a12855fed5de5969b367ed05003944cf901ed43c7";
    };
    freetype = {
      urlPrefix = "https://download.savannah.gnu.org/releases/freetype";
      file = "freetype-2.11.1.tar.gz";
      sha256 = "f8db94d307e9c54961b39a1cc799a67d46681480696ed72ecf78d4473770f09b";
    };
    fontconfig = {
      urlPrefix = "https://www.freedesktop.org/software/fontconfig/release";
      file = "fontconfig-2.12.6.tar.gz";
      sha256 = "064b9ebf060c9e77011733ac9dc0e2ce92870b574cca2405e11f5353a683c334";
    };
    libxkbcommon = {
      urlPrefix = "https://xkbcommon.org/download";
      file = "libxkbcommon-0.8.4.tar.xz";
      sha256 = "60ddcff932b7fd352752d51a5c4f04f3d0403230a584df9a2e0d5ed87c486c8b";
    };
    libxcb_util = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-0.4.1.tar.gz";
      sha256 = "21c6e720162858f15fe686cef833cf96a3e2a79875f84007d76f6d00417f593a";
    };
    libxcb_util_cursor = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-cursor-0.1.6.tar.gz";
      sha256 = "eae38b2dfc5c529a886e507ef576b12d2a20aa1f149608e4853af760f31be60b";
    };
    libxcb_util_render = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-renderutil-0.3.10.tar.gz";
      sha256 = "e04143c48e1644c5e074243fa293d88f99005b3c50d1d54358954404e635128a";
    };
    libxcb_util_keysyms = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-keysyms-0.4.1.tar.gz";
      sha256 = "1fa21c0cea3060caee7612b6577c1730da470b88cbdf846fa4e3e0ff78948e54";
    };
    libxcb_util_image = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-image-0.4.1.tar.gz";
      sha256 = "0ebd4cf809043fdeb4f980d58cdcf2b527035018924f8c14da76d1c81001293b";
    };
    libxcb_util_wm = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-wm-0.4.2.tar.gz";
      sha256 = "dcecaaa535802fd57c84cceeff50c64efe7f2326bf752e16d2b77945649c8cd7";
    };
    qrencode = {
      urlPrefix = "https://fukuchi.org/works/qrencode";
      file = "qrencode-4.1.1.tar.gz";
      sha256 = "da448ed4f52aba6bcb0cd48cac0dd51b8692bccc4cd127431402fca6f8171e8e";
    };

  };

  # copies the 'dependsSources.file' into the depends/sources dir for each depends
  cpDependsSources = lib.attrsets.mapAttrsToList (_: value:
    "cp ${mkFetchSource value} ${dependsDir}/sources/${value.file}\n"
    ) dependsSources;

in
gcc14Stdenv.mkDerivation (rec {
  name = "bitcoin-${version}-depends";
  pname = "bitcoin-depends";

  srcs = [
    (fetchurl { inherit url sha256; }) # Bitcoin Core
  ];

  postUnpack = ''
    # Move the depends sources to the depends dir.
    # This let's us avoid downloading them during the no-internet build phase.
    mkdir ${dependsDir}/sources

    ${lib.concatStringsSep "\n" cpDependsSources}

    # Drop libzmq's TIPC sources so our archive matches GUIX's. GUIX's
    # cross-compile skips the runtime TIPC check (which is gated on
    # `if(NOT CMAKE_CROSSCOMPILING)`); a native build runs the check,
    # finds TIPC, and pulls 3 extra .o files into libzmq.a. We patch
    # ZMQ_HAVE_TIPC=FALSE early in libzmq's CMakeLists. See
    # patches/zeromq-disable-tipc.patch.
    cp ${../patches/zeromq-disable-tipc.patch} \
      ${dependsDir}/patches/zeromq/zeromq-disable-tipc.patch
    # Wire the new patch into zeromq's `preprocess_cmds` after the
    # existing no_librt.patch invocation (which is the last patch in
    # the chain and needs a `&& \` continuation added).
    sed -i 's|^  patch -p1 < \$(\$(package)_patch_dir)/no_librt\.patch$|  patch -p1 < $($(package)_patch_dir)/no_librt.patch \&\& \\\n  patch -p1 < $($(package)_patch_dir)/zeromq-disable-tipc.patch|' \
      ${dependsDir}/packages/zeromq.mk
    # Register the patch with $(package)_patches so the build captures
    # its hash for caching / build-id computation.
    sed -i '/^\$(package)_patches += no_librt\.patch$/a\$(package)_patches += zeromq-disable-tipc.patch' \
      ${dependsDir}/packages/zeromq.mk

    # Force ZMQ_CACHELINE_SIZE = 64 unconditionally. libzmq's
    # CMakeLists.txt detects it at configure time via
    # `getconf LEVEL1_DCACHE_LINESIZE` (which runs on the build host).
    # In our nix sandbox the aarch64 cross build of depends had this
    # come back as something other than 64, so command_t and other
    # `__attribute__((aligned(ZMQ_CACHELINE_SIZE)))` types ended up
    # 32-byte aligned instead of 64. That alignment difference reached
    # gcc's register-allocator cost model for `std::_Rb_tree<endpoint_t>`
    # instantiations in 8 of 101 libzmq objects (ctx.cpp.o,
    # io_thread.cpp.o, mailbox.cpp.o, mailbox_safe.cpp.o, object.cpp.o,
    # pipe.cpp.o, reaper.cpp.o, socket_base.cpp.o) — different stack-
    # frame size (`sub sp, sp, #0xf0` vs upstream's `#0x110` in
    # `connect_inproc_sockets`), same function size. The 5 aarch64
    # binaries that statically link libzmq (bitcoind, bitcoin-qt,
    # bitcoin-gui, bitcoin-node, test_bitcoin) all diverged from
    # upstream as a result; the other 5 CLI tools matched.
    # GUIX's container has /sys mounted and getconf returns 64 there,
    # so they get the right value; forcing 64 explicitly matches that
    # outcome on every host, and verified byte-equivalent on x86_64
    # (where the detection happened to return 64 anyway).
    cp ${../patches/zeromq-force-cacheline-64.patch} \
      ${dependsDir}/patches/zeromq/zeromq-force-cacheline-64.patch
    sed -i 's|^  patch -p1 < \$(\$(package)_patch_dir)/zeromq-disable-tipc\.patch$|& \&\& \\\n  patch -p1 < $($(package)_patch_dir)/zeromq-force-cacheline-64.patch|' \
      ${dependsDir}/packages/zeromq.mk
    sed -i '/^\$(package)_patches += zeromq-disable-tipc\.patch$/a\$(package)_patches += zeromq-force-cacheline-64.patch' \
      ${dependsDir}/packages/zeromq.mk

    # fontconfig's configure detects freetype via pkg-config ("FREETYPE
    # yes"), but in our Nix build env the resulting FREETYPE_CFLAGS don't
    # reach the compile, so fcfreetype.c fails to find <ft2build.h>. Add the
    # depends freetype include dir to fontconfig's cflags explicitly.
    sed -i 's|^  \$(package)_cflags += -Wno-implicit-function-declaration$|&\n  $(package)_cflags += -I$(host_prefix)/include/freetype2|' \
      ${dependsDir}/packages/fontconfig.mk

    # Match GUIX's depends prefix (/bitcoin/depends/${hostTriple}) in
    # the runtime paths that Qt and libxkbcommon bake into their static
    # libs (and that get linked into bitcoin-qt / bitcoin-gui): Qt's
    # qt_prfxpath + icon search dirs, and libxkbcommon's xkb config root.
    # Our build prefix is /build/bitcoin-<ver>/depends/... (the Nix build
    # dir; we can't build at /bitcoin — the sandbox root is read-only).
    #
    # For Qt we change only -prefix (CMAKE_INSTALL_PREFIX), which is what
    # all of Qt's baked runtime paths derive from. We deliberately do NOT
    # add -extprefix: setting CMAKE_STAGING_PREFIX makes Qt's icon/data
    # search paths use the staging (physical) prefix instead of the install
    # prefix, which would leave /build in the binary. Physical relocation
    # to host_prefix is already handled by qt.mk's
    # `cmake --install --prefix $(staging_prefix_dir)` (line ~302), so the
    # files still land where the depends framework expects.
    #
    # The depends postFixup then rewrites the GUIX prefix back to $out in
    # the *.cmake/*.pc files so the bitcoind build still finds Qt; the
    # baked runtime strings in the .a libraries keep the GUIX prefix,
    # matching upstream's bitcoin-qt / bitcoin-gui.
    sed -i 's|-prefix \$(host_prefix)$|-prefix /bitcoin/depends/${hostTriple}|' \
      ${dependsDir}/packages/qt.mk
    sed -i 's|^\$(package)_config_opts += --disable-shared --disable-docs$|&\n$(package)_config_opts += --with-xkb-config-root=/bitcoin/depends/${hostTriple}/share/X11/xkb|' \
      ${dependsDir}/packages/libxkbcommon.mk

    # xcb-util-cursor bakes the XCURSOR theme search path from its datadir
    # (~/.local/share/icons:~/.icons:$datadir/icons:$datadir/pixmaps) into
    # libxcb-cursor.a, which is linked into bitcoin-qt / bitcoin-gui. Pin it
    # to GUIX's prefix via --with-cursorpath (independent of our build-time
    # datadir) so the baked string matches upstream.
    sed -i 's|^\$(package)_config_opts += --disable-dependency-tracking --enable-option-checking$|&\n$(package)_config_opts += --with-cursorpath=~/.local/share/icons:~/.icons:/bitcoin/depends/${hostTriple}/share/icons:/bitcoin/depends/${hostTriple}/share/pixmaps|' \
      ${dependsDir}/packages/libxcb_util_cursor.mk
  '';

  sourceRoot = dependsDir;

  patches = [
    # Re-add the `test -f source/...` short-circuit removed in upstream
    # 46135d90ea9. Without it, the depends Makefile always tries to curl,
    # which fails in Nix's sandboxed (no-network) build environment.
    ../patches/depends-funcs-test-source-exists.patch
  ];

  # When cross-compiling, crossCC provides the `<host>-gcc`/`<host>-g++`
  # (etc.) that the depends Makefile invokes for HOST packages; the native
  # `gcc`/`g++` from the build stdenv stay the BUILD compiler for the
  # native helper tools (native_capnp, mpgen, …).
  nativeBuildInputs = [ pkg-config ] ++ crossInputs;
  buildInputs = [
    python3 libtool autoconf automake cmake which bison flex gperf
  ];

  # The depends build invokes its own cmake configure commands; don't let
  # nixpkgs' cmake setup-hook run a top-level configure.
  dontUseCmakeConfigure = true;

  # Build the full depends tree including Qt (for bitcoin-qt / bitcoin-gui).
  # Multiprocess IPC (capnp + libmultiprocess) is built unconditionally.
  # HOST=x86_64-linux-gnu makes depends mark the build as a "cross-compile"
  # (host != build, where BUILD defaults to our native x86_64-pc-linux-gnu).
  # This matches GUIX, which builds bitcoin via make-bitcoin-cross-toolchain
  # with HOST=x86_64-linux-gnu. Knock-on effects: depends_crosscompiling=TRUE
  # is baked into the generated toolchain.cmake, which sets CMAKE_SYSTEM_NAME=
  # Linux + CMAKE_CROSSCOMPILING=TRUE downstream. This skips runtime
  # try_run checks (zmq_check_*, secp256k1's Valgrind detection, etc.) so
  # all the resulting depends archives and the secp256k1 region in the
  # final bitcoind match upstream's GUIX-built binary byte-for-byte.
  makeFlags = [ "HOST=${hostTriple}" ]
    ++ lib.optionals (!buildQt) [ "NO_QT=1" ]
    # darwin: hosts/darwin.mk derives OSX_SDK from $(SDK_PATH); the
    # depends Makefile errors out early if the extracted SDK dir is
    # missing. GUIX mounts it at depends/SDKs (see guix-build); we point
    # SDK_PATH at the extracted-SDK store path instead.
    ++ lib.optionals isDarwin [ "SDK_PATH=${darwinSdk}" ];

  # Override the nixpkgs gcc-wrapper's `-fno-omit-frame-pointer
  # -mno-omit-leaf-frame-pointer` (set in cc-cflags-before) so depends
  # compile WITHOUT frame pointers — matching upstream's behavior with
  # the default -O2. Frame pointers add ~12 bytes per function (push
  # %rbp; mov %rsp,%rbp; leave) which accumulates significantly across
  # 50k functions in the final binary.
  #
  # `-pipe` matches GUIX's depends compile commands (see
  # `v31-guix-build.log` line 18550 for sqlite). It just changes IPC
  # between gcc stages from temp files to pipes — shouldn't affect
  # codegen, but included for compile-command parity.
  # aarch64 keeps the non-leaf frame pointer at -O2 (unlike x86_64, which
  # omits it). So for aarch64 we only omit the LEAF frame pointer and let
  # the wrapper's -fno-omit-frame-pointer keep the non-leaf one — matching
  # upstream's bare -O2. x86_64 omits both (its -O2 default). See the
  # frame-pointer note in aarch64-linux-gnu/release.nix. riscv64/armhf/powerpc64
  # also omit the frame pointer at -O2, but have no leaf/non-leaf split —
  # -momit-leaf-frame-pointer is an x86/aarch64-only option — so they get
  # only -fomit-frame-pointer (overriding the wrapper's injection).
  env = {
    NIX_CFLAGS_COMPILE =
      (if lib.hasPrefix "aarch64" hostTriple then "-momit-leaf-frame-pointer"
       else if lib.hasPrefix "x86_64" hostTriple then "-fomit-frame-pointer -momit-leaf-frame-pointer"
       else "-fomit-frame-pointer")
      + " -pipe";
  } // lib.optionalAttrs isDarwin {
    # GUIX build.sh:80 exports LIBRARY_PATH=$NATIVE_GCC/lib for the whole
    # darwin DEPENDS build ("Required for native packages"; build.sh
    # unsets it again before the bitcoin build). NATIVE_GCC is GUIX's
    # gcc-toolchain — a union of gcc AND glibc (commencement.scm
    # make-gcc-toolchain), so its lib/ contains glibc's ASCII linker
    # scripts (libc.so = "GROUP(...)"). clang forwards LIBRARY_PATH
    # entries to the TARGET link, where ld64.lld chokes on the ELF/ASCII
    # libc.so ("unhandled file type") — which makes capnp's
    # check_library_exists(c makecontext …) FAIL in GUIX's container and
    # turns kj fibers OFF (KJ_USE_FIBERS=0). Without this, our `-lc`
    # check resolves against the SDK's libc.tbd, fibers come out ON, and
    # bitcoin-node/bitcoin-gui/test_bitcoin gain ~4.4 KB of fiber code +
    # getcontext/setcontext/makecontext/mprotect imports that upstream's
    # binaries don't have (verified). Mirror the env as ONE union dir
    # like GUIX's (see darwinLibraryPathDir above for why the raw
    # gcc/glibc lib dirs won't do).
    LIBRARY_PATH = "${darwinLibraryPathDir}/lib";
  } // lib.optionalAttrs isMingw {
    # build.sh:81 — same LIBRARY_PATH export for mingw native packages
    # (full gcc+glibc union; see nativeLibraryPathDir).
    LIBRARY_PATH = "${nativeLibraryPathDir}/lib";
  };

  # Disable nixpkgs hardenings that GUIX's toolchain doesn't apply to
  # depends compiles:
  #
  # - zerocallusedregs: -fzero-call-used-regs=used-gpr (register zeroing).
  # - strictoverflow: -fno-strict-overflow.
  # - stackprotector: -fstack-protector-strong with --param
  #   ssp-buffer-size=4. Our gcc still defaults to strong via
  #   --enable-default-ssp=yes.
  # - stackclashprotection: -fstack-clash-protection. Bitcoin's CMake
  #   adds this for `core_interface` targets only; depends archives in
  #   GUIX don't get it (GUIX gcc doesn't enable it by default for the
  #   depends build).
  # - fortify / fortify3: -D_FORTIFY_SOURCE={2,3}. nixpkgs defaults to
  #   adding -D_FORTIFY_SOURCE=3 to every depends compile, but GUIX's
  #   HOST_CFLAGS for depends is just `-O2 -g` + prefix-maps — no
  #   FORTIFY at all. The replacement of libc calls with their __*_chk
  #   variants adds code size at every call site, contributing to our
  #   .text bloat. (Bitcoin's own code separately enables FORTIFY=3
  #   via its CMakeLists.txt, so depends-only disabling preserves
  #   that for the main link.)
  # - format: -Wformat -Wformat-security (warning only; safe to drop).
  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection"
    "fortify" "fortify3" "format"
    # New nixos-26.05 cc-wrapper defaults GUIX doesn't apply (see x86_64-linux-gnu/release.nix).
    # strictflexarrays1 = -fstrict-flex-arrays=1 (codegen-affecting; GUIX gcc
    # defaults to =0). libcxxhardeningfast is libc++-only (no-op for us).
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  doCheck = false;
  enableParallelBuilding = true;

  postFixup = ''
    # HOST=x86_64-linux-gnu (set in makeFlags) makes depends install
    # under x86_64-linux-gnu/ — move it to $out.
    mv ${hostTriple}/* $out/

    # The depends build hardcodes its absolute build-time staging path
    # (e.g. /build/.../depends/x86_64-linux-gnu) into CMake config
    # files like libevent's LibeventTargets-static.cmake. Rewrite
    # those to point at $out so consumers (the bitcoind build) can
    # find the installed libraries and headers.
    # Rewrite both our build-time prefix and the GUIX prefix that Qt bakes
    # (via -prefix above) to $out, so the bitcoind build finds the libs.
    # Only *.cmake/*.pc are touched; the baked runtime strings inside the
    # .a libraries keep the GUIX prefix (matching upstream's bitcoin-qt).
    find $out -type f \( -name '*.cmake' -o -name '*.pc' \) \
      -exec sed -i \
        -e "s|/build/bitcoin-${version}/depends/${hostTriple}|$out|g" \
        -e "s|/bitcoin/depends/${hostTriple}|$out|g" {} +
  '';
} // lib.optionalAttrs (crossInputs != [ ]) {
  # When cross-compiling, unset the Nix-exported well-known tool vars so
  # depends uses the <hostTriple>- cross toolchain for HOST packages (see
  # crossInputs). The native `gcc` (default_build_CC) still builds the
  # native helper tools. Added conditionally so the native x86_64
  # derivation is byte-identical (no stray empty preBuild).
  preBuild = ''
    unset CC CXX AR RANLIB NM STRIP OBJCOPY OBJDUMP
  '';
} // lib.optionalAttrs (crossInputs != [ ] && lib.hasPrefix "x86_64" hostTriple && !isDarwin && !isMingw) {
  # x86_64-target cross builds only (on a non-x86 build machine the make
  # conditional below is false and the sed is a harmless no-op):
  # hosts/linux.mk special-cases an x86 build machine —
  # `ifeq (86,$(findstring 86,$(build_arch)))` forces ALL the x86_64 host
  # tools to the native unprefixed ones (CC="gcc -m64", AR=ar, RANLIB=
  # ranlib, NM=nm, STRIP=strip). In GUIX's container that native gcc IS the
  # pinned 2.31-glibc toolchain, but here it would be the plain build
  # stdenv (glibc 2.42) — host packages then carry glibc-2.38+ symbol refs
  # (__isoc23_strtoul in capnp's libkj) that can't link against our 2.31.
  # Disable the special-case so the `else` branch applies: CC=
  # $(default_host_CC) -m64 = x86_64-linux-gnu-gcc -m64 and prefixed
  # binutils — i.e. exactly what depends does for an x86_64-linux-gnu host
  # on any NON-x86 build machine, and what it already does for the aarch64
  # cross build. A separate optionalAttrs (not optionalString inside
  # postUnpack) so the native/aarch64 derivations stay byte-identical.
  postPatch = ''
    sed -i 's|ifeq (86,$(findstring 86,$(build_arch)))|ifeq (x86-build-machine-special-case,disabled-for-cross-to-self)|' \
      hosts/linux.mk
    grep -q 'disabled-for-cross-to-self' hosts/linux.mk || { echo "linux.mk sed failed"; exit 1; }

    # Preseed the Qt configure check results that come out differently in
    # the Nix sandbox than in GUIX's container, to upstream's values:
    # HAVE_GETTIME/HAVE_SHM_OPEN_SHM_UNLINK make FindWrapRt succeed (the
    # WrapRt::WrapRt target must exist for the posix ipc features), and
    # TEST_posix_shm/TEST_posix_sem turn on
    # QT_FEATURE_posix_shm/posix_sem like upstream. The effect on the
    # output is exactly two feature-gated-to-EMPTY objects
    # (qsharedmemory_posix.cpp, qsystemsemaphore_posix.cpp — the selected
    # ipc backend is sysv on both sides, and the stripped runtime binaries
    # byte-matched all along): they contribute the two STT_FILE symtab
    # entries that were the final 96 bytes between our
    # bitcoin-qt.dbg/bitcoin-gui.dbg and upstream's.
    sed -i 's|-DCMAKE_PREFIX_PATH=$(host_prefix)$|-DCMAKE_PREFIX_PATH=$(host_prefix) -DHAVE_GETTIME=ON -DHAVE_SHM_OPEN_SHM_UNLINK=ON -DTEST_posix_shm=ON -DTEST_posix_sem=ON|' \
      packages/qt.mk
    grep -q 'TEST_posix_shm' packages/qt.mk || { echo "qt.mk posix preseed sed failed"; exit 1; }
  '';
} // lib.optionalAttrs isDarwin {
  # darwin: hide the BUILD machine's glibc lib dir from CMake's find
  # commands in HOST packages. find_library derives search PREFIXES from
  # every $PATH entry (strip /bin, probe <prefix>/lib) — in the Nix env
  # that reaches the stdenv glibc, so e.g. FindWrapRt's
  # find_library(LIBRT rt) returns the ELF librt.so, which then poisons
  # the Mach-O try_compile link ("ld64.lld: error: …librt.so: unhandled
  # file type") and flips Qt's WrapRt/clock_gettime checks to FAILED
  # (configure aborts: "Target Core links to WrapRt::WrapRt but the
  # target was not found"); zeromq's find_library(RT_LIBRARY rt) would
  # likewise leak "-lrt" into zmq.pc. In GUIX's container the same
  # probing finds NO matching unversioned librt.so (their find comes out
  # NOTFOUND — upstream's build succeeding proves it: WrapRt::WrapRt
  # exists there only as an EMPTY interface target), so ignoring the one
  # ELF dir that satisfies these lookups is outcome-identical.
  # CMAKE_SYSTEM_IGNORE_PATH (not CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_
  # PATH=OFF, which also breaks find_program's make/compiler lookup; not
  # -DLIBRT=LIBRT-NOTFOUND, which find_library re-runs on -NOTFOUND).
  # Two seds: funcs.mk's host-package cmake invocation (zeromq, capnp,
  # boost, libevent, qrencode) and qt.mk's own config.opt mechanism.
  postPatch = ''
    sed -i 's|^\$(1)_cmake += -DCMAKE_SYSTEM_NAME=\$(\$(host_os)_cmake_system_name)$|&\n$(1)_cmake += -DCMAKE_SYSTEM_IGNORE_PATH=${gcc14Stdenv.cc.libc}/lib|' \
      funcs.mk
    grep -q 'CMAKE_SYSTEM_IGNORE_PATH' funcs.mk || { echo "funcs.mk ignore-path sed failed"; exit 1; }
    sed -i 's|^\$(package)_cmake_opts += -DQT_NO_APPLE_SDK_MAX_VERSION_CHECK=ON$|&\n$(package)_cmake_opts += -DCMAKE_SYSTEM_IGNORE_PATH=${gcc14Stdenv.cc.libc}/lib|' \
      packages/qt.mk
    grep -q 'CMAKE_SYSTEM_IGNORE_PATH' packages/qt.mk || { echo "qt.mk ignore-path sed failed"; exit 1; }

    # qtbase_plugins_cocoa.patch appends, to qtbase's cocoa plugin
    # CMakeLists.txt:
    #   if(CMAKE_VERSION VERSION_LESS "3.25" AND NOT QT_FEATURE_sessionmanager)
    #       set_target_properties(QCocoaIntegrationPlugin PROPERTIES
    #           DISABLE_PRECOMPILE_HEADERS ON)
    #       endif()
    # bitcoin's qt.mk disables sessionmanager UNCONDITIONALLY
    # (-no-feature-sessionmanager is in the shared $(package)_config_opts,
    # not just _linux/_darwin), so QT_FEATURE_sessionmanager is OFF on every
    # host and this guard reduces to CMAKE_VERSION VERSION_LESS "3.25". GUIX
    # builds with cmake-minimal 3.24.2 (manifest.scm "Build tools" — the one
    # cmake used for every host's native_qt/qt), so the guard fires there:
    # QCocoaIntegrationPlugin (qnsview.mm + the rest of libqcocoa.a) is built
    # WITHOUT a precompiled header. nixpkgs' cmake is >=3.25, so the guard
    # never fires for us and PCH stays at Qt's default (enabled). PCH usage
    # doesn't change qnsview.mm's emitted .text/.data (verified
    # byte-identical to upstream) but shifts clang's internal
    # GCC_except_table/_OBJC_SELECTOR_REFERENCES_/_OBJC_CLASSLIST_REFERENCES_
    # counters by a small constant — the sole remaining divergence (and the
    # only reason bitcoin-qt/bitcoin-gui's LC_UUID, an xxh3 of the unstripped
    # image, didn't match). Drop the version guard so PCH is disabled
    # unconditionally for this target, like GUIX's cmake 3.24.2 does.
    cat >> packages/qt.mk <<'EOF'
$(package)_preprocess_cmds += && sed -i 's/CMAKE_VERSION VERSION_LESS "3.25" AND //' qtbase/src/plugins/platforms/cocoa/CMakeLists.txt
EOF
    grep -q 'qtbase/src/plugins/platforms/cocoa/CMakeLists.txt' packages/qt.mk || { echo "qt.mk cocoa PCH sed failed"; exit 1; }
  '';
} // lib.optionalAttrs isMingw {
  # mingw: same BUILD-glibc find_library leak as darwin. In the Nix sandbox
  # CMake's find_library derives search prefixes from $PATH and reaches the
  # stdenv glibc, so Qt's FindWrapRt finds the ELF librt.so and tries to
  # build a WrapRt::WrapRt target around it — which then fails for the
  # Windows target ("Target Core links to WrapRt::WrapRt but the target was
  # not found"), aborting Qt configure. In GUIX's container the same probe
  # finds NO unversioned librt.so (glibc 2.39 ships none), so WrapRt is an
  # empty interface target and Core links fine. Hide the one ELF dir that
  # satisfies the lookup (CMAKE_SYSTEM_IGNORE_PATH) — outcome-identical, the
  # same fix as the darwin block. NO posix-shm/sem preseed: Windows Qt uses
  # the win32 shared-memory backend, so QT_FEATURE_posix_shm/sem stay OFF
  # like upstream.
  postPatch = ''
    sed -i 's|^\$(1)_cmake += -DCMAKE_SYSTEM_NAME=\$(\$(host_os)_cmake_system_name)$|&\n$(1)_cmake += -DCMAKE_SYSTEM_IGNORE_PATH=${gcc14Stdenv.cc.libc}/lib|' \
      funcs.mk
    grep -q 'CMAKE_SYSTEM_IGNORE_PATH' funcs.mk || { echo "funcs.mk ignore-path sed failed"; exit 1; }
    sed -i 's|^\$(package)_cmake_opts += -DCMAKE_SYSTEM_NAME=\$(\$(host_os)_cmake_system_name)$|&\n$(package)_cmake_opts += -DCMAKE_SYSTEM_IGNORE_PATH=${gcc14Stdenv.cc.libc}/lib|' \
      packages/qt.mk
    grep -q 'CMAKE_SYSTEM_IGNORE_PATH' packages/qt.mk || { echo "qt.mk mingw ignore-path sed failed"; exit 1; }
  '';
} // lib.optionalAttrs (crossInputs != [ ] && !lib.hasPrefix "x86_64" hostTriple && !isDarwin) {
  # Non-x86 LINUX cross builds (aarch64/riscv64/armhf/powerpc64): same Qt posix
  # ipc preseed as the x86_64 block above (the sandbox-vs-GUIX-container
  # configure-check divergence is host-independent; the two
  # feature-gated-to-EMPTY objects contribute STT_FILE symtab entries to
  # bitcoin-qt.dbg/bitcoin-gui.dbg). The hosts/linux.mk special-case does
  # NOT apply here (it's x86-build-machine + x86-host only), so no
  # linux.mk sed. A separate optionalAttrs block so the x86_64 depends
  # derivation stays byte-identical.
  postPatch = ''
    sed -i 's|-DCMAKE_PREFIX_PATH=$(host_prefix)$|-DCMAKE_PREFIX_PATH=$(host_prefix) -DHAVE_GETTIME=ON -DHAVE_SHM_OPEN_SHM_UNLINK=ON -DTEST_posix_shm=ON -DTEST_posix_sem=ON|' \
      packages/qt.mk
    grep -q 'TEST_posix_shm' packages/qt.mk || { echo "qt.mk posix preseed sed failed"; exit 1; }
  '';
})
