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
# osslsigncode 2.14 (GUIX's pin since v32.0rc2; 2.5 before that) REMOVED
# -CAfile from attach-signature — `osslsigncode attach-signature --help`
# lists only -add-msi-dse/-h/-in/-nest/-out/-sigin, and -CAfile now exists
# only under the separate `verify` command. Passing it makes 2.14 exit with
# "Unknown option: -CAfile" and write NO output. That split is exactly why
# upstream's codesign.sh gained a standalone `osslsigncode verify -CAfile …
# -ignore-crl -ignore-cdp` pass (and manifest_codesign.scm gained nss-certs)
# at the same time. That verify pass only re-reads the file attach-signature
# already wrote, so it cannot change the emitted bytes and is not reproduced
# here. Do NOT add `|| true` back: with 2.14 there is no verification step
# left to tolerate, so any nonzero exit is a real failure, and swallowing it
# only turns a missing signature into a confusing `mv: cannot stat` later.
{ lib
, runCommand
, gnutar
, zip
, coreutils
, findutils
, osslsigncode
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
      -sigin codesignatures/win/"$bin_base".pem
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
