{ lib
, gcc14Stdenv # The GUIX builds for Bitcoin Core v31.0 use GCC 14.2.0
, fetchurl
# build-inputs
, pkg-config
, python3
, libtool
, autoconf
, automake
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
    python3 libtool autoconf automake
  ];

  # Skip Bitcoin's GUI for now: don't download/build/cache the Qt depends.
  # Multiprocess IPC (capnp + libmultiprocess) is built unconditionally.
  makeFlags = [ "NO_QT=1" ];

  doCheck = false;
  enableParallelBuilding = true;

  postFixup = ''
    mv x86_64-pc-linux-gnu/* $out/
  '';
}
