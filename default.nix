{ pkgs ? import <nixpkgs> {}
}:

let
  # The v32.0 tag (465dde277447, "Merge bitcoin/bitcoin#36508: [32.0]
  # Finalize") — the FINAL release, not a candidate. GUIX's prelude.bash
  # `git_head_version` takes the tag name without its leading `v` as the
  # VERSION, and DISTNAME = bitcoin-<version> is what every published
  # artifact name is built from, so every filename loses its `rc4` suffix.
  #
  # Between v32.0rc4 and v32.0 only 4 commits / 9 files land, and not one
  # of them is a source file: the CMakeLists.txt version bump, the
  # generated doc/man/*.1 pages, and doc/release-notes.md. The top-level
  # tree SHAs say it outright — at both commits src/ is de61fd90d2b6,
  # contrib/ is f78f367f9a35 and depends/ is 4b6789e5e351 — so every
  # toolchain pin stays put (guix time-machine c5eee3336cc1, unchanged
  # since rc1) and package.sh/codesign.sh are the same scripts rc2, rc3 and
  # rc4 were verified against. The ONLY input that moves is the version
  # string: it changes the embedded version, every published filename, and
  # DISTSRC (distsrc-32.0-<host>, three chars shorter than rc4's).
  version = "32.0";

  # SOURCE_DATE_EPOCH: the tagged commit's own commit time
  # (2026-10-21T13:21:46Z), exactly like guix-build derives it
  # (`git log --format=%at -1`).
  sourceDateEpoch = 1792588906;

  # The source tree. GitHub's archive of a TAG is `git archive
  # --prefix=bitcoin-<version>/` of the tagged commit — the same command
  # guix's build.sh runs for its dist archive — so it is used as is: every
  # consumer extracts bitcoin-${version}/ from it, and sourceDistArchive
  # below re-gzips it into the published dist archive.
  src = pkgs.fetchurl {
    name = "bitcoin-${version}.tar.gz";
    url = "https://github.com/bitcoin/bitcoin/archive/refs/tags/v${version}.tar.gz";
    hash = "sha256-lHUfic44I0vLUbRA63tZkmARyAt0ws75j13CDGWSsJ4=";
  };

  # Upstream reference hashes, parsed from the checked-in
  # noncodesigned.SHA256SUMS / all.SHA256SUMS (both from
  # bitcoin-core/guix.sigs) — every gate looks its artifact up here by
  # PUBLISHED FILENAME instead of hardcoding the hash. A filename missing
  # from both files resolves to null and its gate is skipped with a
  # "no upstream gate" log line.
  #
  # noncodesigned.SHA256SUMS is the guix.sigs 32.0 attestation (hebasto,
  # svanstaa and willcl-ark published a byte-identical 21-line file);
  # all.SHA256SUMS is the 28-line one that appeared once
  # bitcoin-detached-sigs tagged v32.0 (achow101, fanquake and willcl-ark,
  # again byte-identical). The invariant that lets artifactTable feed both
  # aggregators holds here: all.SHA256SUMS minus its 7 `signed = true` rows
  # IS noncodesigned.SHA256SUMS byte-for-byte. A target with no sigs tag
  # yet simply has no ./all.SHA256SUMS, which parseSha256sums handles by
  # returning { }. Both files have to stay git-tracked, or flake eval won't
  # see them.
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

  # Detached signatures — used by both the darwin and win64 signed-artifact
  # flows, so they live here rather than inside either target's toolchain.
  #
  # ON at v32.0: bitcoin-core/bitcoin-detached-sigs tagged v32.0 on
  # 2026-10-22. The tag (627019d1) peels to f542f52a and carries both
  # osx/ (f8bbfaf0, "32.0: osx sig for final") and win/ (f542f52a, "32.0:
  # win sig for final") for the final version string, so all 7 signed
  # artifacts can be built; guix.sigs 32.0 now also has an all.SHA256SUMS
  # (achow101, fanquake and willcl-ark published a byte-identical one, and
  # its 21 non-signed lines ARE the checked-in noncodesigned.SHA256SUMS
  # byte-for-byte), so all 28 are gated. The attestation must stay
  # git-tracked or a pure flake eval cannot read it — see parseSha256sums
  # above.
  #
  # Setting this to null is how a target with no sigs tag yet is handled:
  # it keeps the whole signing pipeline (darwin signedDarwin{X86,Arm64},
  # win64 signedMingw, codesignaturesArchive and the `.#sha256sums`
  # aggregator over all 28) out of the exposed outputs via the
  # `lib.optionalAttrs` blocks in both toolchains and at the bottom of this
  # file, leaving the 21 non-codesigned artifacts gated. rc1 and the first
  # day of v32.0 were both in that state.
  detachedSigsPin = {
    rev     = "f542f52a2ad38173ae554f81b0781a05f5a8e120";  # v32.0
    hash    = "sha256-OkDshyj+MFrzG+IiWrtdjWyPFc9oQOwBqOa2MPgXi8g=";
    gitHash = "sha256-cZyc2Lauvvqkd9a8vNMgR81XPqfrj6B0U4QDUYzfTN0=";
  };
  signedFlow = detachedSigsPin != null;
  detachedSigs = if !signedFlow then null else pkgs.fetchFromGitHub {
    owner = "bitcoin-core";
    repo = "bitcoin-detached-sigs";
    inherit (detachedSigsPin) rev hash;
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
    rev = detachedSigsPin.rev;
    leaveDotGit = true;
    hash = detachedSigsPin.gitHash;
  };
  codesignaturesArchive = if !signedFlow then null else
    import ./nix/lib/codesignatures.nix
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

  # EVERY published artifact, in upstream's all.SHA256SUMS order.
  # guix-attest sorts each per-host SHA256SUMS.part fragment by its
  # pre-basename PATH (<outdir_base>/<HOST>/<file>), so the effective order
  # is HOSTS alphabetically, with dist-archive between arm64-apple-darwin
  # and powerpc64-linux-gnu, and each group's SIGNED entries ahead of that
  # group's noncodesigned ones.
  #
  # noncodesigned.SHA256SUMS is EXACTLY this list with the `signed = true`
  # rows removed, so both aggregators are derived from this one table
  # rather than kept in sync by hand. At 32.0 the noncodesigned half was
  # re-checked filename-for-filename against the checked-in attestation
  # (same 21 names in the same order as rc4, minus the `rc4` suffix), and
  # the signed rows were re-checked the same way against the 32.0
  # all.SHA256SUMS that appeared with the sigs tag — the positions are
  # rc2/rc3/rc4's unchanged. (The v31.1 ordering is in git history
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

  # all.SHA256SUMS over all 28 artifacts, diffed against a checked-in
  # guix.sigs attestation when one exists. Defined only while the signed
  # flow is on: without detached signatures 7 of its 28 rows cannot be
  # built at all (see the detachedSigsPin note above).
  sha256sums = if !signedFlow then null else
    import ./nix/lib/sha256sums.nix
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
    signapple codesigningDarwinX86 codesigningDarwinArm64;
  inherit (win64) mingwGuixGcc mingwGuixGccNoFp mingwBinutils pkgsCrossMingw dependsMingw dependsNoQtMingw
    bitcoindMingwNoGui bitcoindMingwGui
    mingwCrtStdenv mingwCrt
    bitcoindMingw packagedMingw unsignedZipMingw debugZipMingw
    nsisGcc14 nsis setupExeMingw codesigningMingw
    osslsigncode214;
  inherit src sourceDistArchive noncodesignedSha256sums;
} // pkgs.lib.optionalAttrs signedFlow {
  # The signed artifacts, the codesignatures archive and the all-28
  # aggregator exist only when there are detached signatures to apply —
  # see the detachedSigsPin note above. Both toolchains gate their own
  # signed attrs the same way, so these inherits would fail to resolve
  # if this block were unconditional.
  inherit (darwin) signedDarwinX86 signedDarwinArm64;
  inherit (win64) signedMingw;
  inherit detachedSigs codesignaturesArchive sha256sums;
}
