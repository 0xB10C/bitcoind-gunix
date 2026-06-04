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
{ runCommandLocal
, gnutar
, gzip
, coreutils
, fetchurl
, version
, url
, sha256
, bitcoind
}:

let
  src = fetchurl { inherit url sha256; };
  # SOURCE_DATE_EPOCH = `git log --format=%at -1` of the v31.0 tag.
  sourceDateEpoch = "1776286524";
  expectedSha256 = "d3e4c58a35b1d0a97a457462c94f55501ad167c660c245cb1ffa565641c65074";
in
runCommandLocal "bitcoin-${version}-x86_64-linux-gnu.tar.gz"
{
  nativeBuildInputs = [ gnutar gzip coreutils ];
} ''
  D=bitcoin-${version}
  mkdir -p "$D/bin" "$D/libexec" "$D/share/man/man1" "$D/share/rpcauth"

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
  mkdir srctmp
  tar xzf ${src} -C srctmp \
    bitcoin-${version}/README.md \
    bitcoin-${version}/share/examples/bitcoin.conf \
    bitcoin-${version}/share/rpcauth
  cp srctmp/bitcoin-${version}/README.md "$D/README.md"
  cp srctmp/bitcoin-${version}/share/examples/bitcoin.conf "$D/bitcoin.conf"
  cp srctmp/bitcoin-${version}/share/rpcauth/* "$D/share/rpcauth/"

  # Normalize permissions before tar (its --mode is symbolic, so the a+X
  # result depends on the current executable bit).
  find "$D" -type d -exec chmod 755 {} +
  find "$D" -type f -exec chmod 644 {} +
  # Executables: the 10 binaries and the rpcauth.py script (upstream ships
  # all of these 0755; tar's `a+X` only keeps the exec bit if it's set).
  chmod 755 "$D"/bin/* "$D"/libexec/* "$D"/share/rpcauth/rpcauth.py

  find "$D" -not -name '*.dbg' -print0 | LC_ALL=C sort -z \
    | tar --create --no-recursion --mode='u+rw,go+r-w,a+X' --null --files-from=- \
          --mtime=@${sourceDateEpoch} --owner=0 --group=0 --numeric-owner \
    | gzip -9n > "$out"

  actual=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$actual" != "${expectedSha256}" ]; then
    echo "FAIL: tarball sha256 does not match upstream GUIX v31.0 release"
    echo "  expected: ${expectedSha256}"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "OK: bitcoin-${version}-x86_64-linux-gnu.tar.gz matches upstream ($actual)"
''
