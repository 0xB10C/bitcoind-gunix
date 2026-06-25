# Reproduce bitcoin-31.0-win64-setup-unsigned.exe — the NSIS installer.
#
# GUIX (build.sh mingw case): `cmake --build build -t deploy` →
#   1. generate_setup_nsi()  : configure_file(share/setup.nsi.in → build/bitcoin-win64-setup.nsi)
#   2. CMAKE_STRIP each binary → build/release/<name>.exe   (the stripped .exe)
#   3. makensis -V2 build/bitcoin-win64-setup.nsi           → build/bitcoin-win64-setup.exe
#   4. mv … → <DISTNAME>-win64-setup-unsigned.exe
#
# We reproduce it: the stripped .exe come from `bitcoind` (already byte-
# identical), the assets from the release source tarball, and the .nsi is the
# SAME configure_file substitution done by hand (makensis embeds file CONTENT,
# not the source paths, so staging at our own dir is transparent). makensis is
# our GUIX-style NSIS 3.10 (native compiler + cross-compiled stubs). The PE
# timestamp is pinned via SOURCE_DATE_EPOCH like GUIX's environment.
{ lib
, stdenv
, coreutils
, gnutar
, gzip
, fetchurl
, version
, url
, sha256
, bitcoind          # the win64 bitcoind derivation (stripped .exe in bin/ + libexec/)
, nsis              # GUIX-style NSIS 3.10 (makensis + stubs)
, mingwBinutils241  # final cross binutils 2.41 (objcopy for the release/ exes)
, libfaketime       # freeze time(NULL) for objcopy's PE TimeDateStamp regen
, hostTriple        # "x86_64-w64-mingw32"
, sourceDateEpoch   # release tag commit epoch (== GUIX SOURCE_DATE_EPOCH)
, expectedSha256 ? null  # null → don't gate (iteration)
}:

let
  src = fetchurl { inherit url sha256; };
  outName = "bitcoin-${version}-win64-setup-unsigned.exe";
  # release/<name>.exe binaries the .nsi packages (NOT bitcoin-util — the .nsi
  # strips it into release/ but never File's it).
  binExes = [ "bitcoin-qt" "bitcoin" "bitcoind" "bitcoin-cli" "bitcoin-tx" "bitcoin-wallet" ];
in
stdenv.mkDerivation {
  name = outName;
  dontUnpack = true;

  nativeBuildInputs = [ nsis coreutils gnutar gzip ];

  buildPhase = ''
    runHook preBuild
    export SOURCE_DATE_EPOCH=${toString sourceDateEpoch}

    # Stage GUIX's distsrc layout: abs_top_srcdir = $S, abs_top_builddir = $S/build.
    S=$PWD/stage
    mkdir -p "$S/build/release" "$S/doc" "$S/share/examples" "$S/share/rpcauth" "$S/share/pixmaps"

    # The stripped .exe → build/release/ (bitcoind's bin/ + libexec/test_bitcoin).
    #
    # GUIX's `deploy` target runs ${"$"}{CMAKE_STRIP} directly on the cmake
    # BUILD-TREE binary (before split-debug ever ran), giving a fully-stripped
    # PE with NO .gnu_debuglink section. Our $out binaries already have
    # .gnu_debuglink added (bitcoind-win.nix postInstall); removing just that
    # section reproduces GUIX's release/*.exe byte-for-byte (verified against
    # the upstream NSIS payload for all 7 binaries).
    #
    # binutils 2.41's objcopy ALWAYS regenerates the PE TimeDateStamp via
    # time(NULL) (ignores SOURCE_DATE_EPOCH and any existing value), so freeze
    # the clock with faketime to get upstream's ${toString sourceDateEpoch} (0x69dffb3c).
    FAKETIME_DATE=$(date -u -d "@${toString sourceDateEpoch}" '+%Y-%m-%d %H:%M:%S')
    stripRelease() {
      chmod u+w "$1"
      TZ=UTC ${libfaketime}/bin/faketime -f "$FAKETIME_DATE" \
        ${mingwBinutils241}/bin/${hostTriple}-objcopy --remove-section=.gnu_debuglink "$1"
    }
    ${lib.concatMapStringsSep "\n" (b: ''
      cp ${bitcoind}/bin/${b}.exe "$S/build/release/${b}.exe"
      stripRelease "$S/build/release/${b}.exe"
    '') binExes}
    cp ${bitcoind}/libexec/test_bitcoin.exe "$S/build/release/test_bitcoin.exe"
    stripRelease "$S/build/release/test_bitcoin.exe"

    # Committed assets from the release source tarball.
    mkdir srctmp
    tar xzf ${src} -C srctmp \
      bitcoin-${version}/COPYING \
      bitcoin-${version}/doc/README_windows.txt \
      bitcoin-${version}/share/examples/bitcoin.conf \
      bitcoin-${version}/share/rpcauth \
      bitcoin-${version}/share/pixmaps \
      bitcoin-${version}/share/setup.nsi.in
    cp srctmp/bitcoin-${version}/COPYING "$S/COPYING"
    cp srctmp/bitcoin-${version}/doc/README_windows.txt "$S/doc/README_windows.txt"
    cp srctmp/bitcoin-${version}/share/examples/bitcoin.conf "$S/share/examples/bitcoin.conf"
    cp srctmp/bitcoin-${version}/share/rpcauth/* "$S/share/rpcauth/"
    cp srctmp/bitcoin-${version}/share/pixmaps/bitcoin.ico "$S/share/pixmaps/"
    cp srctmp/bitcoin-${version}/share/pixmaps/nsis-wizard.bmp "$S/share/pixmaps/"
    cp srctmp/bitcoin-${version}/share/pixmaps/nsis-header.bmp "$S/share/pixmaps/"

    # Reproduce cmake's generate_setup_nsi() configure_file(@ONLY) by hand.
    cp srctmp/bitcoin-${version}/share/setup.nsi.in bitcoin-win64-setup.nsi
    substituteInPlace bitcoin-win64-setup.nsi \
      --replace-quiet '@abs_top_srcdir@'   "$S" \
      --replace-quiet '@abs_top_builddir@' "$S/build" \
      --replace-quiet '@CLIENT_NAME@'            "Bitcoin Core" \
      --replace-quiet '@CLIENT_URL@'             "https://bitcoincore.org/" \
      --replace-quiet '@CLIENT_TARNAME@'         "bitcoin" \
      --replace-quiet '@CLIENT_VERSION_MAJOR@'   "31" \
      --replace-quiet '@CLIENT_VERSION_MINOR@'   "1" \
      --replace-quiet '@CLIENT_VERSION_BUILD@'   "0" \
      --replace-quiet '@CLIENT_VERSION_STRING@'  "31.1.0rc1" \
      --replace-quiet '@COPYRIGHT_YEAR@'         "2026" \
      --replace-quiet '@COPYRIGHT_HOLDERS_FINAL@' "The Bitcoin Core developers" \
      --replace-quiet '@BITCOIN_WRAPPER_NAME@'     "bitcoin" \
      --replace-quiet '@BITCOIN_GUI_NAME@'         "bitcoin-qt" \
      --replace-quiet '@BITCOIN_DAEMON_NAME@'      "bitcoind" \
      --replace-quiet '@BITCOIN_CLI_NAME@'         "bitcoin-cli" \
      --replace-quiet '@BITCOIN_TX_NAME@'          "bitcoin-tx" \
      --replace-quiet '@BITCOIN_WALLET_TOOL_NAME@' "bitcoin-wallet" \
      --replace-quiet '@BITCOIN_TEST_NAME@'        "test_bitcoin" \
      --replace-quiet '@EXEEXT@'                   ".exe"

    # makensis defaults OutFile to the script basename → bitcoin-win64-setup.exe.
    makensis -V2 bitcoin-win64-setup.nsi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -m444 bitcoin-win64-setup.exe "$out"
    runHook postInstall
  '';

  # Gate: byte-match upstream's win64-setup-unsigned.exe (when expectedSha256 set).
  postFixup = lib.optionalString (expectedSha256 != null) ''
    got=$(sha256sum "$out" | cut -d' ' -f1)
    if [ "$got" != "${expectedSha256}" ]; then
      echo "ERROR: ${outName} sha256 $got != ${expectedSha256}" >&2
      exit 1
    fi
    echo "OK: ${outName} matches upstream (${expectedSha256})"
  '';
}
