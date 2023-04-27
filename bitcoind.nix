{
  gcc10Stdenv # The GUIX builds are using GCC 10.3.0
, fetchurl
# build-inputs
, pkgconfig
, autoreconfHook
, hexdump
, which
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
  buildInputs = [ pkgconfig autoreconfHook hexdump which ];

  preConfigure = ''
    export CONFIG_SITE=${depends}/share/config.site

    # checking for QMinimalIntegrationPlugin looks in the depends/x86_64-pc-linux-gnu
    # dir. We might be able to control that with a ENV var, but just symlinking works
    # too
    ln -s ${depends} depends/x86_64-pc-linux-gnu
  '';

  configureFlags = [
    "--with-boost-libdir=${depends}/include/boost"
    "--with-gui"

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
