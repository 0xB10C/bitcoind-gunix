{
  gcc14Stdenv # The GUIX builds for Bitcoin Core v31.0 use GCC 14.2.0
, fetchurl
# build-inputs
, pkg-config
, autoreconfHook
, hexdump
, which
#
, url
, sha256
, depends
}:

gcc14Stdenv.mkDerivation rec {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ ];
  buildInputs = [ pkg-config autoreconfHook hexdump which ];

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
