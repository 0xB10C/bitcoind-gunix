# Reproduce bitcoin-<version>.tar.gz (the source dist-archive that appears
# in upstream's all.SHA256SUMS / noncodesigned.SHA256SUMS as
# `dist-archive/bitcoin-<version>.tar.gz`).
#
# GUIX (build.sh):
#   git -C "$DISTSRC" archive --format=tar --prefix="$DISTNAME"/ HEAD \
#     | gzip -n > "$OUTDIR_BASE/dist-archive/${DISTNAME}.tar.gz"
#
# Decisive observation: GitHub's own tag archive
# (`https://github.com/bitcoin/bitcoin/archive/refs/tags/v${version}.tar.gz`)
# is exactly `git archive` of the v${version} commit with prefix
# `bitcoin-${version}/` — the same command GUIX runs. Decompressing it
# yields a tar that is BYTE-IDENTICAL to GUIX's
# `git -C "$DISTSRC" archive --format=tar --prefix=… HEAD` output (verified
# against the local guix-build-31.1rc1/output/dist-archive/bitcoin-31.1rc1.tar.gz:
# both inner tars sha256 af2cdb37f16793a03a31c7a29acf13ff7778cacd5daaaab68848ba091b3de097,
# 51435520 bytes).
#
# So we don't need git inside the build at all — just gunzip the github
# archive (already in nixpkgs' fixed-output store via fetchurl in
# default.nix's `src`) and re-gzip with zlib level 6 (`gzip6.c` — matches
# GUIX's `gzip 1.13` + `zlib 1.3` `gzip -n` output byte-for-byte). This
# avoids the fetchgit+leaveDotGit non-determinism (the .git/ packfile
# format varies across nixpkgs/git versions, producing fetch-time hash
# churn even though git archive's output doesn't depend on packing).
{ runCommand, gcc, gzip, zlib }:
{ version, src, expectedSha256 ? null }:

runCommand "bitcoin-${version}.tar.gz"
{
  nativeBuildInputs = [ gcc gzip ];
} ''
  ${gzip}/bin/gunzip -c ${src} > archive.tar

  $CC -O2 ${./gzip6.c} -I${zlib.dev}/include -L${zlib}/lib -lz -Wl,-rpath,${zlib}/lib -o gzip6
  ./gzip6 archive.tar "$out"

  ${if expectedSha256 == null then ''
    echo "BUILT (no upstream gate): bitcoin-${version}.tar.gz $(sha256sum "$out" | cut -d' ' -f1)"
  '' else ''
    actual=$(sha256sum "$out" | cut -d' ' -f1)
    if [ "$actual" != "${expectedSha256}" ]; then
      echo "FAIL: bitcoin-${version}.tar.gz sha256 does not match upstream guix.sigs"
      echo "  expected: ${expectedSha256}"
      echo "  actual:   $actual"
      exit 1
    fi
    echo "OK: bitcoin-${version}.tar.gz matches upstream ($actual)"
  ''}
''
