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

  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [ hexdump which python3 ];

  cmakeFlags = [
    "-DCMAKE_TOOLCHAIN_FILE=${depends}/share/toolchain.cmake"
  ];

  preFixup = ''
    ./split-debug.sh $out/bin/bitcoind $out/bin/bitcoind-s $out/bin/bitcoind-d
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
