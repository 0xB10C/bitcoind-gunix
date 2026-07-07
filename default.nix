{ pkgs ? import <nixpkgs> {}
, pkgs2405 ? null # nixos-24.05 (for gcc 11.4.0 — the NSIS stub toolchain)
}:

let
  version = "31.1";
  # v31.1 is not published on bitcoincore.org/bin yet (guix.sigs has the
  # noncodesigned attestations; the signed release follows) — fetch the
  # GitHub source archive directly. The GitHub archive uses the same
  # `bitcoin-<version>/` prefix as the GUIX build.sh `git archive
  # --prefix=…` upstream uses for its release tarball, so the
  # tarball.nix extraction (`bitcoin-${version}/…`) still resolves.
  # Once the release is published, this can be re-pointed at the
  # canonical bitcoincore.org tarball.
  url = "https://github.com/bitcoin/bitcoin/archive/refs/tags/v${version}.tar.gz";
  sha256 = "sha256-iK+7yGX3Un68qCwZcFbswYd7Z4LQ+x/gMrEvhr3X454=";

  # SOURCE_DATE_EPOCH for the release archive's mtime: the v31.1 tag's
  # commit time (9be056a8… = 2026-07-06T13:09:19Z), like GUIX's
  # build.sh derives it from the tag being built.
  sourceDateEpoch = 1783343359;

  # Upstream reference hashes, parsed from the checked-in
  # noncodesigned.SHA256SUMS + all.SHA256SUMS (both from
  # bitcoin-core/guix.sigs) — every gate looks its artifact up here by
  # published filename instead of hardcoding the hash. A filename
  # missing from both files resolves to null and its gate is skipped
  # (that's how the tree builds between "guix.sigs has attestations"
  # and "the full signed release is out": check in whichever file
  # exists). The files must be git-tracked or flake eval won't see them.
  parseSha256sums = file:
    if builtins.pathExists file then
      builtins.listToAttrs (builtins.concatMap
        (line:
          let m = builtins.match "([0-9a-f]{64})[ \t]+([^ \t]+)[ \t]*" line;
          in if m == null then [ ]
             else [ { name = builtins.elemAt m 1; value = builtins.elemAt m 0; } ])
        (pkgs.lib.splitString "\n" (builtins.readFile file)))
    else { };
  upstreamHashes = parseSha256sums ./noncodesigned.SHA256SUMS
    // parseSha256sums ./all.SHA256SUMS;
  upstreamSha256 = filename: upstreamHashes.${filename} or null;

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

  # Detached signatures (bitcoin-core/bitcoin-detached-sigs v31.1) — used by
  # both the darwin and win64 signed-artifact flows, so it lives here rather
  # than inside either target's toolchain.
  detachedSigs = pkgs.fetchFromGitHub {
    owner = "bitcoin-core";
    repo = "bitcoin-detached-sigs";
    rev = "e26f014fc2baefda985f8cb76be9b96efa3e81d7"; # v31.1
    hash = "sha256-7LRhWNmUIOJVu/l8EIWbZkluifqnkNWhff6akJBM2/8=";
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
      expectedSha256 = upstreamSha256 "bitcoin-${version}.tar.gz";
    };

  # bitcoin-${version}-codesignatures-${version}.tar.gz: codesign.sh's
  # `git archive HEAD` of the bitcoin-detached-sigs repo at the v${version}
  # tag — GENERATED from the same repo `detachedSigs` is fetched from
  # (with .git metadata this time, so `git archive` has a tree+commit
  # to work from). See nix/lib/codesignatures.nix for how the
  # git-archive + gzip is reproduced byte-for-byte.
  detachedSigsGit = pkgs.fetchgit {
    url = "https://github.com/bitcoin-core/bitcoin-detached-sigs";
    rev = "e26f014fc2baefda985f8cb76be9b96efa3e81d7"; # v31.1
    leaveDotGit = true;
    hash = "sha256-qibTxXPE8cyFgIJWxNUr84YWNu0xYgLVjc8W3EWFReM=";
  };
  codesignaturesArchive = import ./nix/lib/codesignatures.nix
    { inherit (pkgs) runCommand gcc git zlib; }
    {
      name = "bitcoin-${version}-codesignatures-${version}.tar.gz";
      src = detachedSigsGit;
      # In all.SHA256SUMS (the codesignatures archive isn't part of the
      # noncodesigned set).
      expectedSha256 = upstreamSha256 "bitcoin-${version}-codesignatures-${version}.tar.gz";
    };

  aarch64 = import ./nix/aarch64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch upstreamSha256; };
  riscv64 = import ./nix/riscv64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch upstreamSha256; };
  armhf   = import ./nix/arm-linux-gnueabihf/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch upstreamSha256; };
  ppc64   = import ./nix/powerpc64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch upstreamSha256; };
  x86     = import ./nix/x86_64-linux-gnu/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch upstreamSha256; };
  darwin  = import ./nix/darwin/toolchain.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch detachedSigs upstreamSha256; };
  win64   = import ./nix/win64/toolchain.nix { inherit pkgs pkgs2405 version url sha256 buildSystem sourceDateEpoch detachedSigs upstreamSha256; };

  # The artifacts this project byte-reproduces, in upstream's
  # noncodesigned.SHA256SUMS / all.SHA256SUMS format (see
  # nix/lib/sha256sums.nix). Order matches upstream EXACTLY (verified
  # against bitcoin-core/guix.sigs 31.1rc1/achow101/all.SHA256SUMS; the
  # checked-in 31.1 noncodesigned.SHA256SUMS follows the same order).
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
