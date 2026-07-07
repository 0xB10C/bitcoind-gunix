# Assemble the win64 release archives byte-identically to upstream's GUIX
# build, from the byte-matching PE binaries in `bitcoind` plus the committed
# extras. Unlike the linux/darwin targets, mingw ships ZIP archives:
#   bitcoin-31.0-win64-unsigned.zip  (stripped .exe + extras)
#   bitcoin-31.0-win64-debug.zip     (the .dbg only)
#
# Reproduces contrib/guix/libexec/build.sh's mingw packaging:
#   find DISTNAME -not -name '*.dbg' -print0 | xargs -0r touch --date=@EPOCH
#   find DISTNAME -not -name '*.dbg' | sort | zip -X@ out.zip
# (and the -name '*.dbg' variant for the debug zip). zip records the DOS
# mtime from the filesystem (touched to SOURCE_DATE_EPOCH) and the unix mode
# in the external attributes, so perms are normalized to match upstream:
# dirs + .exe/.dbg + rpcauth.py 0755, everything else 0644. `-X` drops the
# UT/ux extra fields. zip 3.0 (== GUIX's) auto-flags text vs binary entries.
{ lib
, runCommandLocal
, zip
, coreutils
, fetchurl
, version
, url
, sha256
, bitcoind          # the win64 bitcoind derivation (8 .exe + 8 .dbg)
, debug ? false     # true → the -debug.zip (just the .dbg)
# null = no upstream hash to gate against (byte-match gate skipped).
# Callers pass the hash looked up from the checked-in SHA256SUMS.
, expectedSha256 ? null
# SOURCE_DATE_EPOCH — passed through from default.nix (the release
# tag's commit time); the fallback is v31.0's epoch.
, sourceDateEpoch ? 1776286524
}:

let
  src = fetchurl { inherit url sha256; };
  archiveName = "bitcoin-${version}-win64${if debug then "-debug" else "-unsigned"}.zip";
  exes = [ "bitcoin" "bitcoin-cli" "bitcoind" "bitcoin-tx" "bitcoin-util" "bitcoin-wallet" "bitcoin-qt" ];
in
runCommandLocal archiveName
{
  nativeBuildInputs = [ zip coreutils ];
} (''
  D=bitcoin-${version}
  mkdir -p "$D/bin" "$D/libexec"
'' + (if debug then ''
  # Debug archive: just the eight .dbg files (no directory entries match
  # `find -name '*.dbg'`).
  for b in ${toString exes}; do
    cp ${bitcoind}/bin/$b.exe.dbg "$D/bin/$b.exe.dbg"
  done
  cp ${bitcoind}/libexec/test_bitcoin.exe.dbg "$D/libexec/test_bitcoin.exe.dbg"
'' else ''
  mkdir -p "$D/share/man/man1" "$D/share/rpcauth"

  for b in ${toString exes}; do
    cp ${bitcoind}/bin/$b.exe "$D/bin/$b.exe"
  done
  cp ${bitcoind}/libexec/test_bitcoin.exe "$D/libexec/test_bitcoin.exe"

  # Man pages, uncompressed (nixpkgs gzips them; upstream ships them plain).
  for m in ${bitcoind}/share/man/man1/*.1.gz; do
    zcat "$m" > "$D/share/man/man1/$(basename "$m" .gz)"
  done

  # Committed extras from the release source tarball. build.sh copies
  # doc/README_windows.txt → readme.txt for mingw (NOT README.md).
  mkdir srctmp
  tar xzf ${src} -C srctmp \
    bitcoin-${version}/doc/README_windows.txt \
    bitcoin-${version}/share/examples/bitcoin.conf \
    bitcoin-${version}/share/rpcauth
  cp srctmp/bitcoin-${version}/doc/README_windows.txt "$D/readme.txt"
  cp srctmp/bitcoin-${version}/share/examples/bitcoin.conf "$D/bitcoin.conf"
  cp srctmp/bitcoin-${version}/share/rpcauth/* "$D/share/rpcauth/"
'') + ''

  # Normalize modes to match upstream's external attributes.
  find "$D" -type d -exec chmod 755 {} +
  find "$D" -type f -exec chmod 644 {} +
  ${if debug
    then ''chmod 755 "$D"/bin/*.dbg "$D"/libexec/*.dbg''
    else ''chmod 755 "$D"/bin/*.exe "$D"/libexec/*.exe "$D"/share/rpcauth/rpcauth.py''}

  # Pin mtimes to SOURCE_DATE_EPOCH (zip reads the DOS time from the fs).
  find "$D" ${if debug then "-name '*.dbg'" else ""} -print0 \
    | xargs -0r touch --no-dereference --date="@${toString sourceDateEpoch}"

  find "$D" ${if debug then "-name '*.dbg'" else "-not -name '*.dbg'"} \
    | LC_ALL=C sort \
    | zip -X@ "$out"

  actual=$(sha256sum "$out" | cut -d' ' -f1)
'' + (if expectedSha256 == null then ''
  echo "BUILT: ${archiveName} ($actual) — no upstream gate (not in checked-in SHA256SUMS)"
'' else ''
  if [ "$actual" != "${expectedSha256}" ]; then
    echo "FAIL: ${archiveName} sha256 does not match upstream"
    echo "  expected: ${expectedSha256}"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "OK: ${archiveName} matches upstream ($actual)"
''))
