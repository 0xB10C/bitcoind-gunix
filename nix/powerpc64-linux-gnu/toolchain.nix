{ pkgs, version, url, sha256, buildSystem }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version url sha256 buildSystem; };

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
      "bin/bitcoin" = "ee88e8a924d08362b31e73b4c2610c2278d8fb742af22d16b999f4add7110cac";
      "bin/bitcoin-cli" = "95864dd67ee83a937bad40e5d15e63a4b365aaad8d34cc7f5b10f8ba8106367b";
      "bin/bitcoind" = "3eda7c9f2a31c6a78686b168b4931351ccac9d37c693c46433d78942f1f839a9";
      "bin/bitcoin-tx" = "dfd214e1b619ba54c42128e4faf8a7f85fe75b6cc9d3cbd74ca642854acc80ba";
      "bin/bitcoin-util" = "710149e3abdc485b1d82cc7a4471714670e71e049edc1393e1ee21f9c8e0ca58";
      "bin/bitcoin-wallet" = "49d27d4d5e8f1a2a6a1bac26ba8b347e1a84742225d16d754fbda751f975bafd";
      "bin/bitcoin-qt" = "9cf677bfc8820618a16f72a1e8979644579e6d350f6b6eb9eedef129f1f6d0e4";
      "libexec/bitcoin-node" = "38dddbf084aaff10f087d9fb9a278a86e46dca7e26420d4235a5195ff89a010f";
      "libexec/bitcoin-gui" = "2137efafde666e9b85fd3d74b33e23c3926e5df92be97b3ed8d6ff1c6eedcd0e";
      "libexec/test_bitcoin" = "9788b37550bef213d6f12f7d39374b2c8c7085c6738e24ef43560e573385aebf";
      "bin/bitcoin.dbg" = "3636f2841bb165e195a00efbef8d7522965cd46a648d7a783b355202a68761dd";
      "bin/bitcoin-cli.dbg" = "7bbed644bdc4594c26c2fe0341a2d142942dad75abbe18292492071c807d830a";
      "bin/bitcoind.dbg" = "07136e7dc836568645af082105dbfbcf127cbd4efb758d4e17becfe1a113c5f6";
      "bin/bitcoin-tx.dbg" = "e7ad77f0f4956c377f8bbe9d94b408d2bdf076ea3541a678771ff4c5fa58bca1";
      "bin/bitcoin-util.dbg" = "8cd90dadc6c4b01db5a379735aaab3959e2ba45e471d236c0961739d0ff87b2b";
      "bin/bitcoin-wallet.dbg" = "f13293d7934146e15f4852e86b7d9a0396cf3ade6aec51b8a83671243315c66f";
      "libexec/bitcoin-node.dbg" = "6838aa0fb02260ac0ddb6a42de5fc3298195c59a320ac311e143fc79cdf8c87d";
      "libexec/test_bitcoin.dbg" = "b1e24a9ad93ebfbe8cf0a6d2f4715d6582e4a2fcb260bdd2bc729328fe217a9a";
      "bin/bitcoin-qt.dbg" = "7fa98ff12552e60b963d50fbc5099e800c4677042a6cece89573eaed9d66a171";
      "libexec/bitcoin-gui.dbg" = "63378a4b5522ceed2c18bca7a77b333ee55d14d56d7d117c43216fbdaba989ec";
    };
    tarballSha256 = "1d9c865aa0ccf675fc068e79d9fa57a5a70b59132fca38bb322a7d44ce2f0ff2";
    debugTarballSha256 = "efe3e7d0383d54e5d79ac47911be0100b99872fa5205510a2a22d1194a0212d8";
  };
  dependsPpc64 = ppc64Cross.depends;
  bitcoindPpc64 = ppc64Cross.bitcoind;
  tarballPpc64 = ppc64Cross.tarball;
  debugTarballPpc64 = ppc64Cross.debugTarball;

in {
  inherit ppc64Cross dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64;
}
