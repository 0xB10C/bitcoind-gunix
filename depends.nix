{ lib
, stdenv
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
, cmake
, curlMinimal
#
, version
, url
, sha256
}:

let
  dependsDir = "bitcoin-${version}/depends";

  mkFetchSource = {urlPrefix, file, sha256, ...}:
    fetchurl {
      url = "${urlPrefix}/${file}" ;
      inherit sha256;
    };

  qt_version = "6.7.3";
  qt_url_prefix = "https://download.qt.io/archive/qt/${lib.versions.majorMinor qt_version}/${qt_version}/submodules";

  # Nix builds are pure. We can't access the Internet during builds - so we
  # make the depends sources avaliable beforehand.
  dependsSources = {
    boost = {
      urlPrefix = "https://github.com/boostorg/boost/releases/download/boost-1.88.0";
      file = "boost-1.88.0-cmake.tar.gz";
      sha256 = "dcea50f40ba1ecfc448fdf886c0165cf3e525fef2c9e3e080b9804e8117b9694";
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
      file = "fontconfig-2.12.6.tar.gz";
      sha256 = "064b9ebf060c9e77011733ac9dc0e2ce92870b574cca2405e11f5353a683c334";
    };
    xcb-proto = {
      urlPrefix = "https://xorg.freedesktop.org/archive/individual/proto";
      file = "xcb-proto-1.15.2.tar.xz";
      sha256 = "7072beb1f680a2fe3f9e535b797c146d22528990c72f63ddb49d2f350a3653ed";
    };
    systemtap = {
      urlPrefix = "https://sourceware.org/ftp/systemtap/releases/";
      file = "systemtap-4.8.tar.gz";
      sha256 = "cbd50a4eba5b261394dc454c12448ddec73e55e6742fda7f508f9fbc1331c223";
    };
    xproto = {
      urlPrefix = "https://xorg.freedesktop.org/releases/individual/proto";
      file = "xproto-7.0.31.tar.gz";
      sha256 = "6d755eaae27b45c5cc75529a12855fed5de5969b367ed05003944cf901ed43c7";
    };
    libxau = {
      urlPrefix = "https://xorg.freedesktop.org/releases/individual/lib/";
      file = "libXau-1.0.9.tar.gz";
      sha256 = "1f123d8304b082ad63a9e89376400a3b1d4c29e67e3ea07b3f659cccca690eea";
    };
    libxcb = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "libxcb-1.14.tar.xz";
      sha256 = "a55ed6db98d43469801262d81dc2572ed124edc3db31059d4e9916eb9f844c34";
    };
    libxcb-util = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-0.4.0.tar.gz";
      sha256 = "0ed0934e2ef4ddff53fcc70fc64fb16fe766cd41ee00330312e20a985fd927a7";
    };
    libxcb-util-cursor = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-cursor-0.1.5.tar.gz";
      sha256 = "0e9c5446dc6f3beb8af6ebfcc9e27bcc6da6fe2860f7fc07b99144dfa568e93b";
    };
    libxcb-util-render = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-renderutil-0.3.9.tar.gz";
      sha256 = "55eee797e3214fe39d0f3f4d9448cc53cffe06706d108824ea37bb79fcedcad5";
    };
    libxcb-util-image = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-image-0.4.0.tar.gz";
      sha256 = "cb2c86190cf6216260b7357a57d9100811bb6f78c24576a3a5bfef6ad3740a42";
    };
    libxcb-util-keysyms = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-keysyms-0.4.0.tar.gz";
      sha256 = "0807cf078fbe38489a41d755095c58239e1b67299f14460dec2ec811e96caa96";
    };
    libxcb-util-wm = {
      urlPrefix = "https://xcb.freedesktop.org/dist";
      file = "xcb-util-wm-0.4.1.tar.gz";
      sha256 = "038b39c4bdc04a792d62d163ba7908f4bb3373057208c07110be73c1b04b8334";
    };
    libxkbcommon = {
      urlPrefix = "https://xkbcommon.org/download/";
      file = "libxkbcommon-0.8.4.tar.xz";
      sha256 = "60ddcff932b7fd352752d51a5c4f04f3d0403230a584df9a2e0d5ed87c486c8b";
    };
    qt = {
      urlPrefix = qt_url_prefix;
      file = "qtbase-everywhere-src-${qt_version}.tar.xz";
      sha256 = "8ccbb9ab055205ac76632c9eeddd1ed6fc66936fc56afc2ed0fd5d9e23da3097";
    };
    qt-translations = {
      urlPrefix = qt_url_prefix;
      file = "qttranslations-everywhere-src-${qt_version}.tar.xz";
      sha256 = "dcc762acac043b9bb5e4d369b6d6f53e0ecfcf76a408fe0db5f7ef071c9d6dc8";
    };
    qt-tools = {
      urlPrefix = qt_url_prefix;
      file = "qttools-everywhere-src-${qt_version}.tar.xz";
      sha256 = "f03bb7df619cd9ac9dba110e30b7bcab5dd88eb8bdc9cc752563b4367233203f";
    };
    qt-cmakelists = {
      urlPrefix = "https://code.qt.io/cgit/qt/qt5.git/plain";
      file = "CMakeLists.txt?h=${qt_version}";
      name = "CMakeLists.txt-${qt_version}";
      sha256 = "9fb720a633c0c0a21c31fe62a34bf617726fed72480d4064f29ca5d6973d513f";
    };
    qt-cmake = {
      urlPrefix = "https://code.qt.io/cgit/qt/qt5.git/plain/cmake";
      file = "ECMOptionalAddSubdirectory.cmake?h=${qt_version}";
      name = "ECMOptionalAddSubdirectory.cmake-${qt_version}";
      sha256 = "97ee8bbfcb0a4bdcc6c1af77e467a1da0c5b386c42be2aa97d840247af5f6f70";
    };
    qt-cmake-helpers = {
      urlPrefix = "https://code.qt.io/cgit/qt/qt5.git/plain/cmake";
      file = "QtTopLevelHelpers.cmake?h=${qt_version}";
      name = "QtTopLevelHelpers.cmake-${qt_version}";
      sha256 = "5ac2a7159ee27b5b86d26ecff44922e7b8f319aa847b7b5766dc17932fd4a294";
    };
    sqlite = {
      urlPrefix = "https://sqlite.org/2024";
      file = "sqlite-autoconf-3460100.tar.gz";
      sha256 = "67d3fe6d268e6eaddcae3727fce58fcc8e9c53869bdd07a0c61e38ddf2965071";
    };
    zeromq = {
      urlPrefix = "https://github.com/zeromq/libzmq/releases/download/v4.3.5";
      file = "zeromq-4.3.5.tar.gz";
      sha256 = "6653ef5910f17954861fe72332e68b03ca6e4d9c7160eb3a8de5a5a913bfab43";
    };
    qrencode = {
      urlPrefix = "https://fukuchi.org/works/qrencode/";
      file = "qrencode-4.1.1.tar.gz";
      sha256 = "da448ed4f52aba6bcb0cd48cac0dd51b8692bccc4cd127431402fca6f8171e8e";
    };

  };

  # copies the 'dependsSources.file' into the depends/sources dir for each depends
  cpDependsSources = lib.attrsets.mapAttrsToList (name: value:
  let
    fetched = mkFetchSource value;
    targetName = lib.escapeShellArg (value.name or value.file);
  in
    "cp ${fetched} ${dependsDir}/sources/${targetName}"
  ) dependsSources;
in
stdenv.mkDerivation rec {
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
    ./patches/depends-qt-readd-PKG_CONFIG_SYSROOT_DIR-env-var.patch
  ];

  dontUseCmakeConfigure = true;
  nativeBuildInputs = [ pkg-config cmake ];
  buildInputs = [
    python3 bison libtool autoconf automake
    which perl curlMinimal # Qt
  ];

  # we don't want to download/build/cache the Qt depends
  makeFlags = [ "NO_QT=1" ];
  cmakeFlags = [ "-DCMAKE_PREFIX_PATH" "/" ];

  doCheck = false;
  enableParallelBuilding = true;

  postFixup = ''
    mv x86_64-pc-linux-gnu/* $out/
  '';
}
