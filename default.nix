{ pkgs ? import <nixpkgs> {}
}:

let
  # The v32.0rc1 tag (d0231bb01d83, bitcoin/bitcoin#36246 "[32.x] Bump to
  # 32.0rc1"). GUIX's prelude.bash `git_head_version` takes the tag name
  # without its leading `v` as the VERSION, and DISTNAME = bitcoin-<version>
  # is what every published artifact name is built from.
  version = "32.0rc1";

  # SOURCE_DATE_EPOCH: the tagged commit's own commit time
  # (2026-09-14T13:51:13+01:00), exactly like guix-build derives it
  # (`git log --format=%at -1`).
  sourceDateEpoch = 1789390273;

  # The source tree. GitHub's archive of a TAG is `git archive
  # --prefix=bitcoin-<version>/` of the tagged commit — the same command
  # guix's build.sh runs for its dist archive — so it is used as is: every
  # consumer extracts bitcoin-${version}/ from it, and sourceDistArchive
  # below re-gzips it into the published dist archive.
  src = pkgs.fetchurl {
    name = "bitcoin-${version}.tar.gz";
    url = "https://github.com/bitcoin/bitcoin/archive/refs/tags/v${version}.tar.gz";
    hash = "sha256-u0kRh1HFWAH7QONkaoDoLOQaHIaPP0iMeALxvmP5lto=";
  };

  # Upstream reference hashes, parsed from the checked-in
  # noncodesigned.SHA256SUMS / all.SHA256SUMS (both from
  # bitcoin-core/guix.sigs) — every gate looks its artifact up here by
  # PUBLISHED FILENAME instead of hardcoding the hash. A filename missing
  # from both files resolves to null and its gate is skipped with a
  # "no upstream gate" log line.
  #
  # noncodesigned.SHA256SUMS is the first guix.sigs attestation for
  # 32.0rc1 (bitcoin-core/guix.sigs#2544, Sjors). all.SHA256SUMS is absent
  # until detached signatures exist. The files have to stay git-tracked, or
  # flake eval won't see them.
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

  # Detached signatures (bitcoin-core/bitcoin-detached-sigs @ v32.0rc1) —
  # used by both the darwin and win64 signed-artifact flows, so they live
  # here rather than inside either target's toolchain. The v32.0rc1 tag
  # peels to ef47807a, the same commit the 32.x branch points at, and
  # carries both the osx/ and win/ signatures for this rc.
  #
  # NOTE (2026-09-16): guix.sigs has no all.SHA256SUMS for 32.0rc1 yet (all
  # 14 signers posted only noncodesigned.SHA256SUMS), and bitcoincore.org
  # has no rc directory, so the 6 SIGNED artifacts + the codesignatures
  # archive have no upstream reference hash: upstreamSha256 returns null for
  # them and their gates only log "BUILT (no upstream gate)". Drop an
  # all.SHA256SUMS into the repo root once it exists and every one of them
  # is gated with no further change.
  detachedSigsRev = "ef47807a9112c7d8d2533f8545dc022a5cef50c8"; # v32.0rc1
  detachedSigs = pkgs.fetchFromGitHub {
    owner = "bitcoin-core";
    repo = "bitcoin-detached-sigs";
    rev = detachedSigsRev;
    hash = "sha256-6ac/N05/wim20P6Qa3K/rVvjgur1M07tk5NQnohqcb4=";
  };

  # bitcoin-${version}-codesignatures-${version}.tar.gz: codesign.sh's
  # `git archive HEAD` of the bitcoin-detached-sigs repo at the v${version}
  # tag — GENERATED from the same repo detachedSigs is fetched from, with
  # .git metadata this time so `git archive` has a tree to work from. See
  # nix/lib/codesignatures.nix for the byte-exact git-archive + gzip.
  detachedSigsGit = pkgs.fetchgit {
    url = "https://github.com/bitcoin-core/bitcoin-detached-sigs";
    rev = detachedSigsRev;
    leaveDotGit = true;
    hash = "sha256-ugT+uq6BhkjoYelvTw7/ULeFbt1IVbRZ2CGVf9zYDik=";
  };
  codesignaturesArchive = import ./nix/lib/codesignatures.nix
    { inherit (pkgs) runCommand gcc git zlib; }
    {
      name = "bitcoin-${version}-codesignatures-${version}.tar.gz";
      src = detachedSigsGit;
      # In all.SHA256SUMS only (not part of the noncodesigned set).
      expectedSha256 = upstreamSha256 "bitcoin-${version}-codesignatures-${version}.tar.gz";
    };

  # bitcoin-${version}.tar.gz: build.sh's `git archive --prefix=
  # bitcoin-${version}/ HEAD`. GitHub's tag archive is that same tar, so
  # re-gzipping it with guix's zlib level 6 reproduces the dist archive.
  # See nix/lib/source-dist-archive.nix.
  sourceDistArchive = pkgs.callPackage ./nix/lib/source-dist-archive.nix { } {
    inherit version src;
    expectedSha256 = upstreamSha256 "bitcoin-${version}.tar.gz";
  };

  aarch64 = import ./nix/aarch64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  riscv64 = import ./nix/riscv64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  armhf   = import ./nix/arm-linux-gnueabihf/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  ppc64   = import ./nix/powerpc64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  x86     = import ./nix/x86_64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  darwin  = import ./nix/darwin/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch detachedSigs upstreamSha256; };
  win64   = import ./nix/win64/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch detachedSigs upstreamSha256; };

  # The non-codesigned artifacts in upstream's noncodesigned.SHA256SUMS
  # order (verified against bitcoin-core/guix.sigs#2544). guix-attest sorts
  # each per-host SHA256SUMS.part fragment by its pre-basename PATH
  # (<outdir_base>/<HOST>/<file>), so the effective order is HOSTS
  # alphabetically, with dist-archive between arm64-apple-darwin and
  # powerpc64-linux-gnu. all.SHA256SUMS (signed artifacts interleaved ahead
  # of each darwin/win64 group) comes back with the detached sigs; the v31.1
  # version is in git history at commit 4599977e9723.
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

  # all.SHA256SUMS = noncodesignedArtifacts with the 6 SIGNED darwin/win64
  # outputs and the codesignatures archive interleaved into the
  # arm64-apple-darwin, dist-archive, x86_64-apple-darwin and win64 groups,
  # ahead of that group's noncodesigned entries — see the ordering note
  # above.
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

  # noncodesigned.SHA256SUMS of our 21 artifacts, diffed against the
  # checked-in attestation (order included) when that file exists.
  noncodesignedSha256sums = import ./nix/lib/sha256sums.nix
    { inherit (pkgs) runCommandLocal coreutils gnused diffutils; }
    {
      name = "noncodesigned.SHA256SUMS";
      files = noncodesignedArtifacts;
      expected = if builtins.pathExists ./noncodesigned.SHA256SUMS
        then ./noncodesigned.SHA256SUMS else null;
    };

  # all.SHA256SUMS over all 28 artifacts. No attestation exists for 32.0rc1
  # yet, so this only PRINTS the hashes; it starts diffing the moment an
  # all.SHA256SUMS is checked in.
  sha256sums = import ./nix/lib/sha256sums.nix
    { inherit (pkgs) runCommandLocal coreutils gnused diffutils; }
    {
      name = "all.SHA256SUMS";
      files = allArtifactsOrdered;
      expected = if builtins.pathExists ./all.SHA256SUMS
        then ./all.SHA256SUMS else null;
    };
in {
  inherit (x86) depends dependsNoQt bitcoind bitcoindNoGui bitcoindGui packaged tarball debugTarball;
  inherit (aarch64) dependsAarch64 dependsNoQtAarch64 bitcoindAarch64 packagedAarch64
    bitcoindNoGuiAarch64 bitcoindGuiAarch64 tarballAarch64 debugTarballAarch64;
  inherit (riscv64) dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64;
  inherit (armhf) dependsArmhf bitcoindArmhf tarballArmhf debugTarballArmhf;
  inherit (ppc64) dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64;
  inherit (riscv64) riscv64Cross;
  inherit (armhf) armhfCross;
  inherit (ppc64) ppc64Cross;
  inherit (aarch64) crossGlibc231;
  inherit (x86) crossGlibc231X86 crossGuixGccX86;
  inherit (darwin) llvmPackages1914 clangDarwin lldDarwin llvmDarwin darwinSdk dependsNoQtDarwinX86 dependsNoQtDarwinArm64
    dependsDarwinX86 dependsDarwinArm64 bitcoindDarwinX86 bitcoindDarwinArm64
    tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
    signapple codesigningDarwinX86 codesigningDarwinArm64
    signedDarwinX86 signedDarwinArm64;
  inherit (win64) mingwGuixGcc mingwGuixGccNoFp mingwBinutils pkgsCrossMingw dependsMingw dependsNoQtMingw
    bitcoindMingwNoGui bitcoindMingwGui
    mingwCrtStdenv mingwCrt
    bitcoindMingw packagedMingw unsignedZipMingw debugZipMingw
    nsisGcc14 nsis setupExeMingw codesigningMingw
    osslsigncode25 signedMingw;
  inherit src sourceDistArchive noncodesignedSha256sums
    detachedSigs codesignaturesArchive sha256sums;
}
