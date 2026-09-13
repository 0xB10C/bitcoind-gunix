{ pkgs, version, src, buildSystem, sourceDateEpoch, upstreamSha256 }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version src buildSystem sourceDateEpoch; };

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
    # Branch-off: bitcoin-gui (.text > 32 MB, so ld inserts long-branch
    # stubs) differed only in stub order. Our glibc libm.so.6/libc.so.6
    # carry a .gnu.attributes section GUIX's don't; that one extra section
    # shifted ld's global section ids, renaming two stubs
    # (long_branch.29967 vs guix 29966) and reordering the hash-ordered
    # stub table. See glibcStripSharedSections in lib/linux-cross-target.nix.
    glibcStripSharedSections = [ ".gnu.attributes" ];
    pnameSuffix = "ppc64";
    tarballSha256 = upstreamSha256 "bitcoin-${version}-powerpc64-linux-gnu.tar.gz";
    debugTarballSha256 = upstreamSha256 "bitcoin-${version}-powerpc64-linux-gnu-debug.tar.gz";
  };
  dependsPpc64 = ppc64Cross.depends;
  bitcoindPpc64 = ppc64Cross.bitcoind;
  tarballPpc64 = ppc64Cross.tarball;
  debugTarballPpc64 = ppc64Cross.debugTarball;

in {
  inherit ppc64Cross dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64;
}
