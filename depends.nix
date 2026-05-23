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

  mkFetchSource = {urlPrefix, file, sha256}:
    fetchurl {
      url = "${urlPrefix}/${file}" ;
      inherit sha256;
    };

  # Nix builds are pure. We can't access the Internet during builds - so we
  # make the depends sources avaliable beforehand.
  dependsSources = {
    boost = {
      urlPrefix = "https://boostorg.jfrog.io/artifactory/main/release/1.81.0/source";
      file = "boost_1_81_0.tar.bz2";
      sha256 = "71feeed900fbccca04a3b4f2f84a7c217186f28a940ed8b7ed4725986baf99fa";
    };
    libevent = {
      urlPrefix = "https://github.com/libevent/libevent/releases/download/release-2.1.12-stable";
      file = "libevent-2.1.12-stable.tar.gz";
      sha256 = "92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb";
    };
    systemtap = {
      urlPrefix = "https://sourceware.org/ftp/systemtap/releases/";
      file = "systemtap-4.8.tar.gz";
      sha256 = "cbd50a4eba5b261394dc454c12448ddec73e55e6742fda7f508f9fbc1331c223";
    };
    sqlite = {
      urlPrefix = "https://sqlite.org/2020";
      file = "sqlite-autoconf-3380500.tar.gz";
      sha256 = "5af07de982ba658fd91a03170c945f99c971f6955bc79df3266544373e39869c";
    };
    zeromq = {
      urlPrefix = "https://github.com/zeromq/libzmq/releases/download/v4.3.5";
      file = "zeromq-4.3.5.tar.gz";
      sha256 = "6653ef5910f17954861fe72332e68b03ca6e4d9c7160eb3a8de5a5a913bfab43";
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
      file = "07004b97cf691774efebe70404cf22201e4d330d.tar.gz";
      sha256 = "9321953ceb39d07c25463e266e50d0ae7b64676bb3a986d932b18881ed94f1fb";
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

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    python3 libtool autoconf automake
  ];

  # Skip Bitcoin's GUI for now: don't download/build/cache the Qt depends.
  makeFlags = [ "NO_QT=1" ];

  doCheck = false;
  enableParallelBuilding = true;

  postFixup = ''
    mv x86_64-pc-linux-gnu/* $out/
  '';
}
