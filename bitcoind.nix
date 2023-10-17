{
  gcc10Stdenv # The GUIX builds are using GCC 10.3.0
, fetchurl
# build-inputs
, pkg-config
, hexdump
, which
, cmake
, python3
#
, url
, sha256
, depends
}:

gcc10Stdenv.mkDerivation rec {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ cmake hexdump which python3 ];

  preConfigure = ''
    ln -s ${depends} depends/x86_64-pc-linux-gnu
    export CMAKE_TOOLCHAIN_FILE=depends/x86_64-pc-linux-gnu/share/toolchain.cmake
  '';

  cmakeFlags = [
    # NixOS sets CMAKE_PREFIX_PATH, which breaks the cmake find_path functions for some of the depends.
    "-DCMAKE_PREFIX_PATH=/"
  ];

  preFixup = ''
    ./split-debug.sh $out/bin/bitcoind $out/bin/bitcoind-s $out/bin/bitcoind-d
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
