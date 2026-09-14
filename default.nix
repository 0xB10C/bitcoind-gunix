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

  # Detached signatures are OFF until bitcoin-core/bitcoin-detached-sigs
  # tags v${version}. Passing null keeps the whole signing pipeline (darwin
  # signedDarwin{X86,Arm64}, win64 signedMingw, codesignaturesArchive) out
  # of the exposed outputs; the UNSIGNED and -codesigning artifacts do not
  # need it and stay wired up.
  detachedSigs = null;

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
    osslsigncode25;
  inherit src sourceDistArchive noncodesignedSha256sums;
}
