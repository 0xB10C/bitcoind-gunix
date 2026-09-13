# Cross-build a full Bitcoin Core v31.0 *-apple-darwin release from Linux
# (all 10 Mach-O binaries + the Bitcoin-Qt.app deploy bundle), aiming
# byte-for-byte at the upstream GUIX release's -unsigned artifacts.
#
# Structurally much simpler than the Linux targets (see CLAUDE.md macOS
# status): GUIX's darwin toolchain is bare clang/lld 19.1.4 + the Xcode
# SDK — no custom gcc/glibc — and build.sh UNSETS HOST_CFLAGS/CXXFLAGS/
# LDFLAGS for darwin, so the entire flag set comes from depends'
# toolchain.cmake (darwin.mk) + bitcoin's own CMake defaults. There is no
# -g anywhere, hence no .dbg/split-debug, and `cmake --install --strip`
# (CMAKE_STRIP = llvm-strip via the toolchain) strips at install time.
#
# THE BUILD RUNS INSIDE A USER-NAMESPACE CHROOT at GUIX's literal paths.
# Reason: lld computes LC_UUID as an xxhash of the UNSTRIPPED output (+
# the output basename) BEFORE the install-time strip. The unstripped
# image contains the linker's debug-map stabs — N_SO (absolute source
# paths) and N_OSO (absolute object/archive paths) for bitcoin's own
# TUs — which the strip removes, leaving the UUID as a fossil of the
# build paths. No flag can rewrite the stabs (they are linker-recorded
# argv/compile paths, not DWARF), so the only way to upstream's UUID is
# to make the unstripped image byte-identical: build at GUIX's DISTSRC
# (/distsrc-base/distsrc-<ver>-<host>) with depends visible at
# /bitcoin/depends/<host>. The Nix sandbox root is read-only, but user
# namespaces ARE available inside the sandbox: unshare + a bind-mounted
# new root + chroot recreate GUIX's path layout exactly. (Only bitcoin's
# own TUs emit stabs — depends archives contribute none, verified — so
# the DEPENDS build needs no such treatment.)
#
# With the chroot alone, 8 of 10 binaries matched upstream including
# LC_UUID; bitcoin-qt/bitcoin-gui still diverged in their UUID. Root
# cause: qtbase_plugins_cocoa.patch disables precompiled headers for
# QCocoaIntegrationPlugin only when `CMAKE_VERSION VERSION_LESS "3.25"
# AND NOT QT_FEATURE_sessionmanager` — bitcoin's qt.mk disables
# sessionmanager unconditionally, so the guard reduces to the cmake
# version check. GUIX builds depends with cmake-minimal 3.24.2 (guard
# fires, PCH disabled); nixpkgs' cmake is >=3.25 (guard never fires, PCH
# stays enabled). PCH usage doesn't change qnsview.mm's .text/.data but
# shifts the unstripped image's Objective-C selector/class-ref symtab
# numbering enough to flip LC_UUID. Fixed in lib/depends.nix's darwin
# postPatch: drop the `CMAKE_VERSION VERSION_LESS "3.25" AND ` clause so
# PCH is disabled unconditionally, matching GUIX's effective cmake-3.24.2
# behavior — a build-configuration fix, no byte/UUID patching needed.
#
# We bypass nixpkgs' cmake setup-hook entirely (dontUseCmakeConfigure):
# it unconditionally injects -DCMAKE_C_COMPILER=$CC, which would override
# the toolchain.cmake's multi-token `clang --target=… -isysroot…` (its
# CMAKE_C_COMPILER is guarded by `if(NOT DEFINED …)`). Running cmake by
# hand also means bitcoin's own CMAKE_BUILD_TYPE default applies — the
# same parity-by-construction GUIX gets by passing no build type.
{ lib
, gcc14Stdenv
, fetchurl
, cmake
, python3 # macdeployqtplus + package.sh's lief-based checks
, zip # Info-ZIP 3.0, same as GUIX's `zip` — makes dist/bitcoin-macos-app.zip
, util-linux # unshare, for the chroot illusion
, version
, src
, depends # the target's darwin depends tree WITH Qt (build_macos_gui.sh)
, dependsNoQt # the same tree built NO_QT=1 (build_macos.sh)
, crossInputs # clangDarwin/lldDarwin/llvmDarwin — bare tools on PATH
, hostTriple # "x86_64-apple-darwin" | "arm64-apple-darwin"
, sourceDateEpoch
, pname
}:

let
  distsrc = "/distsrc-base/distsrc-${version}-${hostTriple}";
in
gcc14Stdenv.mkDerivation {
  inherit pname;
  name = pname;
  inherit src;

  # python3 runs macdeployqtplus (the `deploy` target) AND package.sh's
  # security-check.py / symbol-check.py, which import lief.
  nativeBuildInputs = [
    cmake (python3.withPackages (ps: [ ps.lief ])) zip util-linux
  ] ++ crossInputs;

  outputs = [ "out" "dist" ];

  dontUseCmakeConfigure = true;

  # GUIX SOURCE_DATE_EPOCH (the built commit's time). Used by
  # macos_zip.sh to normalize the mtimes inside bitcoin-macos-app.zip;
  # nix's stdenv default would be 315532800. Was hardcoded to v31.0's
  # 1776286524 until the v32.x branch-off — plumb it from default.nix so a
  # version bump cannot leave a stale epoch in the app zip.
  env.SOURCE_DATE_EPOCH = toString sourceDateEpoch;

  # configure+build+install+deploy all run inside one chroot entry (the
  # mount namespace lives only as long as the unshare invocation).
  buildPhase = ''
    runHook preBuild

    # The script that runs INSIDE the chroot, at GUIX's literal paths.
    # build.sh (darwin): no CC/CXX env for the cmake invocation and
    # HOST_CFLAGS/HOST_CXXFLAGS/HOST_LDFLAGS unset — everything comes
    # from the toolchain file (referenced via /bitcoin/depends/<host>,
    # whose CMAKE_CURRENT_LIST_DIR-relative contents then spell every
    # depends path exactly like GUIX's BASEPREFIX).
    # Upstream's libexec/setup.sh (with the Nix-sandbox rewrites — see
    # nix/lib/guix-setup.sh) and its libexec/package.sh, minus package.sh's
    # trailing outdir bookkeeping (a hardcoded /outdir-base the read-only
    # sandbox root has no room for, plus a SHA256SUMS.part over a
    # dist-archive we do not build). Both are prepared out here and run
    # inside the chroot. nix/lib/package.nix does the same for every other
    # target; darwin's package.sh has to run INSIDE this derivation because
    # its `deploy` target needs the GUI pass's cmake build tree.
    up="$NIX_BUILD_TOP/bitcoin-${version}/contrib/guix/libexec"
    bash ${../lib/guix-setup.sh} "$up/setup.sh" "$NIX_BUILD_TOP/setup.sh"
    grep -qx 'rm -rf "$ACTUAL_OUTDIR"' "$up/package.sh" \
      || { echo "package.sh no longer ends with the expected outdir block"; exit 1; }
    sed -n '/^rm -rf "\$ACTUAL_OUTDIR"$/q;p' "$up/package.sh" \
      > "$NIX_BUILD_TOP/package-artifacts.sh"

    mkdir -p "$NIX_BUILD_TOP/dist-archive"
    # setup.sh would `git archive` this if it were missing; ours is a
    # repack of the same tree under the same prefix, and nothing that runs
    # here reads it (only the SHA256SUMS.part block we cut does).
    ln -sfn ${src} "$NIX_BUILD_TOP/dist-archive/bitcoin-${version}.tar.gz"

    cat > "$NIX_BUILD_TOP/inner-build.sh" <<INNEREOF
    set -euo pipefail
    unset CC CXX CFLAGS CXXFLAGS LDFLAGS
    cd ${distsrc}

    # The environment libexec/setup.sh expects to be handed, then setup.sh
    # itself: it renames this OUTDIR to ACTUAL_OUTDIR, points OUTDIR at
    # \$DISTSRC/output and sets INSTALLPATH, TAR_OPTIONS, TZ and the umask.
    export HOST=${hostTriple}
    export DISTNAME=bitcoin-${version}
    export JOBS=\$NIX_BUILD_CORES
    export DISTSRC=${distsrc}
    export OUTDIR=\$dist
    export DIST_ARCHIVE_BASE=$NIX_BUILD_TOP/dist-archive
    # setup.sh tests \$V unguarded (guix's container shell has no nounset).
    set +u
    source "$NIX_BUILD_TOP/setup.sh"
    set -u
    mkdir -p "\$INSTALLPATH"

    # mpgen's baked capnp_PREFIX is the depends build-time path
    # (/build/bitcoin-<ver>/depends/<triple>); the source tree is ALSO
    # still bind-visible at /build/bitcoin-<ver>, so this one symlink
    # serves both spellings. It is re-pointed between the two passes,
    # mirroring the two depends trees GUIX builds under separate
    # BASE_CACHEs into the same physical depends/<triple> prefix.
    mkdir -p depends

    # --- pass 1: build_macos.sh (everything except the GUI) ---
    ln -sfn ${dependsNoQt} depends/${hostTriple}
    ln -sfn ${dependsNoQt} /bitcoin/depends/${hostTriple}

    cmake -S . -B build \
      --toolchain /bitcoin/depends/${hostTriple}/toolchain.cmake \
      -DBUILD_BENCH=OFF \
      -DBUILD_FUZZ_BINARY=OFF \
      -DBUILD_GUI=OFF \
      -DBUILD_GUI_TESTS=OFF \
      -DCMAKE_INSTALL_PREFIX="\$INSTALLPATH" \
      -DCMAKE_SKIP_RPATH=TRUE \
      -DREDUCE_EXPORTS=ON \
      -DWITH_CCACHE=OFF

    cmake --build build -j \$NIX_BUILD_CORES

    # --strip runs CMAKE_STRIP (= llvm-strip, recorded in toolchain.cmake
    # by darwin.mk) over every installed binary — this IS upstream's
    # stripping; package.sh runs no split-debug step on darwin.
    # (build.sh's \`cmake_install.cmake -u -r\` sed is gone: upstream
    # dropped that CMake < 3.27 workaround at the v32.x branch-off.)
    cmake --install build --strip

    rm -rf build

    # --- pass 2: build_macos_gui.sh (bitcoin-gui + bitcoin-qt only) ---
    ln -sfn ${depends} depends/${hostTriple}
    ln -sfn ${depends} /bitcoin/depends/${hostTriple}

    cmake -S . -B build \
      --toolchain /bitcoin/depends/${hostTriple}/toolchain.cmake \
      -DBUILD_BENCH=OFF \
      -DBUILD_BITCOIN_BIN=OFF \
      -DBUILD_CLI=OFF \
      -DBUILD_DAEMON=OFF \
      -DBUILD_FUZZ_BINARY=OFF \
      -DBUILD_GUI_TESTS=OFF \
      -DBUILD_TESTS=OFF \
      -DBUILD_TX=OFF \
      -DBUILD_UTIL=OFF \
      -DBUILD_WALLET_TOOL=OFF \
      -DCMAKE_INSTALL_PREFIX="\$INSTALLPATH" \
      -DCMAKE_SKIP_RPATH=TRUE \
      -DREDUCE_EXPORTS=ON \
      -DWITH_CCACHE=OFF \
      -Werror=dev

    cmake --build build -j \$NIX_BUILD_CORES --target bitcoin-gui bitcoin-qt

    cmake --install build --strip --component bitcoin-gui
    cmake --install build --strip --component bitcoin-qt

    # build_macos_gui.sh ends by sourcing package.sh: the security/symbol
    # checks, the -unsigned.tar.gz, the \`deploy\` target (macdeployqtplus
    # builds dist/Bitcoin-Qt.app and cmake/script/macos_zip.sh zips it) →
    # -unsigned.zip, and the -codesigning.tar.gz.
    bash "$NIX_BUILD_TOP/package-artifacts.sh"

    # macdeployqtplus copies Qt's translations (Contents/Resources/qt_*.qm)
    # straight from the read-only Nix store, so they land mode 0444 and the
    # zip records the DOS read-only bit (external_attr 0x81240001).
    # Upstream's GUIX deploy has them 0644 (0x81a40000). Lift the bundle to
    # owner-writable and rebuild the zip with the same macos_zip.sh — a
    # no-op for the already-0755/0644 entries. (The -codesigning.tar.gz
    # carries the same bundle but tar's --mode normalizes it, so only the
    # zip needs this.) package.sh has already moved dist/ into
    # unsigned-app-<host>/ by this point.
    chmod -R u+w "unsigned-app-${hostTriple}/dist/Bitcoin-Qt.app"
    rm -f "unsigned-app-${hostTriple}/dist/bitcoin-macos-app.zip"
    ( cd "unsigned-app-${hostTriple}/dist" \
      && ${distsrc}/cmake/script/macos_zip.sh "\$(command -v zip)" bitcoin-macos-app.zip )
    mv "unsigned-app-${hostTriple}/dist/bitcoin-macos-app.zip" \
       "\$OUTDIR/bitcoin-${version}-${hostTriple}-unsigned.zip"

    mkdir -p \$out \$dist
    cp -a "\$INSTALLPATH/." \$out/
    cp -a "\$OUTDIR/." \$dist/
    INNEREOF

    # Assemble the new root and enter it. /nix/store (rw — $out/$dist
    # live there), the build top, /proc, /dev and the sandbox's /bin
    # and /usr (sh, env) are bind-mounted; the unpacked source tree is
    # bound at GUIX's DISTSRC and the depends store path symlinked at
    # GUIX's BASEPREFIX/<host>.
    cat > "$NIX_BUILD_TOP/enter-chroot.sh" <<CHROOTEOF
    set -euo pipefail
    nr="$NIX_BUILD_TOP/nr"
    mkdir -p "\$nr/nix/store" "\$nr/proc" "\$nr/dev" "\$nr/bin" "\$nr/usr" \
      "\$nr$NIX_BUILD_TOP" "\$nr${distsrc}" "\$nr/bitcoin/depends" "\$nr/tmp" "\$nr/etc"
    mount --rbind /nix/store "\$nr/nix/store"
    mount --rbind /proc "\$nr/proc"
    mount --rbind /dev "\$nr/dev"
    mount --rbind /bin "\$nr/bin"
    if [ -d /usr ]; then mount --rbind /usr "\$nr/usr"; fi
    mount --rbind "$NIX_BUILD_TOP" "\$nr$NIX_BUILD_TOP"
    mount --bind "$NIX_BUILD_TOP/bitcoin-${version}" "\$nr${distsrc}"
    ln -sfn ${depends} "\$nr/bitcoin/depends/${hostTriple}"
    exec chroot "\$nr" bash "$NIX_BUILD_TOP/inner-build.sh"
    CHROOTEOF

    unshare --user --map-root-user --mount bash "$NIX_BUILD_TOP/enter-chroot.sh"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # installation happened inside the chroot (buildPhase)
    runHook postInstall
  '';

  # No per-binary gate: upstream publishes no per-binary hashes, and the
  # archives package.sh produced are gated downstream (nix/lib/artifact.nix)
  # against the checked-in SHA256SUMS. Print every hash for the log — that
  # is what localizes an archive divergence to one binary.
  postFixup = ''
    echo "BUILT (no per-binary upstream gate — archive gates downstream): ${hostTriple}"
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-qt bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet \
      libexec/bitcoin-gui libexec/bitcoin-node libexec/test_bitcoin; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "FAIL: $rel was not built"; exit 1; fi
      echo "  $rel  $(sha256sum "$f" | cut -d' ' -f1)"
    done
    echo "PACKAGED ${hostTriple}:"
    for f in "$dist"/*; do
      echo "  $(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")"
    done
  '';

  dontStrip = true;
  # package.sh ran inside the chroot over INSTALLPATH; $out is a copy of
  # that tree, so nixpkgs' fixup must not gzip its man pages either.
  dontGzipMan = true;
  doCheck = false;
  enableParallelBuilding = true;
}
