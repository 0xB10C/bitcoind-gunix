{ pkgs, version, url, sha256, buildSystem, detachedSigs }:

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
  # from the published -unsigned.tar.gz (whose archive sha256 is in the
  # upstream SHA256SUMS: 48d34a14… arm64 / d1d0174f… x86_64).
  bitcoindDarwinX86 = pkgs.callPackage ./release.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinX86;
    crossInputs = darwinCrossInputs;
    hostTriple = "x86_64-apple-darwin";
    pname = "bitcoind-darwin-x86_64";
    expectedHashes = {
      "bin/bitcoin" = "ff8e302989b143052aba65b5028cd746a413e99b75e0e2a7d8e3f467b5ef0ce3";
      "bin/bitcoin-cli" = "9e157c6bddcecb468494ca4891c0db7d1b05ccc62d647a25459bdf170e570b6f";
      "bin/bitcoind" = "dd95faf2edf77dc7dd6928c0e41c14e6bb630b8872778c99bb51fa5f2e68d477";
      "bin/bitcoin-qt" = "ab17cfd634f0c11144e41bb6a3a39386f31bca3736f0b3ba17367f455147727a";
      "bin/bitcoin-tx" = "5fbd09c750b133622ee687ac499f59a9ab265dc9a243bba8c58d4e10a1cb8789";
      "bin/bitcoin-util" = "c4a4530c14a47884ea40df3a89688fe3c996a8bd81585f20c570ac2b918f943e";
      "bin/bitcoin-wallet" = "faec8f64d555bae9482d73de0c78b452abc484bfde8c627cc7ffa22350696c1d";
      "libexec/bitcoin-gui" = "0f6e5f2f30d5cc74088bb078f50dc2e8cc5277bbc7d64f19fb1a1e2eef229c8a";
      "libexec/bitcoin-node" = "80f7b8184d420b9c8a4c4cf9211248dfb5aa571ee1d5b4a1b7cd2aed9186c972";
      "libexec/test_bitcoin" = "4f6a85f2ae6b2c5e405865d184cc8c4a2090ef2308c9339e7c7ee2ba162c5d5a";
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
      "bin/bitcoin" = "b3d77e88f98c6f26722175c4f4c927088ae29d467f548340d9803bad8b76f12c";
      "bin/bitcoin-cli" = "8669044ee26f3c902153f5cdb9cdc0d95d3ba82e6127974bff8abdeae665aa15";
      "bin/bitcoind" = "2c6b7529c343e7c3bc37d24a2e05ad861fdb7459d6d897357c39d548d4b05d82";
      "bin/bitcoin-qt" = "984a018e5810ca9e5ef3d5e224c6b827ad0554e28d1cfa8c28fdbe1e9fa30ec7";
      "bin/bitcoin-tx" = "1abf9b518e2720fc27d26cc1fda0ff9ebb9d1b8630fe6551ee6f45412ebbaffa";
      "bin/bitcoin-util" = "859f489d2cbc265d5642003eebd36de8a47e0f28e00b436f00ab1f8f5fc0c470";
      "bin/bitcoin-wallet" = "09a7793db030bd3a286dadca6bc045c0cf10b3727ed8ce7a2b6239eefb6c857b";
      "libexec/bitcoin-gui" = "12d7e9299110f2c24293397c99c6a41a896d37a0482574a63690a8b2adc3f038";
      "libexec/bitcoin-node" = "194c86c913566b6288cd6754cc9840df6f9fa4f909ce62004fd52b63cd8b2364";
      "libexec/test_bitcoin" = "0b12e79748f53540606d5eb7915d99731ac824dd0c015121790f16863093ae6c";
    };
  };
  # The published darwin -unsigned artifacts. The -unsigned.tar.gz is
  # assembled like the linux release archives (build.sh darwin case: no
  # README.md, no .dbg); the -unsigned.zip IS the deploy target's
  # bitcoin-macos-app.zip under its release name (build.sh just mv's it).
  tarballDarwinX86 = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindDarwinX86;
    arch = "x86_64-apple-darwin";
    darwinUnsigned = true;
    expectedSha256 = "d1d0174f07cf87d9af4318f7072350510fa0f1bf8d3d3b1ee7143ad5967b6bdf";
  };
  tarballDarwinArm64 = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    darwinUnsigned = true;
    expectedSha256 = "48d34a140aeaacd63a4bd37c24ed1876df4b077c98a7e0dd9a4483d1032839f4";
  };
  mkDarwinUnsignedZip = { bitcoindDarwin, arch, expectedSha256 }:
    pkgs.runCommandLocal "bitcoin-${version}-${arch}-unsigned.zip" {} ''
      cp ${bitcoindDarwin.dist}/bitcoin-macos-app.zip "$out"
      actual=$(sha256sum "$out" | cut -d' ' -f1)
      if [ "$actual" != "${expectedSha256}" ]; then
        echo "FAIL: unsigned zip sha256 does not match upstream GUIX v31.0 release"
        echo "  expected: ${expectedSha256}"
        echo "  actual:   $actual"
        exit 1
      fi
      echo "OK: bitcoin-${version}-${arch}-unsigned.zip matches upstream ($actual)"
    '';
  zipDarwinX86 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinX86;
    arch = "x86_64-apple-darwin";
    expectedSha256 = "b8d9b9915a1871ee12a3a9883fd47860028454fcd192864735f2e0d3a88b4735";
  };
  zipDarwinArm64 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    expectedSha256 = "b639946d343114cca5d87b218aaece04d0d111374b725d90dffc7e2d1d3b99f5";
  };

  # --- darwin signed artifacts -------------------------------------------
  # signapple (+ its elfesteem) pinned to GUIX's manifest, and the v31.0
  # detached signatures. These reproduce the -codesigning.tar.gz and the
  # SIGNED .tar.gz/.zip (the UUID-patched unsigned binaries are already
  # upstream-identical, so applying upstream's detached sigs reproduces the
  # signed bytes).
  signapple = pkgs.callPackage ./signapple.nix { };
  codesigningDarwinX86 = pkgs.callPackage ./codesigning.nix {
    inherit version url sha256;
    host = "x86_64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinX86;
    unsignedTarball = tarballDarwinX86;
    expectedSha256 = "fccf54f31bd58a3f834add05fa5df36520313d936445c556be8f71ccf314b658";
  };
  codesigningDarwinArm64 = pkgs.callPackage ./codesigning.nix {
    inherit version url sha256;
    host = "arm64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinArm64;
    unsignedTarball = tarballDarwinArm64;
    expectedSha256 = "955563c720b4d5fc22a11d4b102940d605f1cb9eb0b564f50deb606412c631e5";
  };
  signedDarwinX86 = pkgs.callPackage ./signed.nix {
    inherit version signapple detachedSigs;
    host = "x86_64-apple-darwin";
    arch = "x86_64";
    codesigningTarball = codesigningDarwinX86;
    expectedTarballSha256 = "56824dd705bc2a3b22d42e8aa02ed53498d491ff7c2c8aa96831333871887ead";
    expectedZipSha256 = "8e230f36a2020072763adf742b20d95348cb20aaa0b0a918ca44ecdc83ac4efd";
  };
  signedDarwinArm64 = pkgs.callPackage ./signed.nix {
    inherit version signapple detachedSigs;
    host = "arm64-apple-darwin";
    arch = "arm64";
    codesigningTarball = codesigningDarwinArm64;
    expectedTarballSha256 = "a2d7a13b4da53d4a3e4c517f3a0269e2429813417bb320d3b268993cfdc545d0";
    expectedZipSha256 = "fc119a34915daac57e5fbdf181c9295d862d6843d52a9380e39dc0d0ac69cf20";
  };
in {
  inherit llvmPackages1914 clangDarwin lldDarwin llvmDarwin darwinSdk
    dependsDarwinX86 dependsDarwinArm64 bitcoindDarwinX86 bitcoindDarwinArm64
    tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
    signapple codesigningDarwinX86 codesigningDarwinArm64 signedDarwinX86 signedDarwinArm64;
}
