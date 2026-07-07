# Apply Bitcoin Core's win64 detached Authenticode signatures with
# osslsigncode and assemble the two SIGNED win64 artifacts byte-identically
# to upstream:
#   bitcoin-<version>-win64-setup.exe   (signed NSIS installer)
#   bitcoin-<version>-win64.zip         (signed binary tree)
#
# Mirrors contrib/guix/libexec/codesign.sh's `*mingw*)` case: extract the
# -codesigning.tar.gz (windeploy/{detached-sig-create.sh,win-codesign.cert,
# unsigned/...}), `osslsigncode attach-signature` each unsigned .exe with its
# detached-sigs .pem (codesignatures/win/...), then `find|sort|zip -X@` the
# resulting bitcoin-<version>/ tree.
#
# osslsigncode's attach-signature writes the signed PE (incl. the recomputed
# PE checksum) BEFORE its post-attach `-CAfile` verification step, and keeps
# the output even if that verification fails — so the output bytes don't
# depend on -CAfile content; `|| true` just keeps a verification-only
# nonzero exit from aborting the build.
{ lib
, runCommand
, gnutar
, zip
, coreutils
, findutils
, osslsigncode
, cacert
, version
, sourceDateEpoch    # release tag commit epoch (== GUIX SOURCE_DATE_EPOCH)
, codesigningTarball # win64-codesigning.tar.gz drv (codesigningMingw)
, detachedSigs       # bitcoin-core/bitcoin-detached-sigs (win/ tree)
, expectedSetupSha256 ? null
, expectedZipSha256 ? null
}:

let
  distname = "bitcoin-${version}";
  exes = [ "bitcoin" "bitcoin-cli" "bitcoind" "bitcoin-tx" "bitcoin-util" "bitcoin-wallet" "bitcoin-qt" ];
in
runCommand "bitcoin-${version}-win64-signed"
{
  nativeBuildInputs = [ gnutar zip coreutils findutils osslsigncode ];
} ''
  export LC_ALL=C TZ=UTC
  umask 0022

  mkdir distsrc && cd distsrc
  tar xf ${codesigningTarball}

  # The detached-sigs checkout == codesign.sh's `git archive HEAD` extract.
  ln -s ${detachedSigs} codesignatures

  mkdir -p "$out"
  WORKDIR=.tmp
  mkdir -p "$WORKDIR"
  cp -r --target-directory="$WORKDIR" "unsigned/${distname}"
  find "$WORKDIR/${distname}" -name '*.exe' -type f -delete

  sign() {
    bin_base="$1"
    out_base="''${bin_base/-unsigned/}"
    mkdir -p "$WORKDIR/$(dirname "$out_base")"
    osslsigncode attach-signature \
      -in "unsigned/$bin_base" \
      -out "$WORKDIR/$out_base" \
      -CAfile ${cacert}/etc/ssl/certs/ca-bundle.crt \
      -sigin codesignatures/win/"$bin_base".pem \
      || true
  }

  sign "${distname}-win64-setup-unsigned.exe"
  for b in ${toString exes}; do
    sign "${distname}/bin/$b.exe"
  done
  sign "${distname}/libexec/test_bitcoin.exe"

  mv "$WORKDIR/${distname}-win64-setup.exe" "$out/"

  find "$WORKDIR/${distname}" -print0 \
    | xargs -0r touch --no-dereference --date="@${toString sourceDateEpoch}"
  ( cd "$WORKDIR" && find "${distname}" | LC_ALL=C sort | zip -X@ "$out/${distname}-win64.zip" )

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
  check "$out/${distname}-win64-setup.exe" "${toString expectedSetupSha256}"
  check "$out/${distname}-win64.zip" "${toString expectedZipSha256}"
  [ "$fail" = "0" ] || { echo "FAIL: signed win64 artifacts diverged from expected"; exit 1; }
''
