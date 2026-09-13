#!/usr/bin/env bash
# Emit a Nix-sandbox-safe copy of upstream's contrib/guix/libexec/setup.sh.
#
# setup.sh is the environment every contrib/guix/libexec/build_*.sh sources:
# LC_ALL, TZ, umask, TAR_OPTIONS, the required-variable check, ACTUAL_OUTDIR
# / OUTDIR / INSTALLPATH / BASEPREFIX, the GIT_ARCHIVE creation, and the
# helper functions (glibc_dynamic_linker, store_path, the toolchain setups).
# We source it rather than restating any of that, but two lines cannot run
# as written under Nix, and one crashes GNU tar. Both rewrites are made
# here, in one place, and verified to have applied.
#
#   1-2. `[ -e /usr/bin ] || mkdir -p /usr/bin` and the /usr/bin/env symlink
#        next to it. The Nix sandbox root is a read-only mount with no /usr,
#        and creating one is denied even for the build user, so these abort
#        the script under `set -o errexit`. They exist to make `#!/usr/bin/env`
#        shebangs resolve inside GUIX's container; under Nix the interpreters
#        are absolute store paths (patchShebangs) or explicit (`python3 x.py`,
#        `bash x.sh`), and /bin/sh exists, so dropping them changes nothing.
#
#   3.   TAR_OPTIONS quotes the --mtime date: `--mtime='@${SOURCE_DATE_EPOCH}'`.
#        GNU tar 1.35 as built in nixpkgs ABORTS parsing that out of the
#        environment — "*** buffer overflow detected ***", exit 134 — so the
#        quotes are removed. Unquoted it pins the mtime as intended, which is
#        demonstrably the value upstream's archives carry: our v31.0/v31.1
#        archives byte-matched them while passing --mtime=@epoch explicitly.
#
# usage: guix-setup.sh <upstream setup.sh> <output path>
set -o errexit -o nounset -o pipefail

src=$1
out=$2

sed -e '/^\[ -e \/usr\/bin \] || mkdir -p \/usr\/bin$/d' \
    -e '/^\[ -e \/usr\/bin\/env \] *|| ln -s --no-dereference .*\/usr\/bin\/env$/d' \
    -e 's|--mtime=.@${SOURCE_DATE_EPOCH}.|--mtime=@${SOURCE_DATE_EPOCH}|' \
    "$src" > "$out"

dropped=$(( $(wc -l < "$src") - $(wc -l < "$out") ))
if [ "$dropped" -ne 2 ]; then
    echo "guix-setup.sh: expected to drop exactly 2 /usr/bin lines from setup.sh, dropped $dropped" >&2
    exit 1
fi
if ! grep -q -- '--mtime=@${SOURCE_DATE_EPOCH}' "$out" \
   || grep -q -- "--mtime='@" "$out"; then
    echo "guix-setup.sh: setup.sh's TAR_OPTIONS --mtime no longer looks as expected" >&2
    exit 1
fi
