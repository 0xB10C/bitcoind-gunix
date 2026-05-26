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
#
, version
, url
, sha256
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

  };

  # copies the 'dependsSources.file' into the depends/sources dir for each depends
  cpDependsSources = lib.attrsets.mapAttrsToList (name: value:
    "cp ${mkFetchSource value} ${dependsDir}/sources/${value.file}\n"
    ) dependsSources;

in
gcc14Stdenv.mkDerivation rec {
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

    # Drop the three TIPC source files from libzmq so our archive matches
    # GUIX's. GUIX cross-compiles, libzmq's CMakeLists wraps the runtime
    # TIPC check in `if(NOT CMAKE_CROSSCOMPILING)`, and the conditional
    # `if(ZMQ_HAVE_TIPC)` block adds tipc_*.cpp only when the check
    # succeeded. Under cross-compile the check is skipped and the block
    # stays disabled. We build natively, the check runs, and TIPC
    # support is detected — pulling 3 extra .o files into libzmq.a.
    # See patches/zeromq-disable-tipc.patch for the full rationale.
    cp ${./patches/zeromq-disable-tipc.patch} \
      ${dependsDir}/patches/zeromq/zeromq-disable-tipc.patch
    # Append a chained `patch -p1 < ...` line after the existing
    # `no_librt.patch` line in zeromq's `preprocess_cmds`. We have to
    # first add the trailing ` && \` line continuation to the
    # `no_librt.patch` line (it was the last patch and has no
    # continuation), then insert our patch line after it.
    sed -i 's|^  patch -p1 < \$(\$(package)_patch_dir)/no_librt\.patch$|  patch -p1 < $($(package)_patch_dir)/no_librt.patch \&\& \\\n  patch -p1 < $($(package)_patch_dir)/zeromq-disable-tipc.patch|' \
      ${dependsDir}/packages/zeromq.mk
    # Register the patch with $(package)_patches so the build captures
    # its hash for caching/build-id computation.
    sed -i '/^\$(package)_patches += no_librt\.patch$/a\$(package)_patches += zeromq-disable-tipc.patch' \
      ${dependsDir}/packages/zeromq.mk
  '';

  sourceRoot = dependsDir;

  patches = [
    # Re-add the `test -f source/...` short-circuit removed in upstream
    # 46135d90ea9. Without it, the depends Makefile always tries to curl,
    # which fails in Nix's sandboxed (no-network) build environment.
    ./patches/depends-funcs-test-source-exists.patch
  ];

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    python3 libtool autoconf automake cmake which
  ];

  # The depends build invokes its own cmake configure commands; don't let
  # nixpkgs' cmake setup-hook run a top-level configure.
  dontUseCmakeConfigure = true;

  # Skip Bitcoin's GUI for now: don't download/build/cache the Qt depends.
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
  makeFlags = [ "NO_QT=1" "HOST=x86_64-linux-gnu" ];

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
    # under x86_64-linux-gnu/ rather than the native default
    # x86_64-pc-linux-gnu/. Move whichever exists to $out.
    if [ -d x86_64-linux-gnu ]; then
      mv x86_64-linux-gnu/* $out/
      hostdir=x86_64-linux-gnu
    else
      mv x86_64-pc-linux-gnu/* $out/
      hostdir=x86_64-pc-linux-gnu
    fi

    # The depends build hardcodes its absolute build-time staging path
    # (e.g. /build/.../depends/<hostdir>) into CMake config files like
    # libevent's LibeventTargets-static.cmake. Rewrite those to point at
    # $out so consumers (the bitcoind build) can find the installed
    # libraries and headers.
    find $out -type f \( -name '*.cmake' -o -name '*.pc' \) \
      -exec sed -i "s|/build/bitcoin-${version}/depends/$hostdir|$out|g" {} +
  '';
}
