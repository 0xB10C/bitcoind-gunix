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

  # Detached signatures (bitcoin-core/bitcoin-detached-sigs v31.1rc1) — used by
  # both the darwin and win64 signed-artifact flows, so it lives here rather
  # than inside either target's toolchain.
  detachedSigs = pkgs.fetchFromGitHub {
    owner = "bitcoin-core";
    repo = "bitcoin-detached-sigs";
    rev = "8c852f3283134e52d0a4e78d04648f70c9d79b60"; # v31.1rc1
    hash = "sha256-eJb6KgPP/oB1l0wEXHdoNu/XcE5P3Z9WZ+7sc/9F3cQ=";
  };

  # The two `git archive` tarballs that round out upstream's SHA256SUMS
  # alongside the build artifacts.
  #
  # bitcoin-${version}.tar.gz: build.sh's `git archive --prefix=
  # bitcoin-${version}/ HEAD` of the bitcoin/bitcoin repo at the
  # v${version} tag. We reproduce GUIX's dist-archive output BYTE-FOR-
  # BYTE by gunzip+regzip-ing GitHub's own tag archive (which is
  # itself a `git archive` of the same commit with the same prefix —
  # its inner tar is byte-identical to GUIX's; only the gzip parameters
  # differ). See nix/lib/source-dist-archive.nix.
  sourceDistArchive = pkgs.callPackage ./nix/lib/source-dist-archive.nix { }
    {
      inherit version;
      src = pkgs.fetchurl { inherit url sha256; };
      expectedSha256 = "50c152942bf842346360a3905d4221ce841c3493ac98f323d921714e385e4b4e";
    };

  # bitcoin-${version}-codesignatures-${version}.tar.gz: codesign.sh's
  # `git archive HEAD` of the bitcoin-detached-sigs repo at the v${version}
  # tag — GENERATED from the same repo `detachedSigs` is fetched from
  # (with .git metadata this time, so `git archive` has a tree+commit
  # to work from). See nix/lib/codesignatures.nix for how the
  # git-archive + gzip is reproduced byte-for-byte.
  detachedSigsGit = pkgs.fetchgit {
    url = "https://github.com/bitcoin-core/bitcoin-detached-sigs";
    rev = "8c852f3283134e52d0a4e78d04648f70c9d79b60"; # v31.1rc1
    leaveDotGit = true;
    hash = "sha256-OFCYB/96B1AbSY1VliJwx88fHKPKvAB5Cj6ka8+3pJg=";
  };
  codesignaturesArchive = import ./nix/lib/codesignatures.nix
    { inherit (pkgs) runCommand gcc git zlib; }
    { name = "bitcoin-${version}-codesignatures-${version}.tar.gz"; src = detachedSigsGit; };

  aarch64 = import ./nix/aarch64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  riscv64 = import ./nix/riscv64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  armhf   = import ./nix/arm-linux-gnueabihf/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  ppc64   = import ./nix/powerpc64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  x86     = import ./nix/x86_64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };
  darwin  = import ./nix/darwin/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch detachedSigs; };
  win64   = import ./nix/win64/toolchain.nix { inherit pkgs pkgs2405 version url sha256 buildSystem sourceDateEpoch detachedSigs; };

  # The artifacts this project byte-reproduces, in upstream's
  # noncodesigned.SHA256SUMS / all.SHA256SUMS format (see
  # nix/lib/sha256sums.nix). Order matches upstream EXACTLY (verified
  # against bitcoin-core/guix.sigs 31.1rc1/achow101/all.SHA256SUMS).
  # guix-attest sorts each per-host SHA256SUMS.part fragment by its
  # pre-basename PATH (<outdir_base>/<HOST>/<file>) — the effective
  # order is HOSTS alphabetically (aarch64-linux-gnu,
  # arm-linux-gnueabihf, arm64-apple-darwin, powerpc64-linux-gnu,
  # riscv64-linux-gnu, x86_64-apple-darwin, x86_64-linux-gnu,
  # x86_64-w64-mingw32), with darwin/win64 signed artifacts (from
  # codesigned_outdir_base sorting before outdir_base) ahead of the
  # noncodesigned ones in each group.
  noncodesignedArtifacts = [
    # aarch64-linux-gnu
    aarch64.debugTarballAarch64
    aarch64.tarballAarch64
    # arm-linux-gnueabihf
    armhf.debugTarballArmhf
    armhf.tarballArmhf
    # arm64-apple-darwin
    darwin.codesigningDarwinArm64
    darwin.tarballDarwinArm64
    darwin.zipDarwinArm64
    # dist-archive
    sourceDistArchive
    # powerpc64-linux-gnu
    ppc64.debugTarballPpc64
    ppc64.tarballPpc64
    # riscv64-linux-gnu
    riscv64.debugTarballRiscv64
    riscv64.tarballRiscv64
    # x86_64-apple-darwin
    darwin.codesigningDarwinX86
    darwin.tarballDarwinX86
    darwin.zipDarwinX86
    # x86_64-linux-gnu
    x86.debugTarball
    x86.tarball
    # x86_64-w64-mingw32 (win64)
    win64.codesigningMingw
    win64.debugZipMingw
    win64.setupExeMingw
    win64.unsignedZipMingw
  ];

  # all.SHA256SUMS = noncodesignedArtifacts with the 6 *signed* darwin/win64
  # outputs interleaved into the arm64-apple-darwin, x86_64-apple-darwin
  # and win64 groups, ahead of that group's noncodesigned entries — see
  # the ordering note above.
  allArtifactsOrdered = [
    # aarch64-linux-gnu
    aarch64.debugTarballAarch64
    aarch64.tarballAarch64
    # arm-linux-gnueabihf
    armhf.debugTarballArmhf
    armhf.tarballArmhf
    # arm64-apple-darwin (signed first)
    "${darwin.signedDarwinArm64}/bitcoin-${version}-arm64-apple-darwin.tar.gz"
    "${darwin.signedDarwinArm64}/bitcoin-${version}-arm64-apple-darwin.zip"
    darwin.codesigningDarwinArm64
    darwin.tarballDarwinArm64
    darwin.zipDarwinArm64
    # dist-archive
    codesignaturesArchive
    sourceDistArchive
    # powerpc64-linux-gnu
    ppc64.debugTarballPpc64
    ppc64.tarballPpc64
    # riscv64-linux-gnu
    riscv64.debugTarballRiscv64
    riscv64.tarballRiscv64
    # x86_64-apple-darwin (signed first)
    "${darwin.signedDarwinX86}/bitcoin-${version}-x86_64-apple-darwin.tar.gz"
    "${darwin.signedDarwinX86}/bitcoin-${version}-x86_64-apple-darwin.zip"
    darwin.codesigningDarwinX86
    darwin.tarballDarwinX86
    darwin.zipDarwinX86
    # x86_64-linux-gnu
    x86.debugTarball
    x86.tarball
    # x86_64-w64-mingw32 (win64) (signed first)
    "${win64.signedMingw}/bitcoin-${version}-win64-setup.exe"
    "${win64.signedMingw}/bitcoin-${version}-win64.zip"
    win64.codesigningMingw
    win64.debugZipMingw
    win64.setupExeMingw
    win64.unsignedZipMingw
  ];

  noncodesignedSha256sums = import ./nix/lib/sha256sums.nix
    { inherit (pkgs) runCommandLocal coreutils gnused; }
    { name = "noncodesigned.SHA256SUMS"; files = noncodesignedArtifacts; };
  sha256sums = import ./nix/lib/sha256sums.nix
    { inherit (pkgs) runCommandLocal coreutils gnused; }
    { name = "all.SHA256SUMS"; files = allArtifactsOrdered; };
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
    signapple codesigningDarwinX86 codesigningDarwinArm64 signedDarwinX86 signedDarwinArm64;
  inherit detachedSigs sourceDistArchive codesignaturesArchive;
  inherit (win64) mingwGuixGcc mingwGuixGccNoFp mingwBinutils241 pkgsCrossMingw dependsMingw
    mingwCrtStdenv mingwCrt
    bitcoindMingw bitcoindMingwNoGate unsignedZipMingw debugZipMingw
    nsisGcc11 nsis310 setupExeMingw codesigningMingw
    osslsigncode25 signedMingw
    pkgsCrossMingwNsis nsisCrtBootSet nsisCrtStdenv;
  inherit sha256sums noncodesignedSha256sums;
}
