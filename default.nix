{ pkgs ? import <nixpkgs> {}
}:

let
  # The v32.0rc4 tag (310071f8d0c5, "Merge bitcoin/bitcoin#36498: [32.0]
  # 32.0rc4"). GUIX's prelude.bash `git_head_version` takes the tag name
  # without its leading `v` as the VERSION, and DISTNAME = bitcoin-<version>
  # is what every published artifact name is built from.
  #
  # Between v32.0rc3 and v32.0rc4 (15 commits, 33 files) `contrib/guix/`
  # and `depends/` are untouched ENTIRELY — as they have been since the
  # branch-off — so the guix time-machine pin stays c5eee3336cc1, every
  # toolchain pin stays put, and package.sh/codesign.sh are the same
  # scripts rc2 and rc3 were verified against. The delta is src/ (private
  # broadcast completion, httpserver read accounting, Sock::WaitMany's
  # timeout cap, bitcoin-util's genesis hash order, an RPC OpenRPC hex
  # pattern), the version bump, generated doc/man, plus test/ci-only churn:
  # it moves the binaries but not how they are built.
  version = "32.0rc4";

  # SOURCE_DATE_EPOCH: the tagged commit's own commit time
  # (2026-10-12T03:58:14Z), exactly like guix-build derives it
  # (`git log --format=%at -1`).
  sourceDateEpoch = 1791777494;

  # The source tree. GitHub's archive of a TAG is `git archive
  # --prefix=bitcoin-<version>/` of the tagged commit — the same command
  # guix's build.sh runs for its dist archive — so it is used as is: every
  # consumer extracts bitcoin-${version}/ from it, and sourceDistArchive
  # below re-gzips it into the published dist archive.
  src = pkgs.fetchurl {
    name = "bitcoin-${version}.tar.gz";
    url = "https://github.com/bitcoin/bitcoin/archive/refs/tags/v${version}.tar.gz";
    hash = "sha256-2xfyhsN8kc9UW8l4gSBm5OPtMCow7DBNXLktB48kXgA=";
  };

  # Upstream reference hashes, parsed from the checked-in
  # noncodesigned.SHA256SUMS / all.SHA256SUMS (both from
  # bitcoin-core/guix.sigs) — every gate looks its artifact up here by
  # PUBLISHED FILENAME instead of hardcoding the hash. A filename missing
  # from both files resolves to null and its gate is skipped with a
  # "no upstream gate" log line.
  #
  # Both files are the guix.sigs 32.0rc4 attestations: all 12 signers
  # published a byte-identical noncodesigned.SHA256SUMS, and 10 of them a
  # byte-identical all.SHA256SUMS. The files have to stay git-tracked, or
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

  # Detached signatures (bitcoin-core/bitcoin-detached-sigs @ v32.0rc4) —
  # used by both the darwin and win64 signed-artifact flows, so they live
  # here rather than inside either target's toolchain. The v32.0rc4 tag
  # (07e61362) peels to 760896cf and carries both osx/ (760896c, "32.0: osx
  # sig for rc4") and win/ (491626d, "32.0: win sig for rc4").
  #
  # Like rc2 and rc3, this rc HAS an all.SHA256SUMS (10 byte-identical
  # signers), checked in at the repo root, so upstreamSha256 resolves the 6
  # signed artifacts + the codesignatures archive and all 28 are gated.
  # (The file must stay git-tracked or a pure flake eval cannot read it —
  # see parseSha256sums above.)
  detachedSigsRev = "760896cf5e2a86310147f476dbb0fdcf3da1c986"; # v32.0rc4
  detachedSigs = pkgs.fetchFromGitHub {
    owner = "bitcoin-core";
    repo = "bitcoin-detached-sigs";
    rev = detachedSigsRev;
    hash = "sha256-QLCub+vkadDjqAQmrFfPlNi7AwH6O/LQtjYbvbF2qys=";
  };

  # bitcoin-${version}-codesignatures-${version}.tar.gz: codesign.sh's
  # `git archive HEAD` of the bitcoin-detached-sigs repo at the v${version}
  # tag — GENERATED from the same repo detachedSigs is fetched from, with
  # .git metadata this time so `git archive` has a tree to work from. See
  # nix/lib/codesignatures.nix for the byte-exact git-archive + gzip.
  # (codesign.sh names it after git_head_version of the SIGS repo, i.e. the
  # tag minus "v" — hence the version twice.)
  detachedSigsGit = pkgs.fetchgit {
    url = "https://github.com/bitcoin-core/bitcoin-detached-sigs";
    rev = detachedSigsRev;
    leaveDotGit = true;
    hash = "sha256-+JPGLogHfsiKkCJ+yYmlID3IKYCFOYDp0Yg6iBZQx1Y=";
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

  # EVERY published artifact, in upstream's all.SHA256SUMS order (verified
  # against guix.sigs 32.0rc4). guix-attest sorts each per-host
  # SHA256SUMS.part fragment by its pre-basename PATH
  # (<outdir_base>/<HOST>/<file>), so the effective order is HOSTS
  # alphabetically, with dist-archive between arm64-apple-darwin and
  # powerpc64-linux-gnu, and each group's SIGNED entries ahead of that
  # group's noncodesigned ones.
  #
  # noncodesigned.SHA256SUMS is EXACTLY this list with the `signed = true`
  # rows removed — checked line-for-line against both checked-in
  # attestations — so both aggregators are derived from this one table
  # rather than kept in sync by hand. (The v31.1 ordering is in git history
  # at commit 4599977e9723.)
  artifactTable = [
    # aarch64-linux-gnu
    { file = aarch64.debugTarballAarch64; }
    { file = aarch64.tarballAarch64; }
    # arm-linux-gnueabihf
    { file = armhf.debugTarballArmhf; }
    { file = armhf.tarballArmhf; }
    # arm64-apple-darwin (signed first)
    { signed = true; file = "${darwin.signedDarwinArm64}/bitcoin-${version}-arm64-apple-darwin.tar.gz"; }
    { signed = true; file = "${darwin.signedDarwinArm64}/bitcoin-${version}-arm64-apple-darwin.zip"; }
    { file = darwin.codesigningDarwinArm64; }
    { file = darwin.tarballDarwinArm64; }
    { file = darwin.zipDarwinArm64; }
    # dist-archive
    { signed = true; file = codesignaturesArchive; }
    { file = sourceDistArchive; }
    # powerpc64-linux-gnu
    { file = ppc64.debugTarballPpc64; }
    { file = ppc64.tarballPpc64; }
    # riscv64-linux-gnu
    { file = riscv64.debugTarballRiscv64; }
    { file = riscv64.tarballRiscv64; }
    # x86_64-apple-darwin (signed first)
    { signed = true; file = "${darwin.signedDarwinX86}/bitcoin-${version}-x86_64-apple-darwin.tar.gz"; }
    { signed = true; file = "${darwin.signedDarwinX86}/bitcoin-${version}-x86_64-apple-darwin.zip"; }
    { file = darwin.codesigningDarwinX86; }
    { file = darwin.tarballDarwinX86; }
    { file = darwin.zipDarwinX86; }
    # x86_64-linux-gnu
    { file = x86.debugTarball; }
    { file = x86.tarball; }
    # x86_64-w64-mingw32 (win64) (signed first)
    { signed = true; file = "${win64.signedMingw}/bitcoin-${version}-win64-setup.exe"; }
    { signed = true; file = "${win64.signedMingw}/bitcoin-${version}-win64.zip"; }
    { file = win64.codesigningMingw; }
    { file = win64.debugZipMingw; }
    { file = win64.setupExeMingw; }
    { file = win64.unsignedZipMingw; }
  ];
  allArtifactsOrdered = map (a: a.file) artifactTable;
  noncodesignedArtifacts =
    map (a: a.file) (builtins.filter (a: !(a.signed or false)) artifactTable);

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

  # all.SHA256SUMS over all 28 artifacts, diffed against the checked-in
  # guix.sigs attestation (10 signers posted a byte-identical one for rc4).
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
    osslsigncode214 signedMingw;
  inherit src sourceDistArchive noncodesignedSha256sums
    detachedSigs codesignaturesArchive sha256sums;
}
