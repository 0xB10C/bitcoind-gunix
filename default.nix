{ pkgs ? import <nixpkgs> {}
# glibc 2.31 pulled from a separate nixpkgs pin (nixos-20.09 via flake.nix).
# Defaults to the active pkgs' glibc so `nix-build` (non-flake) still works,
# even though that flow will then use the current glibc, not 2.31.
, glibc231 ? pkgs.glibc
}:

let
  version = "31.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "sha256-C6DvXuo679lswXdL4nTD1ZSBLPrAmIgJ1wZzi7Bns+M=";

  # Downgrade binutils from nixpkgs' 2.44 to 2.41 (the version GUIX ships
  # in its package manifest, used by cross-binutils for the bitcoin cross
  # toolchain — see gnu/packages/base.scm:656 in GUIX). binutils version
  # changes affect linker layout decisions, section alignment, and (in
  # 2.44) the strictness of GNU property note merging.
  #
  # `outputs = ["out" "info" "man"]` avoids the multi-output reference
  # cycle that nixpkgs 25.11's binutils-unwrapped triggers when its
  # output-splitting machinery runs against the older 2.41 build.
  binutilsForGuix = pkgs.binutils-unwrapped.overrideAttrs (_: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    # Newer nixpkgs binutils patches may not apply to 2.41. Drop them.
    patches = [];
    outputs = [ "out" "info" "man" ];
  });

  # Build a gcc 14 / glibc 2.31 stdenv so the entire build (depends and the
  # final bitcoind link) uses glibc 2.31 — matching GUIX. The chain:
  #
  #   1. Wrap the existing gcc 14 with bintools/cc-wrapper scripts that
  #      point at glibc 2.31's lib dir, CRT files, and dynamic linker.
  #      That gives us `stdenvForGccRebuild` — a stdenv that compiles and
  #      links against glibc 2.31, but still ships the old libstdc++ built
  #      against the current glibc.
  #
  #   2. Rebuild gcc 14 itself inside `stdenvForGccRebuild`, applying
  #      GUIX's gcc-ssa-generation patch. The new gcc's libstdc++ is
  #      then compiled against glibc 2.31 and won't reference newer-
  #      glibc-only symbols (__libc_single_threaded from 2.32, the
  #      __isoc23_* family from 2.39).
  #
  #   3. Wrap the rebuilt gcc and use it as the final stdenv's CC.
  bintoolsWithGlibc231 = pkgs.wrapBintoolsWith {
    bintools = binutilsForGuix;
    libc = glibc231;
  };
  stdenvForGccRebuild = pkgs.overrideCC pkgs.gcc14Stdenv (pkgs.wrapCCWith {
    cc = pkgs.gcc14Stdenv.cc.cc;
    libc = glibc231;
    bintools = bintoolsWithGlibc231;
  });
  gcc14RebuiltWithGlibc231 = (pkgs.gcc14.cc.override {
    stdenv = stdenvForGccRebuild;
  }).overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./patches/gcc-ssa-generation.patch
    ];
    # Match GUIX's `linux-base-gcc` configure flags exactly, from
    # contrib/guix/manifest.scm:
    #
    #   (list "--enable-initfini-array=yes"
    #         "--enable-default-ssp=yes"
    #         "--enable-default-pie=yes"
    #         "--enable-host-bind-now=yes"
    #         "--enable-standard-branch-protection=yes"
    #         "--enable-cet=yes"
    #         "--enable-gprofng=no"
    #         "--disable-gcov"
    #         "--disable-libgomp"
    #         "--disable-libquadmath"
    #         "--disable-libsanitizer")
    #
    # nixpkgs already passes --enable-default-pie and (sometimes)
    # --enable-initfini-array; we add the rest verbatim.
    configureFlags = (old.configureFlags or []) ++ [
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
      # Disable NLS so libstdc++ doesn't compile gettext() calls into
      # the throw-helper functions (functexcept.o, cxx11-ios_failure.o).
      # With NLS=yes, libstdc++'s `_()` macro expands to `gettext()`;
      # with NLS=no, it's an identity macro. Upstream's GUIX-built
      # libstdc++ has NLS disabled (only dgettext, no gettext, in the
      # binary's dynsym), so matching this drops our gettext@GLIBC_2.2.5
      # entry — saves dynsym slot, .rela.plt entry, .plt entry, etc.
      "--disable-nls"
    ];
  });
  ccWithGlibc231 = pkgs.wrapCCWith {
    cc = gcc14RebuiltWithGlibc231;
    libc = glibc231;
    bintools = bintoolsWithGlibc231;
  };
  gcc14Glibc231Stdenv = pkgs.overrideCC pkgs.gcc14Stdenv ccWithGlibc231;

  depends = pkgs.callPackage ./depends.nix {
    inherit version url sha256;
    gcc14Stdenv = gcc14Glibc231Stdenv;
  };
  bitcoind = pkgs.callPackage ./bitcoind.nix {
    inherit version url sha256 depends;
    gcc14Stdenv = gcc14Glibc231Stdenv;
  };
in {
  inherit depends bitcoind;
}
