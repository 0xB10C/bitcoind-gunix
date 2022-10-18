{
  gcc10Stdenv # The GUIX builds are using GCC 10.3.0
, fetchurl
# build-inputs
, pkgconfig
, autoreconfHook
, hexdump
#
, url
, sha256
, depends
}:

gcc10Stdenv.mkDerivation rec {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ ];
  buildInputs = [  pkgconfig autoreconfHook hexdump ];

  preConfigure = ''
    export CONFIG_SITE=${depends}/share/config.site
  '';

  configureFlags = [
    "--with-boost-libdir=${depends}/include/boost"
    # "--with-gui"

    "--disable-tests"
    "--disable-bench"
    "--disable-fuzz-binary"
  ];

  preFixup = ''
    ./contrib/devtools/split-debug.sh $out/bin/bitcoind $out/bin/bitcoind-s $out/bin/bitcoind-d
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
