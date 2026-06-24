{ pkgs, version, url, sha256, buildSystem, sourceDateEpoch }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };

  # --- armhf (arm-linux-gnueabihf) cross-compile ---
  # The arm-linux-gnueabihf release. armhf-specific notes (verified
  # against the upstream .dbg/binaries):
  # - gccArchFlags = GUIX's gcc-configure-flags-for-triplet translation of
  #   the gnueabihf "extended triple" (guix gnu/packages/gcc.scm):
  #   --with-arch=armv7-a --with-float=hard --with-mode=thumb
  #   --with-fpu=neon. nixpkgs already passes --with-float=hard (from
  #   parsed.abi.float), so only the other three are added here. The gcc
  #   driver then self-injects the RECORDED `-mfloat-abi=hard -mfpu=neon
  #   -mtls-dialect=gnu -mthumb -march=armv7-a+simd` into every CU's
  #   DW_AT_producer — exactly upstream's producer prefix (this is the
  #   aarch64 --with-arch effect, except here upstream's gcc HAS the
  #   configured defaults, so we add rather than filter).
  # - build.sh adds -Wno-psabi to HOST_CXXFLAGS for this host only
  #   (warning flag, not recorded in DW_AT_producer; mirrored for compile
  #   parity).
  # - ELF32; interpreter /lib/ld-linux-armhf.so.3.
  # gawk pinned to GUIX's 5.3.0 for the armhf gcc build: gcc's
  # config/arm/parsecpu.awk generates the arm-cpu-data tables with awk's
  # UNORDERED `for (x in array)` iteration — the entry ORDER of (e.g.)
  # `all_implied_fbits` depends on the awk version's hash internals.
  # nixpkgs' gawk 5.4.0 orders it differently than GUIX's 5.3.0, and the
  # table is baked into crtbegin/crtend (crtstuff.c includes the arm tm
  # headers) — i.e. into EVERY linked binary's .rodata. This was the
  # whole-release armhf divergence (72 bytes in bitcoin-cli, all in this
  # one table). arm-only: no other target has awk-generated unordered
  # tables, so the pin is armhf-gated.
  # (C23 disabled via the autoconf cache var: nixpkgs' gawk runs
  # autoreconfHook, and autoconf 2.72's AC_PROG_CC auto-selects the
  # NEWEST C standard the compiler supports — 5.3.0's io.c K&R-style
  # casts don't compile as C23.)
  gawk530 = pkgs.gawk.overrideAttrs (o: {
    version = "5.3.0";
    src = pkgs.fetchurl {
      url = "mirror://gnu/gawk/gawk-5.3.0.tar.xz";
      sha256 = "02x97iyl9v84as4rkdrrkfk2j4vy4r3hpp3rkp3gh3qxs79id76a";
    };
    configureFlags = (o.configureFlags or [ ]) ++ [ "ac_cv_prog_cc_c23=no" ];
    # gcc 15 also DEFAULTS to gnu23, so pin the dialect explicitly too.
    env = (o.env or { }) // { NIX_CFLAGS_COMPILE = "-std=gnu17"; };
  });

  armhfCross = mkLinuxCrossTarget {
    triple = "arm-linux-gnueabihf";
    gccArchFlags = [ "--with-arch=armv7-a" "--with-mode=thumb" "--with-fpu=neon" ];
    gccNativeInputs = [ gawk530 ];
    # Full canon wiring like ppc64 (canon patch + BOTH knobs), for the two
    # replay-verified root causes (see CLAUDE.md):
    # - canonDepends: the depends -ffile-prefix-map FIRING on every
    #   depends header ggc-allocates the rewrites and flips
    #   var-tracking's loclists representative for `it` in
    #   net_processing.cpp (an IDENTITY map alone reproduces the flip);
    #   GUIX fires no map on depends (real /bitcoin path, outside their
    #   /gnu/store→/usr maps).
    # - debugCanonMap: the /build=$DISTSRC argv map matches the
    #   cmake-build-dir GENERATED CUs' main files (mpgen capnp, qt moc)
    #   and duplicates their file-table entry — upstream, building at
    #   the real $DISTSRC, never remaps them (visible as shifted
    #   DW_AT_decl_file implicit_consts + a doubled v5 line-table file
    #   entry in bitcoin-node/-gui/test_bitcoin/qt). With the canon
    #   rewrite the remaining argv map is GUIX's literal
    #   $DISTSRC/src=., which dups the src/ CUs on both sides equally.
    gccExtraPatches = [ ../patches/gcc-debug-canon-prefix-map.patch ];
    debugCanonMap = true;
    canonDepends = true;
    dynamicLinker = "/lib/ld-linux-armhf.so.3";
    extraCXXFLAGS = "-Wno-psabi";
    pnameSuffix = "armhf";
    expectedHashes = {
      "bin/bitcoin" = "0590e94b4d290272ea0969b2ab3a23ddd5030ffaa1310de646c041664ef01e25";
      "bin/bitcoin-cli" = "0d1984b2b5e022be2744c737c2821f00f571977955d8edfeea5edb96be0495f3";
      "bin/bitcoind" = "390940387af727e5957410b736cfb7bf39fcc5954ea33cc3102f543cf8b6c250";
      "bin/bitcoin-tx" = "e6cf985c3e8639b5c85594bd8c4643e3fdcdd155111b7005d8c7d209a5503afa";
      "bin/bitcoin-util" = "c37793791201dc671ac681fd66ec3ca740449d45aac1d57fb9e17572db0ea645";
      "bin/bitcoin-wallet" = "223f1b38ac02c4d0eb8b39dd39855e26972f435539af795be43a1bbe9fd92c5f";
      "bin/bitcoin-qt" = "e1478f4b2594cfb4ea544179e5b85a70a2be0cc9812c587d2f7cd477863b5467";
      "libexec/bitcoin-node" = "8aa6da371a411d8f91c98d03ffdcc3919496384fc599b992f206b0c8b69befc7";
      "libexec/bitcoin-gui" = "5e4259ae4cb793a83740dab25a87e7a0bf3e82ba2bd73ec81895a01dba364b3e";
      "libexec/test_bitcoin" = "a1c3aa83ea7d3cec118cb1592198cd001b6515fed958b90768dc02a98cc3d887";
      "bin/bitcoin.dbg" = "83a0eaf6354537304c590c279fc0a093e9912941a0a2ea9a0cb1b47dc376be4b";
      "bin/bitcoin-cli.dbg" = "4beaa2eb0e72841f22d65fa57c168e992561cc3cd84ab5dc636c238125396df7";
      "bin/bitcoind.dbg" = "379c46071c218d8bef4cce05f38062d5bb8141ab3554ea6b38cfe73ca96d3adc";
      "bin/bitcoin-tx.dbg" = "375b054e6564e2e2f04baa7ab1de302724322b1665bc70dc046d723e31e48612";
      "bin/bitcoin-util.dbg" = "eb5ac324a3de88fb2e676eed02f6cf8da9495c6ff094aa4f611b1b2a56918e93";
      "bin/bitcoin-wallet.dbg" = "d14d9b1d99f6517d462873278e113f334d97a620dc1c92f862cafaf18e3664ce";
      "bin/bitcoin-qt.dbg" = "a7dc6dfd1c588cffc366658eb67c31af3d01ccefc2e1e85ec7a2c3d32a86e9c5";
      "libexec/bitcoin-node.dbg" = "3fde9318cd291f77d6ba4bc78c889b77a6ce8f7860747220e24dbe19354b1226";
      "libexec/bitcoin-gui.dbg" = "2f936dcaa49dbcece2cb27276ac304d0f060250520dabd053c51b5affbd1f28a";
      "libexec/test_bitcoin.dbg" = "73277b5e5695402a32f0747072bee4a6350a0c9df3b5b2768cf0a7a929478796";
    };
    tarballSha256 = "f7341de046f9f799b67a343b9ee8e9be5c13770b9dd2375148af1d3f4db820e1";
    debugTarballSha256 = "0e7c6104046f009ee25d365bcd4b1899192400ae1245d0b04ebf3ce2e4026a58";
  };
  dependsArmhf = armhfCross.depends;
  bitcoindArmhf = armhfCross.bitcoind;
  tarballArmhf = armhfCross.tarball;
  debugTarballArmhf = armhfCross.debugTarball;

in {
  inherit armhfCross dependsArmhf bitcoindArmhf tarballArmhf debugTarballArmhf;
}
