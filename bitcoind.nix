{
  stdenv
, fetchurl
# build-inputs
, pkg-config
, cmake
, hexdump
, which
#
, url
, sha256
, depends
}:

stdenv.mkDerivation rec {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake hexdump which ];
  buildInputs = [ ];

  preConfigure = ''
    export CMAKE_TOOLCHAIN_FILE=${depends}/toolchain.cmake

    # checking for QMinimalIntegrationPlugin looks in the depends/x86_64-pc-linux-gnu
    # dir. We might be able to control that with a ENV var, but just symlinking works
    # too
    ln -s ${depends} depends/x86_64-pc-linux-gnu
  '';
  cmakeFlags = [ "-DCMAKE_PREFIX_PATH=/" ];
  configureFlags = [
    "--with-boost-libdir=${depends}/include/boost"
    "--with-gui"

    "--disable-tests"
    "--disable-bench"
    "--disable-fuzz-binary"
  ];

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
