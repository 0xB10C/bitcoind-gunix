{ pkgs, version, src, buildSystem, sourceDateEpoch, upstreamSha256 }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version src buildSystem sourceDateEpoch; };

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
    # Branch-off: bitcoin-qt/-gui/-node/test_bitcoin differed only in ld's
    # stub order (Cortex-A8 erratum + long-branch veneers, named after
    # global BFD section ids). Our glibc libpthread.so.0 and libc.so.6 each
    # carry one section more than GUIX's; ld reads libpthread.so twice, so
    # ids drifted -1/-3 and the stub hash order changed. Relinking guix's
    # own objects against copies with ANY one section removed from both
    # reproduces guix's .text exactly (ld only counts them). .ARM.extab is
    # chosen because ppc64 shows guix's glibc keeps .interp and the debug
    # sections, so an ARM-only section is the likely one; its identity is
    # unconfirmed. See glibcStripSharedSections in lib/linux-cross-target.nix.
    # Only those two files: GUIX's ld-linux-armhf.so.3 keeps its section.
    # Stripping it too left test_bitcoin (its big stub group is anchored
    # after ld-linux's ids) one id short; relinking test_bitcoin with one
    # section added back to ld-linux reproduces guix's .text exactly.
    glibcStripSharedSections = [ ".ARM.extab" ];
    glibcStripSharedFiles = [ "libc.so.6" "libpthread.so.0" ];
    extraCXXFLAGS = "-Wno-psabi";
    pnameSuffix = "armhf";
    tarballSha256 = upstreamSha256 "bitcoin-${version}-arm-linux-gnueabihf.tar.gz";
    debugTarballSha256 = upstreamSha256 "bitcoin-${version}-arm-linux-gnueabihf-debug.tar.gz";
  };
  dependsArmhf = armhfCross.depends;
  bitcoindArmhf = armhfCross.bitcoind;
  tarballArmhf = armhfCross.tarball;
  debugTarballArmhf = armhfCross.debugTarball;

in {
  inherit armhfCross dependsArmhf bitcoindArmhf tarballArmhf debugTarballArmhf;
}
