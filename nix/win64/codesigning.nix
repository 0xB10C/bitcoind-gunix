# Assemble bitcoin-<version>-win64-codesigning.tar.gz byte-identically to
# upstream's GUIX build. It is the input the signer consumes
# (contrib/guix/libexec/codesign.sh) AND a published, gated artifact.
#
# build.sh's mingw case tars a `windeploy/` dir containing:
#   ./detached-sig-create.sh        (from contrib/windeploy/, verbatim)
#   ./win-codesign.cert              (from contrib/windeploy/, verbatim)
#   ./unsigned/bitcoin-<ver>-win64-setup-unsigned.exe  (= setupExeMingw)
#   ./unsigned/bitcoin-<ver>/...      (the SAME tree as -unsigned.zip, minus
#                                      .dbg — win64/zip.nix's non-debug $D)
# with the same deterministic packaging as the release archives
# (find|sort|tar --mode=...|gzip -9n; TAR_OPTIONS supplies --mtime/--owner).
{ lib
, runCommandLocal
, gnutar
, gzip
, coreutils
, findutils
, fetchurl
, version
, url
, sha256
, bitcoind   # bitcoindMingw (8 .exe + .dbg + man pages)
, setupExe   # setupExeMingw output (the setup-unsigned.exe file)
, expectedSha256
}:

let
  src = fetchurl { inherit url sha256; };
  sourceDateEpoch = "1776286524";
  archiveName = "bitcoin-${version}-win64-codesigning.tar.gz";
  exes = [ "bitcoin" "bitcoin-cli" "bitcoind" "bitcoin-tx" "bitcoin-util" "bitcoin-wallet" "bitcoin-qt" ];
in
runCommandLocal archiveName
{
  nativeBuildInputs = [ gnutar gzip coreutils findutils ];
} ''
  mkdir windeploy && cd windeploy

  # detached-sig-create.sh + win-codesign.cert, verbatim from the release source.
  mkdir ../srctmp
  tar xzf ${src} -C ../srctmp \
    bitcoin-${version}/contrib/windeploy/detached-sig-create.sh \
    bitcoin-${version}/contrib/windeploy/win-codesign.cert
  cp ../srctmp/bitcoin-${version}/contrib/windeploy/detached-sig-create.sh .
  cp ../srctmp/bitcoin-${version}/contrib/windeploy/win-codesign.cert .

  mkdir unsigned
  cp ${setupExe} unsigned/bitcoin-${version}-win64-setup-unsigned.exe

  # The install tree (same as win64-unsigned.zip's bitcoin-<version>/, minus .dbg).
  D=unsigned/bitcoin-${version}
  mkdir -p "$D/bin" "$D/libexec" "$D/share/man/man1" "$D/share/rpcauth"

  for b in ${toString exes}; do
    cp ${bitcoind}/bin/$b.exe "$D/bin/$b.exe"
  done
  cp ${bitcoind}/libexec/test_bitcoin.exe "$D/libexec/test_bitcoin.exe"

  for m in ${bitcoind}/share/man/man1/*.1.gz; do
    zcat "$m" > "$D/share/man/man1/$(basename "$m" .gz)"
  done

  tar xzf ${src} -C ../srctmp \
    bitcoin-${version}/doc/README_windows.txt \
    bitcoin-${version}/share/examples/bitcoin.conf \
    bitcoin-${version}/share/rpcauth
  cp ../srctmp/bitcoin-${version}/doc/README_windows.txt "$D/readme.txt"
  cp ../srctmp/bitcoin-${version}/share/examples/bitcoin.conf "$D/bitcoin.conf"
  cp ../srctmp/bitcoin-${version}/share/rpcauth/* "$D/share/rpcauth/"

  # Normalize modes to match upstream's archived permissions.
  find . -type d -exec chmod 755 {} +
  find . -type f -exec chmod 644 {} +
  chmod 755 \
    detached-sig-create.sh \
    "$D"/bin/*.exe "$D"/libexec/*.exe "$D"/share/rpcauth/rpcauth.py

  find . -print0 | LC_ALL=C sort -z \
    | tar --create --no-recursion --mode='u+rw,go+r-w,a+X' --null --files-from=- \
          --mtime=@${sourceDateEpoch} --owner=0 --group=0 --numeric-owner \
    | gzip -9n > "$out"

  actual=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$actual" != "${expectedSha256}" ]; then
    echo "FAIL: ${archiveName} sha256 does not match upstream GUIX v31.0 release"
    echo "  expected: ${expectedSha256}"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "OK: ${archiveName} matches upstream ($actual)"
''
