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
# environment-set CC as the host compiler).
, crossInputs ? [ ]
}:

let
  dependsDir = "bitcoin-${version}/depends";

  # `downloadFile` is the name on the remote server (defaults to `file`). It
  # only differs from `file` when the upstream depends Makefile renames the
  # tarball locally (e.g. capnp's `capnproto-c++` -> `capnproto-cxx`).
  mkFetchSource = {urlPrefix, file, sha256, downloadFile ? file}:
    fetchurl {
      url = "${urlPrefix}/${downloadFile}";
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
    cp ${./patches/zeromq-disable-tipc.patch} \
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
    ./patches/depends-funcs-test-source-exists.patch
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
  makeFlags = [ "HOST=${hostTriple}" ] ++ lib.optionals (!buildQt) [ "NO_QT=1" ];

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
  env.NIX_CFLAGS_COMPILE = "-fomit-frame-pointer -momit-leaf-frame-pointer -pipe";

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
})
