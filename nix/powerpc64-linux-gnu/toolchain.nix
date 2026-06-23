{ pkgs, version, url, sha256, buildSystem, sourceDateEpoch }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };

  # --- powerpc64 (big-endian) cross-compile ---
  # The powerpc64-linux-gnu release. ppc64-specific notes (verified
  # against the upstream .dbg/binaries):
  # - nixpkgs cannot elaborate the triple as-is: lib/systems/parse.nix
  #   rejects the explicit "gnu" ABI on big-endian ppc64 as ambiguous
  #   (ELFv1 vs ELFv2). GUIX's triple IS powerpc64-linux-gnu, and gcc's
  #   own default for it is ELFv1 (upstream e_flags 0x1 "abiv1"), so the
  #   ppc64 package set is instantiated from a one-line-PATCHED nixpkgs
  #   copy (patches/nixpkgs-ppc64-gnu-abi.patch drops the assertion).
  #   With the plain "gnu" ABI, nixpkgs' gcc platform-flags pass NO
  #   --with-abi/--with-cpu/--with-long-double-* — exactly GUIX's bare
  #   gcc configure (guix's gcc-configure-flags-for-triplet matches
  #   powerpc64le-/powerpc- but NOT powerpc64-, and cross-base adds
  #   nothing), so gccArchFlags is empty and upstream's bitcoin CUs
  #   record no -m flags at all. The -mlong-double-128/-mno-minimal-toc
  #   in upstream's glibc/libgcc CUs come from those projects' OWN build
  #   systems (same sources here).
  # - ELF64 big-endian, ELFv1; interpreter /lib64/ld64.so.1.
  nixpkgsPpc64 = pkgs.applyPatches {
    name = "nixpkgs-ppc64-gnu-abi";
    src = pkgs.path;
    patches = [ ../patches/nixpkgs-ppc64-gnu-abi.patch ];
  };
  ppc64Cross = mkLinuxCrossTarget {
    triple = "powerpc64-linux-gnu";
    nixpkgsPath = nixpkgsPpc64;
    # ppc64's line tables come out of gas (.loc, DWARF v3), where gcc's
    # file-table behavior is path-spelling-sensitive: a main file whose
    # path matches a -fdebug-prefix-map gets a DUPLICATE file entry, and
    # whether that duplicate appears must match upstream's per-CU
    # situation EXACTLY (their $DISTSRC/src=. map duplicates bitcoin's
    # src/ CUs on both sides; our extra whole-tree /build=$DISTSRC map
    # also duplicated the cmake-build-dir mpgen-generated CUs, which
    # upstream — building at the REAL /distsrc-base path — does not
    # remap). The patch adds a TRANSPARENT canonical rewrite (env var
    # NIX_DEBUG_CANON_PREFIX_MAP, applied before the maps and to the
    # file table keys), so the build behaves as if it ran at GUIX's real
    # path and the remaining -fdebug-prefix-map set is spelled exactly
    # like build.sh's. See the patch header; strict no-op when unset.
    gccExtraPatches = [ ../patches/gcc-debug-canon-prefix-map.patch ];
    # With the canon rewrite active, the source-tree map must be GUIX's
    # literal one (on the POST-canon path), not /build-based.
    debugCanonMap = true;
    # The depends rewrite also moves off argv onto the canon env var
    # (second pair): same ggc-allocation root cause as armhf — ppc64's
    # two diverging .dbg are qt CUs, full of depends/Qt headers that our
    # argv map fired on while GUIX's environment fires none.
    canonDepends = true;
    dynamicLinker = "/lib64/ld64.so.1";
    pnameSuffix = "ppc64";
    # rc1: expectedHashes / tarballSha256 / debugTarballSha256 omitted
    # (default null) — no upstream SHA256SUMS yet. v31.0 values live
    # in git history at commit af4bce22b63b for when v31.1 ships.
  };
  dependsPpc64 = ppc64Cross.depends;
  bitcoindPpc64 = ppc64Cross.bitcoind;
  tarballPpc64 = ppc64Cross.tarball;
  debugTarballPpc64 = ppc64Cross.debugTarball;

in {
  inherit ppc64Cross dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64;
}
