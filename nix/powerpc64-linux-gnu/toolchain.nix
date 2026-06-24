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
    expectedHashes = {
      "bin/bitcoin" = "f510983d2728f274a275682f8dba788d3bdc62cd7eb0f04342892fdbb6e3ef07";
      "bin/bitcoin-cli" = "63d76c4853614e813fb74be1356e95ad6045fa879013ec73216aa1ef86cdc443";
      "bin/bitcoind" = "145e03593731c7e9c88f907254e0eff4c5aeb529eb8dc43878493021f0ce9e62";
      "bin/bitcoin-tx" = "43614fbf1d7e8b0d1b4107836f64971ef99a69cb3fffae23ef265e6fbb1ba9a5";
      "bin/bitcoin-util" = "d11bf2a80648878cbfd33ad19c8ea93ed89579bedfa0fcabf2a64df9e9ee382b";
      "bin/bitcoin-wallet" = "2e03eb179b99d31d853e0b158a4729010978f902a8a6722d34a397382e85165f";
      "bin/bitcoin-qt" = "659a8f2487229c64213b16577bef59ec601bcd4b5b61d438cdd79adbb4788d44";
      "libexec/bitcoin-node" = "8feb70ca0d1840faac6eacd093cbad5302cb76b3525bcfec69e8b45dc4e6d68d";
      "libexec/bitcoin-gui" = "1249562c1bdf36f739d4d93e18d9564fb681a915e9f94397189adc716aef97a7";
      "libexec/test_bitcoin" = "fe4ff54cc9a2bef3c2e0048875e24e6489f05b990c972703c5a2a59f0348d352";
      "bin/bitcoin.dbg" = "92bd5521238accf018199ed9a15ccd21e579c6f007ccd22ae424d56608aa888a";
      "bin/bitcoin-cli.dbg" = "94664fbe4f5b984897641e2a6a491e9e4417499dee05cdb86f91c211bbcd125d";
      "bin/bitcoind.dbg" = "becc8b966529ad7d237df55dccf7447debcdb4ee29f4a6fffaeead9e69db245c";
      "bin/bitcoin-tx.dbg" = "50e1086d605eb6f11107183baf0a2b22b1cd105db85f4a4c0ef206255aee2779";
      "bin/bitcoin-util.dbg" = "35f09fe2f4d51c922e8c65eb53bdc2d8472f6a55e8dd8fda27f7584ce0d2c38c";
      "bin/bitcoin-wallet.dbg" = "9ea50c5f9a51221f40b5cd846a54211e71f35948afd0deb552116e73a4927b66";
      "bin/bitcoin-qt.dbg" = "1b9db7e743a89eb31b8d4ac49ffd174a06076cf5b3322250438298102c5c0d53";
      "libexec/bitcoin-node.dbg" = "cd4d46cf9517fab0860fdd7692da1348b6c8dfa1d669a3b4dfb9d77ae8bfe222";
      "libexec/bitcoin-gui.dbg" = "25425093d82727f9f351803ce147fb3a0b4262697364b99e5388c58b39140bc6";
      "libexec/test_bitcoin.dbg" = "8187ea5df74d5edb321511e81c9ed90c760d0a3dede3a2a69d6d815334625a06";
    };
    tarballSha256 = "dc7ba69a377bf0f1965e6938054642a0d779886d83f96e8bbf63471f478ca7c6";
    debugTarballSha256 = "50b00415baa8c877bfd814f31139bfc454b79b0a06999272e71bc4d5377bd6ef";
  };
  dependsPpc64 = ppc64Cross.depends;
  bitcoindPpc64 = ppc64Cross.bitcoind;
  tarballPpc64 = ppc64Cross.tarball;
  debugTarballPpc64 = ppc64Cross.debugTarball;

in {
  inherit ppc64Cross dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64;
}
