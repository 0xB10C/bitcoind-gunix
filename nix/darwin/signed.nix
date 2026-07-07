# Apply Bitcoin Core's detached macOS signatures with signapple and
# assemble the two SIGNED darwin artifacts byte-identically to upstream:
#   bitcoin-<version>-<host>.tar.gz   (signed binaries)
#   bitcoin-<version>-<host>.zip      (signed Bitcoin-Qt.app)
#
# Mirrors contrib/guix/libexec/codesign.sh's darwin case exactly. Because
# our unsigned binaries are already byte-identical to upstream's (UUID
# patched), the same signapple + elfesteem versions + the same detached
# signatures reproduce upstream's signed bytes. Both outputs land in $out
# and are gated against the upstream SHA256SUMS.
{ lib
, runCommand
, gnutar
, gzip
, zip
, coreutils
, findutils
, signapple
, version
, sourceDateEpoch
, host # "x86_64-apple-darwin" | "arm64-apple-darwin"
, arch # "x86_64" | "arm64" (the .<arch>sign suffix)
, codesigningTarball # the -codesigning.tar.gz drv (signer input)
, detachedSigs # bitcoin-core/bitcoin-detached-sigs @ v31.1 (osx/ tree)
, expectedTarballSha256 ? null
, expectedZipSha256 ? null
}:

runCommand "bitcoin-${version}-${host}-signed"
{
  nativeBuildInputs = [ gnutar gzip zip coreutils findutils signapple ];
} ''
  export LC_ALL=C TZ=UTC
  SDE=${toString sourceDateEpoch}
  umask 0022

  mkdir distsrc && cd distsrc
  tar xf ${codesigningTarball}

  # The detached-sigs checkout == codesign.sh's `git archive HEAD` extract
  # (same tracked files); osx/<host>/… paths line up.
  ln -s ${detachedSigs} codesignatures

  # Apply detached codesignatures in-place (app bundle + each binary).
  signapple apply dist/Bitcoin-Qt.app codesignatures/osx/${host}/dist/Bitcoin-Qt.app
  find bitcoin-${version} \( -wholename '*/bin/*' -o -wholename '*/libexec/*' \) -type f \
    | while read -r bin; do
        signapple apply "$bin" "codesignatures/osx/${host}/$bin.${arch}sign"
      done

  mkdir -p "$out"

  # Signed .zip from dist/ (the signed app bundle).
  (
    cd dist
    find . -print0 | xargs -0r touch --no-dereference --date="@$SDE"
    find . | LC_ALL=C sort | zip -X@ "$out/bitcoin-${version}-${host}.zip"
  )

  # Signed .tar.gz from the binary tree (same deterministic packaging as
  # the release/unsigned archives).
  find bitcoin-${version} -print0 | LC_ALL=C sort -z \
    | tar --create --no-recursion --mode='u+rw,go+r-w,a+X' --null --files-from=- \
          --mtime=@$SDE --owner=0 --group=0 --numeric-owner \
    | gzip -9n > "$out/bitcoin-${version}-${host}.tar.gz"

  fail=0
  check() {
    local f="$1" want="$2"
    local got
    got=$(sha256sum "$f" | cut -d' ' -f1)
    if [ -z "$want" ]; then
      echo "BUILT (no upstream gate — not in checked-in SHA256SUMS): $(basename "$f") $got"
    elif [ "$got" = "$want" ]; then
      echo "OK:   $(basename "$f") matches upstream ($got)"
    else
      echo "FAIL: $(basename "$f")  expected $want  actual $got"
      fail=1
    fi
  }
  check "$out/bitcoin-${version}-${host}.tar.gz" "${if expectedTarballSha256 == null then "" else expectedTarballSha256}"
  check "$out/bitcoin-${version}-${host}.zip" "${if expectedZipSha256 == null then "" else expectedZipSha256}"
  [ "$fail" = "0" ] || { echo "FAIL: signed ${host} artifacts diverged from upstream guix.sigs"; exit 1; }
''
