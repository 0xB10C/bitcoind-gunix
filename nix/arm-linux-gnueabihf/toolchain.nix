{ pkgs, version, url, sha256, buildSystem }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version url sha256 buildSystem; };

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
      "bin/bitcoin" = "6fe2e29aeea99bafb1ad92333ecc2eaa52d3e16734b63ff743da37e2ec87688e";
      "bin/bitcoin-cli" = "d135cb00ca315694aa5274a2f3065d82b9183b80881e634016f7504906e79b86";
      "bin/bitcoind" = "d44c812afed46ca02d0a6ee494b738f92ef255a28afaa2530544cfc3784e7ae6";
      "bin/bitcoin-tx" = "007e46104f7c74b6fbb24b6c9e9a8fd0cf0ee6fbbe6c9ccb22e66f5275bdfb7f";
      "bin/bitcoin-util" = "046c67b8d6fcaa29aa02ad1c14ad6e1b9bedef9320335d7de427127da1b19a66";
      "bin/bitcoin-wallet" = "effbb134e764fbf0dbabf999e8855367e83c2ba2dd25e8b25a28e2a679749b7d";
      "bin/bitcoin-qt" = "dab13e05f54a04b7430cfe9ddc16069a6c93b059ff70e27e5d21140d8a9e9b4b";
      "libexec/bitcoin-node" = "19fe6129533db79c622e5ca52b5a26af765e8114124a94a3548a2c4208f3c1ee";
      "libexec/bitcoin-gui" = "6b50fb850eb42df3fc774b8137baa31eeb497aa259584c0ee5eb1f395dd76753";
      "libexec/test_bitcoin" = "c6170cb1c5115034c7d2dc5697909bb921c93e07a186323eba43a50fc4b4460d";
      "bin/bitcoin.dbg" = "60d22fc62c48176d4d52e049fcd6c378aa8918e0ddbd81c4e515d68590654775";
      "bin/bitcoin-cli.dbg" = "ffad56789f3b85f959f510472accbacb92e45e5db69f41de5ed5de7e2dba7239";
      "bin/bitcoind.dbg" = "964b99bbde7dc42213d8b4296880988880d3d63b52aa67bcfcfc97ac3cd05b83";
      "bin/bitcoin-tx.dbg" = "3c2575828c75fde267800a2b2e6da8a44d79b5fd99810fed7a61b1e45ef3005b";
      "bin/bitcoin-util.dbg" = "136fffa7961ea8f5bf686dadfe30b1bc8dcb2f2ce1bf4997a3273c519cbe7ee0";
      "bin/bitcoin-wallet.dbg" = "5555299c4ab4388ddc3de83eb1a39a895940cde22cd258f3b75ceb9128c26d30";
      "bin/bitcoin-qt.dbg" = "6c2ad12a49736b26b81e383f97e6cbbc24d56e0c4ef3c93d95215a30590293c1";
      "libexec/bitcoin-gui.dbg" = "c5776fc7a96bbaebaff1fa2779c2b13f310219f942ffd4e2b2c2411be8c11d67";
      "libexec/bitcoin-node.dbg" = "57d9f19955ffb266bf17c80123ddd94a91268eba2e5303d9d4a7a81320e94430";
      "libexec/test_bitcoin.dbg" = "05a022436c126df567fe532c34def4d815215d49eac4cde818730d774cf43c1e";
    };
    tarballSha256 = "8c19d007bfc73502625095ea4073af3a98ceb722d500556ab173bac5bcadd0d6";
    debugTarballSha256 = "fc17562b66707d0c8d1863af0cd40d7c6818a8d7d7b360b8d43276b1593924d9";
  };
  dependsArmhf = armhfCross.depends;
  bitcoindArmhf = armhfCross.bitcoind;
  tarballArmhf = armhfCross.tarball;
  debugTarballArmhf = armhfCross.debugTarball;

in {
  inherit armhfCross dependsArmhf bitcoindArmhf tarballArmhf debugTarballArmhf;
}
