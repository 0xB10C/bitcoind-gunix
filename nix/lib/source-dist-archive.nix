# Reproduce bitcoin-<version>.tar.gz (the source dist-archive that appears
# in upstream's all.SHA256SUMS / noncodesigned.SHA256SUMS as
# `dist-archive/bitcoin-<version>.tar.gz`).
#
# build.sh:
#   git -C "$DISTSRC" archive --format=tar --prefix="$DISTNAME"/ HEAD \
#     | gzip -n > "$OUTDIR_BASE/dist-archive/${DISTNAME}.tar.gz"
#
# Same machinery as codesignatures.nix:
# - `git archive --format=tar HEAD` is git-version-stable (verified
#   byte-identical regardless of git version).
# - Only the gzip step matters; nixpkgs' zlib 1.3.2 + a tiny C helper
#   that calls zlib's gzFile API at compression level 6 reproduces
#   GUIX's gzip 1.13 + zlib 1.3 output exactly.
#
# v31.1rc1 has no published bitcoincore.org release tarball, so we fetch
# the source directly from the bitcoin/bitcoin GitHub repo at the v31.1rc1
# commit and regenerate the dist-archive locally. The output byte-matches
# the GUIX-built dist-archive (50c15294... per achow101's all.SHA256SUMS).
{ runCommand, gcc, git, zlib, fetchgit }:
{ version }:
let
  src = fetchgit {
    url = "https://github.com/bitcoin/bitcoin";
    rev = "efde623463cf194dda8407271f4dd136d054bc9f"; # v31.1rc1
    leaveDotGit = true;
    hash = "sha256-DJyyki8SLNDNOcAW02yH9Gzq3mOICdBr9W5TCd49EJ0=";
  };
in
runCommand "bitcoin-${version}.tar.gz"
{
  nativeBuildInputs = [ gcc git ];
} ''
  cp -r ${src} ./repo
  cd repo
  git archive --format=tar --prefix=bitcoin-${version}/ HEAD > ../archive.tar
  cd ..

  $CC -O2 ${./gzip6.c} -I${zlib.dev}/include -L${zlib}/lib -lz -Wl,-rpath,${zlib}/lib -o gzip6
  ./gzip6 archive.tar "$out"
''
