{ pkgs ? import <nixpkgs> {}
}:

let
  # The v32.x BRANCH-OFF commit on master (bitcoin/bitcoin#36227, "Pre 32.x
  # branching updates", 2026-09-11). It carries no tag, so GUIX's
  # prelude.bash `git_head_version` falls back to `git rev-parse
  # --short=12 HEAD` — that short hash is the VERSION, and hence
  # DISTNAME = bitcoin-<short12>, that every published artifact name is
  # built from.
  commit = "f3fec67c3eeb27d5be1bc9d57ca737b74fcd762d";
  version = "f3fec67c3eeb";

  # SOURCE_DATE_EPOCH: the branch-off commit's own commit time
  # (2026-09-11T17:11:36+01:00), exactly like guix-build derives it
  # (`git log --format=%at -1`).
  sourceDateEpoch = 1789143096;

  # The source tree, repacked under GUIX's DISTNAME prefix.
  #
  # GUIX extracts its dist archive (`git archive --prefix=$DISTNAME/`) into
  # $DISTSRC, so every path the build sees starts with bitcoin-<short12>/.
  # GitHub's archive of a COMMIT (there is no tag to fetch here) uses the
  # FULL 40-char sha as its prefix instead, so we unpack and repack it
  # under bitcoin-${version}/ — the contents are identical (both are
  # `git archive` of the same tree) and every consumer below keeps its
  # bitcoin-${version} path assumptions.
  #
  # NOTE: this repack is a BUILD INPUT only, never a published artifact.
  # The dist-archive itself (bitcoin-${version}.tar.gz in upstream's
  # SHA256SUMS) has to come out of a real `git archive` — its pax headers
  # for >99-char paths depend on the prefix length, so a rename-repack of
  # the 40-char-prefixed GitHub archive would NOT be byte-identical. See
  # the dropped sourceDistArchive note further down.
  srcArchive = pkgs.fetchurl {
    url = "https://github.com/bitcoin/bitcoin/archive/${commit}.tar.gz";
    hash = "sha256-aLcMQjq7YQ7e5TadrhHNOtT5ExXSh9kVIXA0rKtQff0=";
  };
  src = pkgs.runCommand "bitcoin-${version}.tar.gz" { } ''
    mkdir unpack
    tar xzf ${srcArchive} -C unpack
    mv unpack/bitcoin-${commit} unpack/bitcoin-${version}
    tar --create --sort=name --owner=0 --group=0 --numeric-owner \
        --mtime=@${toString sourceDateEpoch} -C unpack bitcoin-${version} \
      | gzip -n > $out
  '';

  # Upstream reference hashes, parsed from the checked-in
  # noncodesigned.SHA256SUMS / all.SHA256SUMS (both from
  # bitcoin-core/guix.sigs) — every gate looks its artifact up here by
  # PUBLISHED FILENAME instead of hardcoding the hash. A filename missing
  # from both files resolves to null and its gate is skipped with a
  # "no upstream gate" log line.
  #
  # The branch-off commit is not a release, so guix.sigs has no attestation
  # for it. The two files still hold v31.1's hashes, and no v31.1 filename
  # matches a bitcoin-${version}-… artifact, so every byte-match gate is
  # currently OFF. The reference to diff against is a LOCAL guix build of
  # the same commit; replacing the file's contents with that build's
  # output/<host>/SHA256SUMS.part fragments turns every gate back on with
  # no nix changes (the file just has to stay git-tracked, or flake eval
  # won't see it).
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

  # Detached signatures + the two `git archive` artifacts are OFF for the
  # branch-off commit.
  #
  # - detachedSigs: bitcoin-core/bitcoin-detached-sigs only ever grows tags
  #   for RELEASES, so there is nothing to sign against at a master commit.
  #   Passing null keeps the whole signing pipeline (darwin
  #   signedDarwin{X86,Arm64}, win64 signedMingw, codesignaturesArchive) out
  #   of the exposed outputs, exactly as the v31.1rc1 tree did before the
  #   v31.1 tag landed. The UNSIGNED and -codesigning artifacts do not need
  #   it and stay wired up.
  # - sourceDistArchive (bitcoin-${version}.tar.gz): reproducing it means
  #   reproducing `git archive --prefix=bitcoin-${version}/ HEAD` byte for
  #   byte. For a tagged release GitHub's own tag archive IS that output, so
  #   we only had to re-gzip it; for an untagged commit GitHub prefixes with
  #   the full 40-char sha, which changes the pax long-path headers, so the
  #   shortcut does not hold. Needs a real `git archive` (fetchgit +
  #   leaveDotGit, like nix/lib/codesignatures.nix does for the
  #   detached-sigs repo) — left for when the guix reference exists to
  #   compare against.
  detachedSigs = null;

  aarch64 = import ./nix/aarch64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  riscv64 = import ./nix/riscv64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  armhf   = import ./nix/arm-linux-gnueabihf/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  ppc64   = import ./nix/powerpc64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  x86     = import ./nix/x86_64-linux-gnu/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch upstreamSha256; };
  darwin  = import ./nix/darwin/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch detachedSigs upstreamSha256; };
  win64   = import ./nix/win64/toolchain.nix { inherit pkgs version src buildSystem sourceDateEpoch detachedSigs upstreamSha256; };

  # The SHA256SUMS aggregators (nix/lib/sha256sums.nix) are dropped for the
  # branch-off commit, along with the ordered artifact lists they consume.
  # They exist to be `diff`ed against upstream's published
  # noncodesigned.SHA256SUMS / all.SHA256SUMS, and neither exists for a
  # master commit; they also include the two `git archive` artifacts that
  # are off here (see the detachedSigs note above). Restore them together
  # with the gates once a reference SHA256SUMS is checked in — the v31.1
  # versions, including the exact upstream ordering comment, are in git
  # history at commit 4599977e9723.
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
  inherit src srcArchive;
}
