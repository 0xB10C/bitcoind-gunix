# Assemble bitcoin-<version>-<host>-codesigning.tar.gz byte-identically to
# upstream's GUIX build.sh output. It is the input the signer consumes
# (contrib/guix/libexec/codesign.sh) AND a published, gated artifact.
#
# build.sh's darwin case tars an `unsigned-app-<host>/` dir containing:
#   ./detached-sig-create.sh            (from contrib/macdeploy/)
#   ./dist/Bitcoin-Qt.app/...           (the deploy bundle, minus the zip)
#   ./bitcoin-<version>/...             (the install tree — byte-for-byte
#                                        the same files as -unsigned.tar.gz)
# with the same deterministic packaging as the release archive
# (find|sort|tar --mode=… --null | gzip -9n); see lib/tarball.nix.
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
, host # e.g. "x86_64-apple-darwin"
, bitcoindDarwin # provides .dist (Bitcoin-Qt.app + the app zip)
, unsignedTarball # the verified -unsigned.tar.gz (its bitcoin-<version>/ tree)
, expectedSha256
}:

let
  src = fetchurl { inherit url sha256; };
  sourceDateEpoch = "1776286524";
  archiveName = "bitcoin-${version}-${host}-codesigning.tar.gz";
in
runCommandLocal archiveName
{
  nativeBuildInputs = [ gnutar gzip coreutils findutils ];
} ''
  mkdir unsigned-app && cd unsigned-app

  # detached-sig-create.sh, verbatim from the release source.
  mkdir ../srctmp
  tar xzf ${src} -C ../srctmp bitcoin-${version}/contrib/macdeploy/detached-sig-create.sh
  cp ../srctmp/bitcoin-${version}/contrib/macdeploy/detached-sig-create.sh ./detached-sig-create.sh

  # The install tree, taken from the already-byte-identical -unsigned.tar.gz
  # (its bitcoin-<version>/ subtree == the codesigning tarball's, verified).
  tar xzf ${unsignedTarball}

  # The deploy app bundle (the app zip is NOT part of the codesigning tarball).
  mkdir dist
  cp -a ${bitcoindDarwin.dist}/Bitcoin-Qt.app dist/Bitcoin-Qt.app

  # Normalize modes (tar's --mode is symbolic; a+X depends on the exec bit).
  # Upstream: dirs 0755, files 0644, the binaries/scripts 0755.
  find . -type d -exec chmod 755 {} +
  find . -type f -exec chmod 644 {} +
  chmod 755 \
    bitcoin-${version}/bin/* \
    bitcoin-${version}/libexec/* \
    bitcoin-${version}/share/rpcauth/rpcauth.py \
    detached-sig-create.sh \
    dist/Bitcoin-Qt.app/Contents/MacOS/Bitcoin-Qt

  find . -print0 | LC_ALL=C sort -z \
    | tar --create --no-recursion --mode='u+rw,go+r-w,a+X' --null --files-from=- \
          --mtime=@${sourceDateEpoch} --owner=0 --group=0 --numeric-owner \
    | gzip -9n > "$out"

  actual=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$actual" != "${expectedSha256}" ]; then
    echo "FAIL: codesigning tarball sha256 does not match upstream GUIX v31.0 release"
    echo "  expected: ${expectedSha256}"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "OK: ${archiveName} matches upstream ($actual)"
''
