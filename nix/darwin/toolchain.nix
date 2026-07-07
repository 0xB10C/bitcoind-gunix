{ pkgs, version, url, sha256, buildSystem, sourceDateEpoch, detachedSigs, upstreamSha256 }:

  #
  # ───────────────────── macOS (darwin) toolchain ──────────────────────
  #
  # GUIX builds the two darwin releases (arm64-/x86_64-apple-darwin) with
  # plain clang-toolchain-19 + lld-19 (symlinked as `ld`) from its
  # llvm.scm — LLVM/clang/lld 19.1.4 — against the extracted Xcode SDK;
  # there is NO custom gcc/glibc cross toolchain for darwin at all
  # (manifest.scm, darwin branch). nixpkgs-26.05's llvmPackages_19 is
  # 19.1.7, so re-pin the whole LLVM set to GUIX's exact 19.1.4 (clang
  # point releases contain codegen fixes — the version must match).
  #
  # The toolchain is used UNWRAPPED — bare clang/clang++/ld.lld/llvm-* on
  # PATH, like the binaries in GUIX's profile: depends/hosts/darwin.mk
  # passes all the cross flags explicitly (--target, -isysroot,
  # -nostdlibinc, -iwithsysroot, -mlinker-version=711), and skipping the
  # nixpkgs cc-wrapper means none of its injected flags (hardening,
  # frame pointers, -march) exist in the first place. Note darwin release
  # builds carry no -g and Mach-O has no .comment, so compile flags are
  # never recorded in the artifacts.
  # The pin is done via an OVERLAY (own nixpkgs import, like the cross
  # package sets) rather than a plain llvmPackages_19.override: the llvm
  # build takes LLVM_TABLEGEN from buildPackages.llvmPackages_19.tblgen
  # through the splice machinery, which a local .override doesn't reach —
  # it would TableGen 19.1.4's .td files with a 19.1.7 tblgen. The overlay
  # makes the spliced set the pinned one, so tblgen is 19.1.4 as well
  # (GUIX builds tblgen in-tree from the same source).

let
  pkgsLlvm1914 = import pkgs.path {
    localSystem = { system = buildSystem; };
    overlays = [
      (final: prev: {
        llvmPackages_19 = prev.llvmPackages_19.override {
          version = "19.1.4";
          officialRelease = {
            sha256 = "sha256-qi1a/AWxF5j+4O38VQ2R/tvnToVAlMjgv9SP0PNWs3g=";
          };
        };
      })
    ];
  };
  llvmPackages1914 = pkgsLlvm1914.llvmPackages_19;
  # nixpkgs moves clang's builtin headers (stdarg.h etc.) into the
  # separate `lib` output and normally reglues them via the cc-wrapper's
  # -resource-dir — which we don't use. clang locates its resource dir
  # relative to the REALPATH of the executable, so symlinking the
  # binaries wouldn't work either: reunite real copies of bin/ with a
  # complete lib/clang/19 in one GUIX-shaped store path.
  clangDarwin = pkgs.runCommand "clang-guix-19.1.4" {} ''
    mkdir -p $out/lib/clang/19
    cp -a ${llvmPackages1914.clang-unwrapped}/bin $out/bin
    cp -a ${llvmPackages1914.clang-unwrapped.lib}/lib/clang/19/include \
      $out/lib/clang/19/include
  '';
  lldDarwin = llvmPackages1914.lld;
  llvmDarwin = llvmPackages1914.llvm;

  # The extracted macOS SDK (headers + frameworks + libc++ headers,
  # produced by contrib/macdeploy/gen-sdk.py from the Xcode 26.1.1 xip).
  # Publicly hosted on Bitcoin Core's depends-sources mirror; the sha256
  # is the one documented in contrib/macdeploy/README.md. Extracted into
  # its own store path so the -isysroot baked into depends'
  # toolchain.cmake remains valid in the downstream bitcoind build
  # sandbox. NOTE: Apple-licensed content — never push this path (or
  # anything whose closure contains it) to the public Cachix.
  darwinSdk = pkgs.runCommand "darwin-sdk-xcode-26.1.1-17B100" {} ''
    mkdir $out
    tar -xf ${pkgs.fetchurl {
      url = "https://bitcoincore.org/depends-sources/sdks/Xcode-26.1.1-17B100-extracted-SDK-with-libcxx-headers.tar";
      sha256 = "9600fa93644df674ee916b5e2c8a6ba8dacf631996a65dc922d003b98b5ea3b1";
    }} -C $out
  '';

  darwinCrossInputs = [ clangDarwin lldDarwin llvmDarwin ];

  # depends trees for the two darwin releases. Unlike the Linux targets
  # there is no custom cross toolchain: darwin.mk picks the bare
  # clang/llvm-* tools off PATH (crossInputs) and compiles against the
  # SDK; the native helper tools still use the gcc14 stdenv like every
  # other target (GUIX: gcc-toolchain-14 as NATIVE_GCC, build.sh).
  dependsDarwinX86 = pkgs.callPackage ../lib/depends.nix {
    inherit version url sha256 darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "x86_64-apple-darwin";
    buildQt = true;
    crossInputs = darwinCrossInputs;
  };
  dependsDarwinArm64 = pkgs.callPackage ../lib/depends.nix {
    inherit version url sha256 darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "arm64-apple-darwin";
    buildQt = true;
    crossInputs = darwinCrossInputs;
  };

  # The 10 Mach-O binaries of each darwin release. Per-binary reference
  # hashes are not published for v31.1 (upstream's noncodesigned.SHA256SUMS
  # covers only the assembled archives, gated below) — empty expectedHashes
  # skips the per-binary gate; the release build prints the hashes instead.
  bitcoindDarwinX86 = pkgs.callPackage ./release.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinX86;
    crossInputs = darwinCrossInputs;
    hostTriple = "x86_64-apple-darwin";
    pname = "bitcoind-darwin-x86_64";
    expectedHashes = { };
  };
  bitcoindDarwinArm64 = pkgs.callPackage ./release.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinArm64;
    crossInputs = darwinCrossInputs;
    hostTriple = "arm64-apple-darwin";
    pname = "bitcoind-darwin-arm64";
    expectedHashes = { };
  };
  # The published darwin -unsigned artifacts. The -unsigned.tar.gz is
  # assembled like the linux release archives (build.sh darwin case: no
  # README.md, no .dbg); the -unsigned.zip IS the deploy target's
  # bitcoin-macos-app.zip under its release name (build.sh just mv's it).
  tarballDarwinX86 = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256 sourceDateEpoch;
    bitcoind = bitcoindDarwinX86;
    arch = "x86_64-apple-darwin";
    darwinUnsigned = true;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-x86_64-apple-darwin-unsigned.tar.gz";
  };
  tarballDarwinArm64 = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256 sourceDateEpoch;
    bitcoind = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    darwinUnsigned = true;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-arm64-apple-darwin-unsigned.tar.gz";
  };
  mkDarwinUnsignedZip = { bitcoindDarwin, arch, expectedSha256 }:
    pkgs.runCommandLocal "bitcoin-${version}-${arch}-unsigned.zip" {} ''
      cp ${bitcoindDarwin.dist}/bitcoin-macos-app.zip "$out"
      actual=$(sha256sum "$out" | cut -d' ' -f1)
      if [ "$actual" != "${expectedSha256}" ]; then
        echo "FAIL: unsigned zip sha256 does not match upstream GUIX release"
        echo "  expected: ${expectedSha256}"
        echo "  actual:   $actual"
        exit 1
      fi
      echo "OK: bitcoin-${version}-${arch}-unsigned.zip matches upstream ($actual)"
    '';
  zipDarwinX86 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinX86;
    arch = "x86_64-apple-darwin";
    expectedSha256 = upstreamSha256 "bitcoin-${version}-x86_64-apple-darwin-unsigned.zip";
  };
  zipDarwinArm64 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    expectedSha256 = upstreamSha256 "bitcoin-${version}-arm64-apple-darwin-unsigned.zip";
  };

  # --- darwin signed artifacts -------------------------------------------
  # signapple (+ its elfesteem) pinned to GUIX's manifest, and the v31.1
  # detached signatures. These reproduce the -codesigning.tar.gz and the
  # SIGNED .tar.gz/.zip. The signed artifacts appear only in upstream's
  # all.SHA256SUMS (not published yet) — their expected hashes resolve to
  # null and the gate is skipped until that file is checked in.
  signapple = pkgs.callPackage ./signapple.nix { };
  codesigningDarwinX86 = pkgs.callPackage ./codesigning.nix {
    inherit version url sha256 sourceDateEpoch;
    host = "x86_64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinX86;
    unsignedTarball = tarballDarwinX86;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-x86_64-apple-darwin-codesigning.tar.gz";
  };
  codesigningDarwinArm64 = pkgs.callPackage ./codesigning.nix {
    inherit version url sha256 sourceDateEpoch;
    host = "arm64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinArm64;
    unsignedTarball = tarballDarwinArm64;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-arm64-apple-darwin-codesigning.tar.gz";
  };
  signedDarwinX86 = pkgs.callPackage ./signed.nix {
    inherit version sourceDateEpoch signapple detachedSigs;
    host = "x86_64-apple-darwin";
    arch = "x86_64";
    codesigningTarball = codesigningDarwinX86;
    expectedTarballSha256 = upstreamSha256 "bitcoin-${version}-x86_64-apple-darwin.tar.gz";
    expectedZipSha256 = upstreamSha256 "bitcoin-${version}-x86_64-apple-darwin.zip";
  };
  signedDarwinArm64 = pkgs.callPackage ./signed.nix {
    inherit version sourceDateEpoch signapple detachedSigs;
    host = "arm64-apple-darwin";
    arch = "arm64";
    codesigningTarball = codesigningDarwinArm64;
    expectedTarballSha256 = upstreamSha256 "bitcoin-${version}-arm64-apple-darwin.tar.gz";
    expectedZipSha256 = upstreamSha256 "bitcoin-${version}-arm64-apple-darwin.zip";
  };
in {
  inherit llvmPackages1914 clangDarwin lldDarwin llvmDarwin darwinSdk
    dependsDarwinX86 dependsDarwinArm64 bitcoindDarwinX86 bitcoindDarwinArm64
    tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
    signapple codesigningDarwinX86 codesigningDarwinArm64 signedDarwinX86 signedDarwinArm64;
}
