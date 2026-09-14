# Run UPSTREAM's contrib/guix/libexec/package.sh over the merged install
# tree, instead of reimplementing what it does.
#
# package.sh is what turns the installed prefix into the published
# artifacts: it runs the security/symbol checks, splits the debug info off
# every binary, copies the committed extras (README.md, INSTALL.md,
# bitcoin.conf, share/rpcauth, readme.txt on win64) and produces the
# release/debug archives, the win64 NSIS installer and the codesigning
# tarballs. Reproducing those by hand means re-deriving upstream's exact
# find/sort/tar/zip invocations and file selections on every release; this
# way a change like "the linux tarball now ships INSTALL.md" just happens.
#
# We run it VERBATIM up to its final outdir bookkeeping — everything from
# its trailing `rm -rf "$ACTUAL_OUTDIR"` on is cut, because that block
# moves OUTDIR into place and then writes a SHA256SUMS.part from a
# hardcoded /outdir-base (not creatable under the read-only Nix sandbox
# root) whose first entry is the dist-archive we do not build. We do the
# move ourselves instead; $out IS package.sh's OUTDIR.
#
# The two deviations from libexec/setup.sh's environment:
#
#   * TAR_OPTIONS drops the QUOTES around the --mtime date. GNU tar 1.35 as
#     built in nixpkgs aborts outright ("*** buffer overflow detected ***")
#     when it parses `--mtime='@<epoch>'` out of TAR_OPTIONS; unquoted it
#     pins the mtime as intended, which is demonstrably the value upstream's
#     archives carry (our v31.0/v31.1 archives byte-matched them while
#     passing --mtime=@epoch explicitly).
#   * DISTSRC is a plain build-directory path rather than GUIX's
#     /distsrc-base/distsrc-<version>-<host>. Nothing is compiled here, so
#     no path is recorded anywhere: the archives hold DISTNAME-relative
#     paths and the NSIS installer embeds file CONTENT, not source paths.
#
# The pieces cmake would have generated into the build tree are generated
# here the same way cmake's configure_file() does, since the build tree
# itself is not carried between derivations:
#   * build/split-debug.sh            from contrib/devtools/split-debug.sh.in
#   * build/GenerateWindowsInstaller.cmake (mingw only)
#                                     from cmake/script/GenerateWindowsInstaller.cmake.in
# Their @VARS@ come from the source tree's own CMakeLists.txt, so a version
# bump needs no edit here.
{ lib
, stdenv
, coreutils
, findutils
, gnutar
, gzip
, zip
, python3
, python3Packages
, cmake
, version
, src
, hostTriple # GUIX $HOST, e.g. "x86_64-linux-gnu" / "x86_64-w64-mingw32"
, sourceDateEpoch
, noGui # build_<os>.sh's install tree
, gui # build_<os>_gui.sh's install tree
, crossInputs # cross bintools (<hostTriple>-objcopy/-strip for split-debug.sh)
, pname
# mingw only: makensis for GenerateWindowsInstaller.cmake's find_program.
, nsis ? null
}:

let
  isMingw = lib.hasInfix "mingw" hostTriple;
in
stdenv.mkDerivation {
  inherit pname;
  name = pname;
  dontUnpack = true;
  dontFixup = true;
  # cmake is an input on mingw only for package.sh's `cmake -P`; without
  # this its setup hook would try to configure a project in the build dir.
  dontUseCmakeConfigure = true;

  nativeBuildInputs = [
    coreutils findutils gnutar gzip zip
    # symbol-check.py / security-check.py import lief and nothing else.
    (python3.withPackages (ps: [ ps.lief ]))
  ] ++ crossInputs
    ++ lib.optionals isMingw [ cmake nsis ];

  buildPhase = ''
    runHook preBuild

    # --- the environment libexec/setup.sh expects to be handed ----------
    export HOST=${hostTriple}
    export DISTNAME=bitcoin-${version}
    export SOURCE_DATE_EPOCH=${toString sourceDateEpoch}
    export JOBS=''${NIX_BUILD_CORES:-1}
    export DISTSRC=$PWD/distsrc
    # setup.sh renames the incoming OUTDIR to ACTUAL_OUTDIR and points
    # OUTDIR at $DISTSRC/output, exactly as guix-build hands it in.
    export OUTDIR=$out
    export DIST_ARCHIVE_BASE=$PWD/dist-archive

    umask 0022
    mkdir -p "$DISTSRC" "$DIST_ARCHIVE_BASE"
    tar --strip-components=1 -xf ${src} -C "$DISTSRC"

    # setup.sh creates $DIST_ARCHIVE_BASE/$DISTNAME.tar.gz with `git archive`
    # when it is missing — there is no git repo here, and nothing this
    # derivation runs reads the file (only the SHA256SUMS.part block we cut
    # does). Put our own source tarball there so the branch is skipped: it
    # is a repack of the same `git archive` tree under the same prefix.
    ln -s ${src} "$DIST_ARCHIVE_BASE/$DISTNAME.tar.gz"

    cd "$DISTSRC"

    # Upstream's setup.sh, with the three rewrites the Nix sandbox forces
    # (see nix/lib/guix-setup.sh for what and why). Sourcing it gives us
    # its LC_ALL/TZ/umask/TAR_OPTIONS, the required-variable check, and
    # ACTUAL_OUTDIR / OUTDIR / INSTALLPATH / BASEPREFIX.
    bash ${./guix-setup.sh} contrib/guix/libexec/setup.sh "$NIX_BUILD_TOP/setup.sh"
    source "$NIX_BUILD_TOP/setup.sh"

    mkdir -p "$INSTALLPATH" "$DISTSRC/build"

    # cmake's configure_file(contrib/devtools/split-debug.sh.in) — package.sh
    # calls the result, and the build tree it would live in is not carried
    # between derivations.
    sed -e 's|@OBJCOPY@|${hostTriple}-objcopy|g' \
        -e 's|@STRIP@|${hostTriple}-strip|g' \
        "$DISTSRC/contrib/devtools/split-debug.sh.in" > "$DISTSRC/build/split-debug.sh"
    chmod +x "$DISTSRC/build/split-debug.sh"
    grep -q '@OBJCOPY@\|@STRIP@' "$DISTSRC/build/split-debug.sh" \
      && { echo "split-debug.sh.in has unsubstituted vars"; exit 1; }

    # The merged install prefix: upstream's two passes install into the
    # same directory, so copy pass 1's tree and then pass 2's over it.
    # Store trees are r-x/r--; u+w lifts them to the 0755/0644 that cmake
    # installed (and that the zip records in its external attributes).
    cp -a ${noGui}/. "$INSTALLPATH/"
    chmod -R u+w "$INSTALLPATH"
    cp -a ${gui}/. "$INSTALLPATH/"
    chmod -R u+w "$INSTALLPATH"
  '' + lib.optionalString (!isMingw) ''

    # Normalize the linked producer stamp to GUIX's gcc. Believed to be a
    # no-op since glibc 2.31 moved to gcc-14 (CLAUDE.md's glibc section) —
    # kept because it is cheap, and applied BEFORE package.sh so the .dbg
    # that split-debug.sh derives sees the same section. PE/COFF has no
    # .comment, so mingw skips it.
    printf 'GCC: (GNU) 14.3.0\0' > "$NIX_BUILD_TOP/comment.bin"
    find "$INSTALLPATH/bin" "$INSTALLPATH/libexec" -type f -executable \
      -exec ${hostTriple}-objcopy --update-section .comment="$NIX_BUILD_TOP/comment.bin" {} \;
  '' + lib.optionalString isMingw ''

    # cmake's configure_file(cmake/script/GenerateWindowsInstaller.cmake.in).
    # Every @VAR@ comes out of the source tree's own CMakeLists.txt, so this
    # needs no maintenance across version bumps.
    cml="$DISTSRC/CMakeLists.txt"
    getset() { sed -n "s/^set($1 \"\\?\([^\")]*\)\"\\?)\$/\1/p" "$cml" | head -1; }
    CLIENT_NAME=$(getset CLIENT_NAME)
    CLIENT_VERSION_MAJOR=$(getset CLIENT_VERSION_MAJOR)
    CLIENT_VERSION_MINOR=$(getset CLIENT_VERSION_MINOR)
    CLIENT_VERSION_BUILD=$(getset CLIENT_VERSION_BUILD)
    CLIENT_VERSION_RC=$(getset CLIENT_VERSION_RC)
    COPYRIGHT_YEAR=$(getset COPYRIGHT_YEAR)
    CLIENT_VERSION_STRING="$CLIENT_VERSION_MAJOR.$CLIENT_VERSION_MINOR.$CLIENT_VERSION_BUILD"
    if [ "$CLIENT_VERSION_RC" -gt 0 ]; then
      CLIENT_VERSION_STRING="''${CLIENT_VERSION_STRING}rc$CLIENT_VERSION_RC"
    fi
    PROJECT_HOMEPAGE_URL=$(sed -n 's/^ *HOMEPAGE_URL "\(.*\)"$/\1/p' "$cml" | head -1)
    for v in CLIENT_NAME CLIENT_VERSION_MAJOR CLIENT_VERSION_MINOR \
             CLIENT_VERSION_BUILD COPYRIGHT_YEAR PROJECT_HOMEPAGE_URL; do
      [ -n "''${!v}" ] || { echo "could not read $v from CMakeLists.txt"; exit 1; }
    done
    echo "NSIS: CLIENT_VERSION_STRING=$CLIENT_VERSION_STRING COPYRIGHT_YEAR=$COPYRIGHT_YEAR"

    sed -e "s|@CLIENT_NAME@|$CLIENT_NAME|g" \
        -e "s|@CLIENT_VERSION_MAJOR@|$CLIENT_VERSION_MAJOR|g" \
        -e "s|@CLIENT_VERSION_MINOR@|$CLIENT_VERSION_MINOR|g" \
        -e "s|@CLIENT_VERSION_BUILD@|$CLIENT_VERSION_BUILD|g" \
        -e "s|@CLIENT_VERSION_STRING@|$CLIENT_VERSION_STRING|g" \
        -e "s|@PROJECT_HOMEPAGE_URL@|$PROJECT_HOMEPAGE_URL|g" \
        -e "s|@COPYRIGHT_YEAR@|$COPYRIGHT_YEAR|g" \
        -e "s|@COPYRIGHT_HOLDERS_FINAL@|The $CLIENT_NAME developers|g" \
        -e "s|@PROJECT_SOURCE_DIR@|$DISTSRC|g" \
        -e "s|@CMAKE_EXECUTABLE_SUFFIX@|.exe|g" \
        "$DISTSRC/cmake/script/GenerateWindowsInstaller.cmake.in" \
        > "$DISTSRC/build/GenerateWindowsInstaller.cmake"
    grep -q '@[A-Z_]*@' "$DISTSRC/build/GenerateWindowsInstaller.cmake" \
      && { echo "GenerateWindowsInstaller.cmake.in has unsubstituted vars"; exit 1; }
  '' + ''

    # Upstream's package.sh, minus its trailing outdir bookkeeping.
    ps="$DISTSRC/contrib/guix/libexec/package.sh"
    grep -qx 'rm -rf "$ACTUAL_OUTDIR"' "$ps" \
      || { echo "package.sh no longer ends with the expected outdir block"; exit 1; }
    sed -n '/^rm -rf "\$ACTUAL_OUTDIR"$/q;p' "$ps" > "$NIX_BUILD_TOP/package-artifacts.sh"

    bash "$NIX_BUILD_TOP/package-artifacts.sh"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # package.sh's own final step, the one line we cut off it:
    # ACTUAL_OUTDIR is $out (setup.sh renamed the OUTDIR we handed in).
    mv --no-target-directory "$OUTDIR" "$ACTUAL_OUTDIR"
    echo "PACKAGED ${hostTriple} (no upstream gate — see default.nix):"
    for f in "$out"/*; do
      echo "  $(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")"
    done
    runHook postInstall
  '';

  # The install tree with its .dbg files, for the per-binary diffing that
  # localizes an archive divergence. package.sh split the debug info out of
  # $INSTALLPATH in place, so this is exactly what the archives were made
  # from.
  postInstall = ''
    mkdir -p "$installed"
    cp -a "$INSTALLPATH/." "$installed/"
  '';
  outputs = [ "out" "installed" ];

  doCheck = false;
  enableParallelBuilding = true;
}
