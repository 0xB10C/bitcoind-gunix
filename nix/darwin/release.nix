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
, python3 # macdeployqtplus (the `deploy` target)
, zip # Info-ZIP 3.0, same as GUIX's `zip` — makes dist/bitcoin-macos-app.zip
, util-linux # unshare, for the chroot illusion
, version
, url
, sha256
, depends # the target's darwin depends tree (Qt included)
, crossInputs # clangDarwin/lldDarwin/llvmDarwin — bare tools on PATH
, hostTriple # "x86_64-apple-darwin" | "arm64-apple-darwin"
# {} = no per-binary upstream hashes published (upstream's SHA256SUMS
# covers only the assembled archives, gated downstream) — gate skipped.
, expectedHashes ? { }
, withGate ? true # disable to keep diverging outputs for diffing
, pname
}:

let
  distsrc = "/distsrc-base/distsrc-${version}-${hostTriple}";
in
gcc14Stdenv.mkDerivation {
  inherit pname;
  name = pname;
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ cmake python3 zip util-linux ] ++ crossInputs;

  outputs = [ "out" "dist" ];

  dontUseCmakeConfigure = true;

  # GUIX SOURCE_DATE_EPOCH (the v31.0 commit time). Used by macos_zip.sh
  # to normalize the mtimes inside bitcoin-macos-app.zip; nix's stdenv
  # default would be 315532800.
  env.SOURCE_DATE_EPOCH = "1776286524";

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
    cat > "$NIX_BUILD_TOP/inner-build.sh" <<INNEREOF
    set -euo pipefail
    unset CC CXX CFLAGS CXXFLAGS LDFLAGS
    cd ${distsrc}

    # mpgen's baked capnp_PREFIX is the depends build-time path
    # (/build/bitcoin-<ver>/depends/<triple>); the source tree is ALSO
    # still bind-visible at /build/bitcoin-<ver>, so this one symlink
    # serves both spellings.
    mkdir -p depends
    ln -sfn ${depends} depends/${hostTriple}

    cmake -S . -B build \
      --toolchain /bitcoin/depends/${hostTriple}/toolchain.cmake \
      -DWITH_CCACHE=OFF \
      -Werror=dev \
      -DREDUCE_EXPORTS=ON \
      -DBUILD_BENCH=OFF \
      -DBUILD_GUI_TESTS=OFF \
      -DBUILD_FUZZ_BINARY=OFF \
      -DCMAKE_SKIP_RPATH=TRUE

    cmake --build build -j $NIX_BUILD_CORES

    # build.sh's cmake_install.cmake \`cp -u -r\` workaround (a no-op
    # for CMake >= 3.27, kept for parity with build.sh). --strip runs
    # CMAKE_STRIP (= llvm-strip, recorded in toolchain.cmake by
    # darwin.mk) over every installed binary — this IS upstream's
    # stripping; there is no separate split-debug step.
    find build -name 'cmake_install.cmake' -exec sed -i 's| -u -r | |g' {} +
    cmake --install build --strip --prefix $out

    # The macOS app bundle: \`deploy\` installs the bitcoin-qt component
    # into dist/Bitcoin-Qt.app, runs macdeployqtplus (Qt translations,
    # plists; OBJDUMP=llvm-objdump comes from Maintenance.cmake) and
    # zips it deterministically via macos_zip.sh (SOURCE_DATE_EPOCH
    # mtimes, find|sort|zip -X@). build.sh ships that zip as
    # bitcoin-<ver>-<host>-unsigned.zip and the dist/ tree inside the
    # -codesigning.tar.gz.
    cmake --build build -j $NIX_BUILD_CORES --target deploy

    # macdeployqtplus copies Qt's translations (Contents/Resources/qt_*.qm)
    # straight from the read-only Nix store, so they land mode 0444 and zip
    # records the DOS read-only bit (external_attr 0x81240001). Upstream's
    # GUIX deploy has them 0644 (0x81a40000). Make the whole bundle
    # owner-writable before zipping — a no-op for the already-0755/0644
    # entries, it only lifts the store-sourced 0444 files to 0644.
    chmod -R u+w build/dist/Bitcoin-Qt.app

    rm -f build/dist/bitcoin-macos-app.zip
    ( cd build/dist && ${distsrc}/cmake/script/macos_zip.sh "\$(command -v zip)" bitcoin-macos-app.zip )

    mkdir -p $dist
    cp -a build/dist/. $dist/
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

  # Reproducibility gate: assert every shipped binary byte-matches the
  # upstream GUIX release -unsigned tarball for this target. When
  # `expectedHashes` is empty (default), the gate is skipped and the
  # binaries are merely listed.
  postFixup =
    if expectedHashes == { } || !withGate then ''
      echo "BUILT (no per-binary upstream gate — archive gates downstream): ${hostTriple}"
      for rel in \
        bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-qt bin/bitcoin-tx \
        bin/bitcoin-util bin/bitcoin-wallet \
        libexec/bitcoin-gui libexec/bitcoin-node libexec/test_bitcoin; do
        f="$out/$rel"
        [ -f "$f" ] && echo "  $rel  $(sha256sum "$f" | cut -d' ' -f1)"
      done
      echo "INFO: bitcoin-macos-app.zip sha256: $(sha256sum $dist/bitcoin-macos-app.zip | cut -d' ' -f1)"
    '' else ''
      declare -A expected=(
${lib.concatStringsSep "\n" (lib.mapAttrsToList (rel: h: "      [${rel}]=${h}") expectedHashes)}
      )
      fail=0
      for rel in "''${!expected[@]}"; do
        f="$out/$rel"
        if [ ! -f "$f" ]; then echo "FAIL: $rel was not built"; fail=1; continue; fi
        actual=$(sha256sum "$f" | cut -d' ' -f1)
        if [ "$actual" = "''${expected[$rel]}" ]; then
          echo "OK:   $rel matches upstream"
        else
          echo "FAIL: $rel  expected ''${expected[$rel]}  actual $actual"
          fail=1
        fi
      done
      [ "$fail" = "0" ] || { echo "FAIL: one or more ${hostTriple} binaries diverged from upstream GUIX"; exit 1; }
      echo "OK: all ${toString (builtins.length (builtins.attrNames expectedHashes))} asserted ${hostTriple} binaries match upstream GUIX"
      echo "INFO: bitcoin-macos-app.zip sha256: $(sha256sum $dist/bitcoin-macos-app.zip | cut -d' ' -f1)"
    '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
