{
  stdenv   # can be overriden in default.nix
, fetchurl
# build-inputs
, pkg-config
, cmake
, hexdump
, which
, binutils  # for objcopy and strip
#
, url
, sha256
, depends
}:
let
  myCflags = "-O2 -g -ffile-prefix-map=${builtins.storeDir}=/usr";
  myLdflags = "-Wl,--as-needed -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 -static-libstdc++ -Wl,-O2";
in
stdenv.mkDerivation rec {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  outputs = [ "out" "debug" ];

  nativeBuildInputs = [ pkg-config cmake hexdump which binutils ];
  buildInputs = [ ];

  preConfigure = ''
    ln -s ${depends} depends/x86_64-pc-linux-gnu
  '';

  # instead of relying on the nix's cmake configure phase, write things out
  # explicitly here, as its easier to compare to the guix steps. can be rewritten
  # to be more declaritive once weve squared up with the guix builds
  configurePhase = ''
    runHook preConfigure
    mkdir build
    cd build
    cmake .. \
      -DCMAKE_TOOLCHAIN_FILE=${depends}/toolchain.cmake \
      -DCMAKE_PREFIX_PATH=/ \
      -DCMAKE_INSTALL_PREFIX=$out \
      -DCMAKE_C_FLAGS="${myCflags}" \
      -DCMAKE_CXX_FLAGS="${myCflags}" \
      -DCMAKE_SHARED_LINKER_FLAGS="${myLdflags}" \
      -DCMAKE_EXE_LINKER_FLAGS="${myLdflags}" \
      -DREDUCE_EXPORTS=ON \
      -DBUILD_BENCH=OFF \
      -DBUILD_GUI_TESTS=OFF \
      -DBUILD_FUZZ_BINARY=OFF
    runHook postConfigure
  '';

  # i couldnt figure out how to easily call the split-debug script after building
  # so this is also imperatively called in the postBuild hook.
  # note: cant use nix's separateDebugInfo and doStrip
  # hooks because they use eu-strip (instead of strip). also, --enable-deterministic-archives
  # is not used in nix's strip script.
  postBuild = ''
    for binary in $(find . -type f -executable -name "bitcoin*"); do
      echo "Splitting debug symbols for $binary"
      ./split-debug.sh "$binary" "$binary.stripped" "$binary.debug"
      mv "$binary.stripped" "$binary"
    done
  '';

  # output both the stripped and non-stripped versions, since we want to compare both
  # todo: make this more declarative , i.e., follow nix conventions for multioutput drvs
  installPhase = ''
    runHook preInstall
    
    mkdir -p $out/bin
    find . -type f -executable -name "bitcoin*" -exec cp {} $out/bin/ \;
    mkdir -p $debug/lib/debug
    find . -name "*.debug" -exec cp {} $debug/lib/debug/ \;
    
    runHook postInstall
  '';

  env = {
    SOURCE_DATE_EPOCH = "1750944068"; # set to match SDE used in guix, derived from the head commit
    TZ = "UTC";
  };

  # disable automatic debug info separation since we're doing it manually
  separateDebugInfo = false;
  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
