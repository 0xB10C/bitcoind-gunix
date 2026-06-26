# Reproduce bitcoin-<version>-codesignatures-<version>.tar.gz byte-for-byte:
# contrib/guix/libexec/codesign.sh's
#   git -C "$DETACHED_SIGS_REPO" archive --output="$CODESIGNATURE_GIT_ARCHIVE" HEAD
# (a plain `git archive`, no --prefix; the filename's version comes from
# `git describe --exact-match HEAD` with the leading 'v' stripped, i.e. the
# v31.0 tag -> "31.0").
#
# `git archive --format=tar HEAD` is independent of the git version used --
# the tar format, the default tar.umask=0002 mode adjustment, and the
# commit-date mtimes are all stable across git versions (verified
# byte-identical to the tar embedded in upstream's published archive,
# regardless of git version). Only the gzip step is version-sensitive:
# `git archive --output=*.tar.gz` gzip-compresses via zlib's gzFile API, and
# GNU gzip's own bundled deflate / zlib-ng both produce DIFFERENT bytes than
# plain zlib for the same input. nixpkgs' zlib 1.3.2 reproduces GUIX's
# zlib 1.3 output exactly (verified byte-for-byte against the published
# artifact) via gzip6.c.
{ runCommand, gcc, git, zlib }:
{ name, src, expectedSha256 ? null }:
runCommand name
{
  nativeBuildInputs = [ gcc git ];
} ''
  cp -r ${src} ./repo
  cd repo
  git archive --format=tar HEAD > ../archive.tar
  cd ..

  $CC -O2 ${./gzip6.c} -I${zlib.dev}/include -L${zlib}/lib -lz -Wl,-rpath,${zlib}/lib -o gzip6
  ./gzip6 archive.tar "$out"

  ${if expectedSha256 == null then ''
    echo "BUILT (no upstream gate): ${name} $(sha256sum "$out" | cut -d' ' -f1)"
  '' else ''
    actual=$(sha256sum "$out" | cut -d' ' -f1)
    if [ "$actual" != "${expectedSha256}" ]; then
      echo "FAIL: ${name} sha256 does not match upstream guix.sigs"
      echo "  expected: ${expectedSha256}"
      echo "  actual:   $actual"
      exit 1
    fi
    echo "OK: ${name} matches upstream ($actual)"
  ''}
''
