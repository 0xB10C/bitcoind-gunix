{ pkgs ? import <nixpkgs> {}
, pkgs2405 ? null # nixos-24.05 (for gcc 11.4.0 — the NSIS stub toolchain)
}:

let
  version = "31.1rc1";
  # v31.1rc1 has no bitcoincore.org release tarball yet (rc still being
  # tested) — fetch the GitHub source archive directly. The GitHub
  # archive uses the same `bitcoin-<version>/` prefix as the GUIX
  # build.sh `git archive --prefix=…` upstream uses for its release
  # tarball, so the tarball.nix extraction (`bitcoin-${version}/…`)
  # still resolves. The hash will need to be re-pinned to the
  # bitcoincore.org tarball if/when v31.1 ships, alongside the per-
  # binary gates (currently disabled, see the rc1 NOTE in tarball.nix /
  # release-cross.nix).
  url = "https://github.com/bitcoin/bitcoin/archive/refs/tags/v${version}.tar.gz";
  sha256 = "sha256-hJmpaCwPzodnoHb4Q1sXqdTiXj9LPTBNhtltOfldYh4=";

  # SOURCE_DATE_EPOCH for the release archive's mtime. v31.0 used the
  # v31.0 tag commit time (1776286524). For v31.1rc1 use the tag's
  # commit time (efde6234… = 2026-06-22T13:11:02Z). When v31.1 final
  # ships, switch to the v31.1 tag's commit time.
  sourceDateEpoch = 1782133862;

  # NOTE (2026-06-10): the original NATIVE x86_64 toolchain (binutils 2.41
  # + gcc 14 rebuilt against glibc 2.31 via wrapped native stdenvs:
  # binutilsForGuix → bintoolsWithGlibc231 → stdenvForGccRebuild →
  # gcc14RebuiltWithGlibc231 → gcc14Glibc231Stdenv, plus flake.nix's native
  # glibc231) was REMOVED after the cross-to-self toolchain below
  # (crossGuixGccX86) reproduced the identical 10 binaries + tarball. The
  # cross-to-self structure also obsoleted two native-only workarounds the
  # cross gcc handles via --with-as: the PATH `as`-shadow for the gas
  # NOP-fill order and depsBuildTarget. See CLAUDE.md's 2026-06-10 status
  # and git history (pre-2026-06-10 default.nix) for the native chain.

  # The build host system, taken from the incoming pkgs ("cross
  # everywhere"): every target's cross toolchain is instantiated FROM this
  # system, so the same definitions build every target on any build host —
  # on x86_64-linux, pkgsCrossX86 is a cross-to-self and pkgsCrossAarch64 a
  # real cross; on aarch64-linux it's exactly mirrored. The target triples
  # (and hence the GUIX-exact toolchain configs) never change; only the
  # host the compilers run on does. The core bet — cross toolchains emit
  # build-host-independent target bytes — is proven on x86_64 hosts (both
  # targets' gates); other hosts re-assert the same gates.
  buildSystem = pkgs.stdenv.hostPlatform.system;

  # rc1 NOTE: no detached signatures published for v31.1rc1 yet, so the
  # darwin/win64 codesigning + signed flows are not wired in this build.
  # When v31.1 final ships and detached-sigs is tagged, restore the
  # `detachedSigs` / `detachedSigsGit` / `codesignaturesArchive` /
  # `sourceDistArchive` / `sha256sums` machinery (see git history at
  # commit af4bce22b63b for the v31.0 versions of those derivations).
  # `detachedSigs = null` is passed through so the darwin/win64
  # toolchains can drop their signed/codesigning attrs.
  detachedSigs = null;

  aarch64 = import ./nix/aarch64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  riscv64 = import ./nix/riscv64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  armhf   = import ./nix/arm-linux-gnueabihf/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  ppc64   = import ./nix/powerpc64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  x86     = import ./nix/x86_64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  darwin  = import ./nix/darwin/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch detachedSigs; };
  win64   = import ./nix/win64/toolchain.nix { inherit pkgs pkgs2405 version url sha256 buildSystem sourceDateEpoch detachedSigs; };

  # rc1 NOTE: aggregated SHA256SUMS outputs (the
  # `noncodesigned.SHA256SUMS` / `all.SHA256SUMS` files) are dropped
  # for the rc — they only make sense once upstream's SHA256SUMS file
  # is published and we can diff against it. The per-target tarballs/
  # binaries still build, but without upstream-hash gates (every
  # `expectedSha256` / `expectedHashes` is null/empty until v31.1
  # ships).
in {
  inherit (x86) depends bitcoind tarball debugTarball;
  inherit (aarch64) dependsAarch64 bitcoindAarch64 tarballAarch64 debugTarballAarch64;
  inherit (riscv64) dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64;
  inherit (armhf) dependsArmhf bitcoindArmhf tarballArmhf debugTarballArmhf;
  inherit (ppc64) dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64;
  inherit (riscv64) riscv64Cross;
  inherit (armhf) armhfCross;
  inherit (ppc64) ppc64Cross;
  inherit (aarch64) crossGlibc231;
  inherit (x86) crossGlibc231X86 crossGuixGccX86;
  inherit (darwin) llvmPackages1914 clangDarwin lldDarwin llvmDarwin darwinSdk
    dependsDarwinX86 dependsDarwinArm64 bitcoindDarwinX86 bitcoindDarwinArm64
    tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
    signapple;
  inherit (win64) mingwGuixGcc mingwGuixGccNoFp mingwBinutils241 pkgsCrossMingw dependsMingw
    mingwCrtStdenv mingwCrt
    bitcoindMingw bitcoindMingwNoGate unsignedZipMingw debugZipMingw
    nsisGcc11 nsis310 setupExeMingw
    pkgsCrossMingwNsis nsisCrtBootSet nsisCrtStdenv;
}
