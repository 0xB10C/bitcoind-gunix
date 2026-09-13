# Pick one published artifact out of a package.sh output directory and,
# when a reference hash is known, gate it byte-for-byte.
#
# contrib/guix/libexec/package.sh produces all of a host's artifacts in one
# OUTDIR (see nix/lib/package.nix), so the per-artifact flake attrs are thin
# selections from it rather than separate assembly derivations. Keeping them
# separate keeps the CI job layout, the Cachix granularity and the
# one-gate-per-published-file structure.
{ runCommandLocal }:
{ packaged # the package.nix derivation (its default output IS the OUTDIR)
, file # published filename, e.g. "bitcoin-<ver>-x86_64-linux-gnu.tar.gz"
, expectedSha256 ? null # null = no reference hash checked in; gate skipped
}:

runCommandLocal file { } (''
  if [ ! -f "${packaged}/${file}" ]; then
    echo "FAIL: package.sh did not produce ${file}; it produced:"
    ls -1 "${packaged}"
    exit 1
  fi
  cp "${packaged}/${file}" "$out"
  actual=$(sha256sum "$out" | cut -d' ' -f1)
'' + (if expectedSha256 == null then ''
  echo "BUILT: ${file} ($actual) — no upstream gate (not in the checked-in SHA256SUMS)"
'' else ''
  if [ "$actual" != "${expectedSha256}" ]; then
    echo "FAIL: ${file} does not match the upstream GUIX build"
    echo "  expected: ${expectedSha256}"
    echo "  actual:   $actual"
    exit 1
  fi
  echo "OK: ${file} matches upstream ($actual)"
''))
