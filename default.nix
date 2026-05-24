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

  # Patches GUIX applies to its toolchain. We apply the same so our
  # gcc/binutils generate identical code/encodings.
  #
  # - gcc-ssa-generation.patch: deterministic SSA version numbering
  #   (gcc PR123351). Without it, SSA names are assigned non-
  #   deterministically depending on function-argument evaluation
  #   order, which yields different generated code per gcc build.
  #
  # - binutils-unaligned-default.patch: defaults the gas assembler's
  #   `use_unaligned_vector_move` to 1, encoding aligned vector moves
  #   as unaligned. Without this we get different VEX/EVEX encodings
  #   in .text vs upstream.
  #
  # We don't apply gcc-remap-guix-store.patch — it strips /gnu/store
  # paths from libgcc DWARF, which only matters for unstripped
  # binaries. Our reproducibility target is the stripped binary.
  binutilsWithGuixPatches = pkgs.binutils-unwrapped.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./patches/binutils-unaligned-default.patch
    ];
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
    bintools = binutilsWithGuixPatches;
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
    inherit url sha256 depends;
    gcc14Stdenv = gcc14Glibc231Stdenv;
  };
in {
  depends = depends;
  bitcoind = bitcoind;
}
