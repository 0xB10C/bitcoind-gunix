{ pkgs, version, url, sha256, buildSystem, sourceDateEpoch, detachedSigs }:

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

  # The 10 Mach-O binaries of each darwin release. Reference hashes taken
  # from the published -unsigned.tar.gz (per achow101's all.SHA256SUMS).
  bitcoindDarwinX86 = pkgs.callPackage ./release.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinX86;
    crossInputs = darwinCrossInputs;
    hostTriple = "x86_64-apple-darwin";
    pname = "bitcoind-darwin-x86_64";
    expectedHashes = {
      "bin/bitcoin" = "09fce95d0c8667cf896164ccaab3550b0d38332e2900311675bda851d878f754";
      "bin/bitcoin-cli" = "bcd48926ee344073f4a7e911941aa38e495bbb3c8cd572aa01cac3d5f3d65628";
      "bin/bitcoind" = "52089f2ed3e435f4390af39dd5cd94837e75a3a0ca055cdb997f10bd4165f02d";
      "bin/bitcoin-qt" = "a6131bbae00092f2bfd52749d47a32c5bf7862614c93c8074e8d69a5291b734a";
      "bin/bitcoin-tx" = "a6f24392c4843b7f8542f047814e70257c624981497bbb016312367e045819e4";
      "bin/bitcoin-util" = "71ed0b8df68db34473110efc3c25f81034a4679d6f1bcd3c108bb780acc645c5";
      "bin/bitcoin-wallet" = "45df0e4f4f0ee29e36b93a02cd1527e0c0e14d414ec46a3fc254ad99e966dce2";
      "libexec/bitcoin-gui" = "c91cbe028c1d5786ec9a8fe1e27140d17ae88a224e11d1e7b72367b9bbf10236";
      "libexec/bitcoin-node" = "9d447fdf8263cf63292a4e98ebac1ddf423c4f08fee07199dfaa7f0203015e5d";
      "libexec/test_bitcoin" = "af5f03063963f4002d1ebaed9b0c707e09f9794d139363e2dc08e9f0ac79e2a3";
    };
  };
  bitcoindDarwinArm64 = pkgs.callPackage ./release.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinArm64;
    crossInputs = darwinCrossInputs;
    hostTriple = "arm64-apple-darwin";
    pname = "bitcoind-darwin-arm64";
    expectedHashes = {
      "bin/bitcoin" = "27f82ab5645937ac118efe6510936bd9df56bbded2fbd09befd948653a1a9bcb";
      "bin/bitcoin-cli" = "6cd8103fe1657b3eef6855fbcd950d02f3bcbb2f39fcf44490e416ca62713f6b";
      "bin/bitcoind" = "e20bf28941733b7e6a4817995f2433e86bb19fd37c666a6fc269add8e95e5219";
      "bin/bitcoin-qt" = "bfd2eac9f16e64e9e71da20f10a365a49e04e17c0d59845f706690d1eba928d3";
      "bin/bitcoin-tx" = "f018ab5e9d621faeac5d04c4d37046f4a7a754a44b9cf1930e2287e74b0bda84";
      "bin/bitcoin-util" = "4aa6a063b4f0f1de41df88f987bfa2a0b57717309d397ef7645202063f67069d";
      "bin/bitcoin-wallet" = "0afe5c41673cfb5b6678d27f07bc92727fa1af7c2e43311e3bd87cf0dc6c85dc";
      "libexec/bitcoin-gui" = "be610eec55155c772128d0fc4b504001c472c94a8aae78158662724574a56c3e";
      "libexec/bitcoin-node" = "825d8aacafb8d2d2f9b0016cf6993ac8c4629f6b57f7756af930167bde59d7ff";
      "libexec/test_bitcoin" = "87fba26b10a3154d155dd188135fd8deae04ba7043f808f617d74a37f047e87f";
    };
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
    expectedSha256 = "c3d4318855349f2d931154473671de780f2643d8e1e1ecc4ed97b0cfa6c50db8";
  };
  tarballDarwinArm64 = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256 sourceDateEpoch;
    bitcoind = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    darwinUnsigned = true;
    expectedSha256 = "6ddf76fa6eab9bd032ba7a293b55286d9a57f4566025f7f216eb41159a864398";
  };
  mkDarwinUnsignedZip = { bitcoindDarwin, arch, expectedSha256 }:
    pkgs.runCommandLocal "bitcoin-${version}-${arch}-unsigned.zip" {} ''
      cp ${bitcoindDarwin.dist}/bitcoin-macos-app.zip "$out"
      actual=$(sha256sum "$out" | cut -d' ' -f1)
      if [ "$actual" != "${expectedSha256}" ]; then
        echo "FAIL: unsigned zip sha256 does not match upstream GUIX v31.1rc1 release"
        echo "  expected: ${expectedSha256}"
        echo "  actual:   $actual"
        exit 1
      fi
      echo "OK: bitcoin-${version}-${arch}-unsigned.zip matches upstream ($actual)"
    '';
  zipDarwinX86 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinX86;
    arch = "x86_64-apple-darwin";
    expectedSha256 = "31bb7c87c5dbea60b81c49ee43206be459fd54342f421d9c221f0ae508582183";
  };
  zipDarwinArm64 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    expectedSha256 = "b428a2c07c9fb44b70f0ded0868adfe34e00d79d2f96293c7507802298fa549e";
  };

  # --- darwin signed artifacts -------------------------------------------
  # signapple (+ its elfesteem) pinned to GUIX's manifest, and the v31.1rc1
  # detached signatures. These reproduce the -codesigning.tar.gz and the
  # SIGNED .tar.gz/.zip.
  signapple = pkgs.callPackage ./signapple.nix { };
  codesigningDarwinX86 = pkgs.callPackage ./codesigning.nix {
    inherit version url sha256 sourceDateEpoch;
    host = "x86_64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinX86;
    unsignedTarball = tarballDarwinX86;
    expectedSha256 = "e3bb6be108847b36567203dcab1482abb6ffc20d1fe2acc2357404fbc54ae018";
  };
  codesigningDarwinArm64 = pkgs.callPackage ./codesigning.nix {
    inherit version url sha256 sourceDateEpoch;
    host = "arm64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinArm64;
    unsignedTarball = tarballDarwinArm64;
    expectedSha256 = "7d29c298421461dd843e5326d652464e0f11f376112972a42f0c42cb03aba624";
  };
  signedDarwinX86 = pkgs.callPackage ./signed.nix {
    inherit version sourceDateEpoch signapple detachedSigs;
    host = "x86_64-apple-darwin";
    arch = "x86_64";
    codesigningTarball = codesigningDarwinX86;
    expectedTarballSha256 = "9e12bb6abf800b210cab2ff356a76ace787661bf6fc438726520d174b527aae8";
    expectedZipSha256 = "c4186905f172a6b3bc21afa8d8e8e97c2f75578fc023a50d5091f80aef14a816";
  };
  signedDarwinArm64 = pkgs.callPackage ./signed.nix {
    inherit version sourceDateEpoch signapple detachedSigs;
    host = "arm64-apple-darwin";
    arch = "arm64";
    codesigningTarball = codesigningDarwinArm64;
    expectedTarballSha256 = "eea402015458eb42f635614a098c61365d2a77a5d54f8ce4ff65225f642da67f";
    expectedZipSha256 = "afa1048477c0db2a34cf5889c6558f47dcfcd67dbbd0aee3703203a9e0980a58";
  };
in {
  inherit llvmPackages1914 clangDarwin lldDarwin llvmDarwin darwinSdk
    dependsDarwinX86 dependsDarwinArm64 bitcoindDarwinX86 bitcoindDarwinArm64
    tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
    signapple codesigningDarwinX86 codesigningDarwinArm64 signedDarwinX86 signedDarwinArm64;
}
