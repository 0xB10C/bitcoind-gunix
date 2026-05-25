{ pkgs ? import <nixpkgs> {}
, glibc231 ? pkgs.glibc
}:

let
  version = "31.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "sha256-C6DvXuo679lswXdL4nTD1ZSBLPrAmIgJ1wZzi7Bns+M=";

  # ============================================================================
  # "Build our own compiler" — coherent toolchain rebuilt against glibc 2.31.
  # ============================================================================
  #
  # Multi-stage:
  #   1. binutils 2.41 with GUIX's binutils-unaligned-default patch.
  #   2. A "stage-A" stdenv: existing gcc 14 binary but with cc-wrapper
  #      pointing at glibc 2.31 and the 2.41 bintools. This lets us
  #      compile-and-link against glibc 2.31, even though stage-A's gcc
  #      binary itself was built against the host's glibc.
  #   3. Rebuild gmp/mpfr/libmpc/isl using stage-A. Each thread its
  #      glibc-2.31-built deps explicitly to the next package, so e.g.
  #      libmpc uses our glibc-2.31 gmp not nixpkgs' glibc-2.42 gmp.
  #   4. Rebuild gcc 14 itself using stage-A + the glibc-2.31 helpers.
  #      Apply GUIX's gcc-ssa-generation patch and the
  #      `linux-base-gcc` configureFlags. Filter --disable-bootstrap
  #      so gcc does the full 3-stage bootstrap. The resulting gcc's
  #      libstdc++ is then built by stage-3 gcc (matching GUIX), not
  #      stage-1.
  #   5. Wrap that gcc into a CC-wrapper pointing at glibc 2.31.
  #   6. Use that wrapper as the final stdenv for depends and bitcoind.

  binutilsWithGuixPatches = pkgs.binutils-unwrapped.overrideAttrs (old: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    patches = [
      ./patches/binutils-unaligned-default.patch
    ];
    outputs = [ "out" "info" "man" ];
  });

  bintoolsWithGlibc231 = pkgs.wrapBintoolsWith {
    bintools = binutilsWithGuixPatches;
    libc = glibc231;
  };

  # Stage-A: existing gcc binary wrapped to target glibc 2.31.
  stageAStdenv = pkgs.overrideCC pkgs.gcc14Stdenv (pkgs.wrapCCWith {
    cc = pkgs.gcc14Stdenv.cc.cc;
    libc = glibc231;
    bintools = bintoolsWithGlibc231;
  });

  # gmp/mpfr/libmpc/isl rebuilt against glibc 2.31, threading rebuilt
  # deps to subsequent packages.
  gmpGlibc231 = pkgs.gmp.override { stdenv = stageAStdenv; };
  mpfrGlibc231 = pkgs.mpfr.override {
    stdenv = stageAStdenv;
    gmp = gmpGlibc231;
  };
  libmpcGlibc231 = pkgs.libmpc.override {
    stdenv = stageAStdenv;
    gmp = gmpGlibc231;
    mpfr = mpfrGlibc231;
  };
  islGlibc231 = pkgs.isl.override {
    stdenv = stageAStdenv;
    gmp = gmpGlibc231;
  };

  # The new gcc 14: bootstrap-enabled, GUIX patches/configureFlags,
  # using glibc-2.31-built helpers.
  gcc14RebuiltCc = (pkgs.gcc14.cc.override {
    stdenv = stageAStdenv;
    gmp = gmpGlibc231;
    mpfr = mpfrGlibc231;
    libmpc = libmpcGlibc231;
    isl = islGlibc231;
  }).overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./patches/gcc-ssa-generation.patch
    ];
    # Mirror GUIX's `linux-base-gcc` configure flags, and drop
    # --disable-bootstrap so gcc does the 3-stage bootstrap.
    configureFlags =
      (builtins.filter (f: f != "--disable-bootstrap") (old.configureFlags or []))
      ++ [
        "--enable-initfini-array=yes"
        "--enable-default-ssp=yes"
        "--enable-default-pie=yes"
        "--enable-host-bind-now=yes"
        "--enable-standard-branch-protection=yes"
        "--enable-cet=yes"
        "--enable-gprofng=no"
        "--disable-gcov"
        "--disable-libgomp"
        "--disable-libquadmath"
        "--disable-libsanitizer"
      ];
  });

  ccWithGlibc231 = pkgs.wrapCCWith {
    cc = gcc14RebuiltCc;
    libc = glibc231;
    bintools = bintoolsWithGlibc231;
  };

  finalStdenv = pkgs.overrideCC pkgs.gcc14Stdenv ccWithGlibc231;

  depends = pkgs.callPackage ./depends.nix {
    inherit version url sha256;
    gcc14Stdenv = finalStdenv;
  };
  bitcoind = pkgs.callPackage ./bitcoind.nix {
    inherit version url sha256 depends;
    gcc14Stdenv = finalStdenv;
  };
in {
  depends = depends;
  bitcoind = bitcoind;
}
