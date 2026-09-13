{ pkgs, version, src, buildSystem, sourceDateEpoch, upstreamSha256 }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version src buildSystem sourceDateEpoch; };

  # --- riscv64 cross-compile ---
  # The riscv64-linux-gnu release. riscv64-specific notes, all verified
  # against the upstream riscv64 .dbg/binaries before building (round-1
  # byte-match):
  # - NO --with-arch/-march handling anywhere: nixpkgs passes no
  #   --with-arch for riscv (riscv-multiplatform defines no gcc.arch), and
  #   gcc's own config.gcc default (rv64gc/lp64d) is what GUIX's gcc gets
  #   too — the driver-injected `-mabi=lp64d -misa-spec=20191213
  #   -mtls-dialect=trad -march=rv64imafdc_zicsr_zifencei` recorded in
  #   every upstream CU's DW_AT_producer comes from those shared defaults.
  # - glibc needs GUIX's glibc-riscv-jumptarget.patch (riscv sysdeps asm:
  #   HIDDEN_JUMPTARGET fixes; part of GUIX's glibc-2.31 source).
  # - frame pointers: riscv gcc at -O2 omits the frame pointer (like
  #   x86_64, no leaf/non-leaf split — -momit-leaf-frame-pointer does not
  #   exist on riscv).
  riscv64Cross = mkLinuxCrossTarget {
    triple = "riscv64-linux-gnu";
    glibcPatches = [ ../patches/glibc-riscv-jumptarget.patch ];
    pnameSuffix = "riscv64";
    # build_linux.sh skips -Wl,--fatal-warnings for riscv64 only
    # (boostorg/test#345).
    fatalLinkWarnings = false;
    # Full canon wiring like armhf/ppc64. v31.0 reproduced without it
    # (big CUs sat below the GGC-allocation flip threshold), but
    # v31.1rc1 trips it: bitcoind.dbg `.debug_loclists` is +129 bytes
    # vs upstream while every other section (incl. the stripped
    # binary) is byte-identical — the classic var-tracking
    # representative flip caused by the depends `-ffile-prefix-map`
    # ggc-allocating its rewrites (see CLAUDE.md armhf finding;
    # GUIX fires no map on depends — real /bitcoin path). Route
    # depends→/bitcoin via the canon env var so its rewrites are
    # malloc'd (GGC-neutral), and use GUIX's literal /build→DISTSRC
    # argv map so generated CUs (mpgen capnp, qt moc) don't dup
    # their main-file table entry.
    gccExtraPatches = [ ../patches/gcc-debug-canon-prefix-map.patch ];
    debugCanonMap = true;
    canonDepends = true;
    tarballSha256 = upstreamSha256 "bitcoin-${version}-riscv64-linux-gnu.tar.gz";
    debugTarballSha256 = upstreamSha256 "bitcoin-${version}-riscv64-linux-gnu-debug.tar.gz";
  };
  dependsRiscv64 = riscv64Cross.depends;
  bitcoindRiscv64 = riscv64Cross.bitcoind;
  tarballRiscv64 = riscv64Cross.tarball;
  debugTarballRiscv64 = riscv64Cross.debugTarball;

in {
  inherit riscv64Cross dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64;
}
