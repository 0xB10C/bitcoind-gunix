{ lib
, gcc10Stdenv # The GUIX builds are using GCC 10.3.0
, fetchurl
# build-inputs
, pkg-config
, python3
, bison
, libtool
, autoconf
, automake
, which # Qt
, perl # Qt
#
, version
, url
, sha256
}:

let
  dependsDir = "bitcoin-${version}/depends";

  mkFetchSource = {urlPrefix, file, sha256}:
    fetchurl {
      url = "${urlPrefix}/${file}" ;
      inherit sha256;
    };

  # Nix builds are pure. We can't access the Internet during builds - so we
  # make the depends sources avaliable beforehand.
  dependsSources = {
    boost = {
      urlPrefix = "https://boostorg.jfrog.io/artifactory/main/release/1.77.0/source";
      file = "boost_1_77_0.tar.bz2";
      sha256 = "fc9f85fc030e233142908241af7a846e60630aa7388de9a5fafb1f3a26840854";
    };
    libevent = {
      urlPrefix = "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable";
      file = "libevent-2.1.12-stable.tar.gz";
      sha256 = "92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb";
    };
    freetype = {
      urlPrefix = "https://download.savannah.gnu.org/releases/freetype";
      file = "freetype-2.11.0.tar.xz";
      sha256 = "8bee39bd3968c4804b70614a0a3ad597299ad0e824bc8aad5ce8aaf48067bde7";
    };
    expat = {
      urlPrefix = "https://github.com/libexpat/libexpat/releases/download/R_2_4_1";
      file = "expat-2.4.8.tar.xz";
      sha256 = "f79b8f904b749e3e0d20afeadecf8249c55b2e32d4ebb089ae378df479dcaf25";
    };
    fontconfig = {
      urlPrefix = "https://www.freedesktop.org/software/fontconfig/release";
      file = "fontconfig-2.12.6.tar.bz2";
      sha256 = "cf0c30807d08f6a28ab46c61b8dbd55c97d2f292cf88f3a07d3384687f31f017";
    };
    xcb-proto = {
      urlPrefix = "https://xorg.freedesktop.org/archive/individual/proto";
      file = "xcb-proto-1.14.1.tar.xz";
      sha256 = "f04add9a972ac334ea11d9d7eb4fc7f8883835da3e4859c9afa971efdf57fcc3";
    };
    systemtap = {
      urlPrefix = "https://sourceware.org/ftp/systemtap/releases/";
      file = "systemtap-4.7.tar.gz";
      sha256 = "43a0a3db91aa4d41e28015b39a65e62059551f3cc7377ebf3a3a5ca7339e7b1f";
    };
    xproto = {
      urlPrefix = "https://xorg.freedesktop.org/releases/individual/proto";
      file = "xproto-7.0.31.tar.bz2";
      sha256 = "c6f9747da0bd3a95f86b17fb8dd5e717c8f3ab7f0ece3ba1b247899ec1ef7747";
    };
    libxau = {
      urlPrefix = "https://xorg.freedesktop.org/releases/individual/lib/";
      file = "libXau-1.0.9.tar.bz2";
      sha256 = "ccf8cbf0dbf676faa2ea0a6d64bcc3b6746064722b606c8c52917ed00dcb73ec";
    };
    libxcb = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "libxcb-1.14.tar.xz";
      sha256 = "a55ed6db98d43469801262d81dc2572ed124edc3db31059d4e9916eb9f844c34";
    };
    libxcb-util = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-0.4.0.tar.bz2";
      sha256 = "46e49469cb3b594af1d33176cd7565def2be3fa8be4371d62271fabb5eae50e9";
    };
    libxcb-util-render = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-renderutil-0.3.9.tar.bz2";
      sha256 = "c6e97e48fb1286d6394dddb1c1732f00227c70bd1bedb7d1acabefdd340bea5b";
    };
    libxcb-util-image = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-image-0.4.0.tar.bz2";
      sha256 = "2db96a37d78831d643538dd1b595d7d712e04bdccf8896a5e18ce0f398ea2ffc";
    };
    libxcb-util-keysyms = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-keysyms-0.4.0.tar.bz2";
      sha256 = "0ef8490ff1dede52b7de533158547f8b454b241aa3e4dcca369507f66f216dd9";
    };
    libxcb-util-wm = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-wm-0.4.1.tar.bz2";
      sha256 = "28bf8179640eaa89276d2b0f1ce4285103d136be6c98262b6151aaee1d3c2a3f";
    };
    libxkbcommon = {
      urlPrefix = "https://xkbcommon.org/download/";
      file = "libxkbcommon-0.8.4.tar.xz";
      sha256 = "60ddcff932b7fd352752d51a5c4f04f3d0403230a584df9a2e0d5ed87c486c8b";
    };
    qt = {
      urlPrefix = "https://download.qt.io/official_releases/qt/5.15/5.15.2/submodules";
      file = "qtbase-everywhere-src-5.15.2.tar.xz";
      sha256 = "909fad2591ee367993a75d7e2ea50ad4db332f05e1c38dd7a5a274e156a4e0f8";
    };
    qt-translations = {
      urlPrefix = "https://download.qt.io/official_releases/qt/5.15/5.15.2/submodules";
      file = "qttranslations-everywhere-src-5.15.2.tar.xz";
      sha256 = "d5788e86257b21d5323f1efd94376a213e091d1e5e03b45a95dd052b5f570db8";
    };
    qt-tools = {
      urlPrefix = "https://download.qt.io/official_releases/qt/5.15/5.15.2/submodules";
      file = "qttools-everywhere-src-5.15.2.tar.xz";
      sha256 = "c189d0ce1ff7c739db9a3ace52ac3e24cb8fd6dbf234e49f075249b38f43c1cc";
    };
    sqlite = {
      urlPrefix = "https://sqlite.org/2020";
      file = "sqlite-autoconf-3320100.tar.gz";
      sha256 = "486748abfb16abd8af664e3a5f03b228e5f124682b0c942e157644bf6fff7d10";
    };
    zeromq = {
      urlPrefix = "https://github.com/zeromq/libzmq/releases/download/v4.3.4";
      file = "zeromq-4.3.4.tar.gz";
      sha256 = "c593001a89f5a85dd2ddf564805deb860e02471171b3f204944857336295c3e5";
    };
    db48 = {
      urlPrefix = "https://download.oracle.com/berkeley-db";
      file = "db-4.8.30.NC.tar.gz";
      sha256 = "12edc0df75bf9abd7f82f821795bcee50f42cb2e5f76a6a281b85732798364ef";
    };
    miniupnpc = {
      urlPrefix = "https://miniupnp.tuxfamily.org/files/";
      file = "miniupnpc-2.2.2.tar.gz";
      sha256 = "888fb0976ba61518276fe1eda988589c700a3f2a69d71089260d75562afd3687";
    };
    libnatpmp = {
      urlPrefix = "https://github.com/miniupnp/libnatpmp/archive";
      file = "4536032ae32268a45c073a4d5e91bbab4534773a.tar.gz";
      sha256 = "543b460aab26acf91e11d15e17d8798f845304199eea2d76c2f444ec749c5383";
    };
    qrencode = {
      urlPrefix = "https://fukuchi.org/works/qrencode/";
      file = "qrencode-3.4.4.tar.bz2";
      sha256 = "efe5188b1ddbcbf98763b819b146be6a90481aac30cfc8d858ab78a19cde1fa5";
    };

  };

  # copies the 'dependsSources.file' into the depends/sources dir for each depends
  cpDependsSources = lib.attrsets.mapAttrsToList (name: value:
    "cp ${mkFetchSource value} ${dependsDir}/sources/${value.file}\n"
    ) dependsSources;

in
gcc10Stdenv.mkDerivation rec {
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

  patches = [];

  nativeBuildInputs = [ ];
  buildInputs = [
    pkg-config python3 bison libtool autoconf automake
    which perl # Qt
  ];

  # we don't want to download/build/cache the Qt depends
  # makeFlags = [ "NO_QT=1" ];

  doCheck = false;
  enableParallelBuilding = true;

  postFixup = ''
    mv x86_64-pc-linux-gnu/* $out/
  '';
}
