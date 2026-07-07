# Assemble the release archive bitcoin-<version>-x86_64-linux-gnu.tar.gz
# byte-identically to upstream's GUIX-built tarball, from the already
# byte-matching binaries in `bitcoind` plus the committed extras
# (README.md, the example bitcoin.conf, share/rpcauth) taken from the
# release source tarball.
#
# Reproduces contrib/guix/libexec/build.sh's deterministic packaging:
#   find DISTNAME -not -name '*.dbg' -print0 | sort -z \
#     | tar --create --no-recursion --mode='u+rw,go+r-w,a+X' --null --files-from=- \
#     | gzip -9n
# GUIX runs that in a container where every installed file already has
# uid/gid 0 and mtime = SOURCE_DATE_EPOCH (the v31.0 commit timestamp,
# 1776286524). We can't reproduce those ambient conditions in the Nix
# sandbox, so we pin them explicitly on the tar command line
# (--mtime / --owner / --group / --numeric-owner) — same resulting bytes.
{ lib
, runCommandLocal
, gnutar
, gzip
, coreutils
, fetchurl
, version
, url
, sha256
, bitcoind
# Target triple in the archive name + the `bitcoind` arg's arch. Defaults to
# x86_64; pass arch = "aarch64-linux-gnu" + the aarch64 bitcoind + expected
# hash to assemble the aarch64 release archive.
, arch ? "x86_64-linux-gnu"
# debug = true assembles the -debug.tar.gz instead: only the .dbg files,
# selected exactly like GUIX build.sh's `find DISTNAME -name "*.dbg"` (note:
# unlike the main archive, no directory entries match, so the archive
# contains just the 10 file entries). Pass the matching expectedSha256.
, debug ? false
# darwin = true assembles the darwin "-unsigned.tar.gz": same packaging
# rules, but build.sh ships NO README.md for darwin (its per-host case
# copies it for linux only) and there are no .dbg files at all.
, darwinUnsigned ? false
# null = no upstream hash to gate against (byte-match gate skipped).
# Callers pass the hash looked up from the checked-in SHA256SUMS.
, expectedSha256 ? null
# SOURCE_DATE_EPOCH passes through from default.nix (the release
# tag's commit time). v31.0 hard-coded 1776286524 inline.
, sourceDateEpoch
}:

let
  src = fetchurl { inherit url sha256; };
  archiveName = "bitcoin-${version}-${arch}${lib.optionalString darwinUnsigned "-unsigned"}${lib.optionalString debug "-debug"}.tar.gz";
in
runCommandLocal archiveName
{
  nativeBuildInputs = [ gnutar gzip coreutils ];
} (''
  D=bitcoin-${version}
  mkdir -p "$D/bin" "$D/libexec"
'' + (if debug then ''
  # Debug archive: just the ten .dbg files.
  for b in bitcoin bitcoin-cli bitcoind bitcoin-qt bitcoin-tx bitcoin-util bitcoin-wallet; do
    cp ${bitcoind}/bin/$b.dbg "$D/bin/$b.dbg"
  done
  for b in bitcoin-gui bitcoin-node test_bitcoin; do
    cp ${bitcoind}/libexec/$b.dbg "$D/libexec/$b.dbg"
  done
'' else ''
  mkdir -p "$D/share/man/man1" "$D/share/rpcauth"

  # Stripped runtime binaries (the .dbg debug files are excluded from the
  # main archive — they ship in the separate -debug tarball).
  for b in bitcoin bitcoin-cli bitcoind bitcoin-qt bitcoin-tx bitcoin-util bitcoin-wallet; do
    cp ${bitcoind}/bin/$b "$D/bin/$b"
  done
  for b in bitcoin-gui bitcoin-node test_bitcoin; do
    cp ${bitcoind}/libexec/$b "$D/libexec/$b"
  done

  # Man pages, uncompressed (nixpkgs gzips them in the bitcoind output;
  # upstream ships them uncompressed).
  for m in ${bitcoind}/share/man/man1/*.1.gz; do
    zcat "$m" > "$D/share/man/man1/$(basename "$m" .gz)"
  done

  # Committed extras from the release source tarball (extracted into a
  # separate dir so it doesn't collide with $D = bitcoin-${version}).
  # darwin ships no README.md (build.sh copies it for linux hosts only).
  mkdir srctmp
  tar xzf ${src} -C srctmp \
    ${lib.optionalString (!darwinUnsigned) "bitcoin-${version}/README.md"} \
    bitcoin-${version}/share/examples/bitcoin.conf \
    bitcoin-${version}/share/rpcauth
  ${lib.optionalString (!darwinUnsigned) ''cp srctmp/bitcoin-${version}/README.md "$D/README.md"''}
  cp srctmp/bitcoin-${version}/share/examples/bitcoin.conf "$D/bitcoin.conf"
  cp srctmp/bitcoin-${version}/share/rpcauth/* "$D/share/rpcauth/"
'') + ''

  # Normalize permissions before tar (its --mode is symbolic, so the a+X
  # result depends on the current executable bit).
  find "$D" -type d -exec chmod 755 {} +
  find "$D" -type f -exec chmod 644 {} +
  # Executables (and the .dbg files, which objcopy creates 0755 — upstream
  # ships them 0755 too; tar's `a+X` only keeps the exec bit if it's set).
  chmod 755 "$D"/bin/* "$D"/libexec/* ${lib.optionalString (!debug) ''"$D"/share/rpcauth/rpcauth.py''}

  find "$D" ${if debug then "-name '*.dbg'" else "-not -name '*.dbg'"} -print0 | LC_ALL=C sort -z \
    | tar --create --no-recursion --mode='u+rw,go+r-w,a+X' --null --files-from=- \
          --mtime=@${toString sourceDateEpoch} --owner=0 --group=0 --numeric-owner \
    | gzip -9n > "$out"

  actual=$(sha256sum "$out" | cut -d' ' -f1)
'' + (if expectedSha256 == null then ''
  echo "BUILT: ${archiveName} ($actual) — no upstream gate (not in checked-in SHA256SUMS)"
'' else ''
  if [ "$actual" != "${expectedSha256}" ]; then
    echo "FAIL: tarball sha256 does not match upstream GUIX release"
    echo "  expected: ${expectedSha256}"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "OK: ${archiveName} matches upstream ($actual)"
''))
