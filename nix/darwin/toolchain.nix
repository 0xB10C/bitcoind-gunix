{ pkgs, version, src, buildSystem, sourceDateEpoch, detachedSigs, upstreamSha256 }:

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
  # v32.x branch-off: the guix pin (c5eee3336cc1) moved llvm-19 to 19.1.7
  # (clang/lld/libcxx; the build tree's CMakeCache records clang 19.1.7),
  # which is exactly nixpkgs-26.05's llvmPackages_19 — so the 19.1.4
  # overlay pin described above is gone. Attr names kept for compatibility.
  llvmPackages1914 = pkgs.llvmPackages_19;
  # nixpkgs moves clang's builtin headers (stdarg.h etc.) into the
  # separate `lib` output and normally reglues them via the cc-wrapper's
  # -resource-dir — which we don't use. clang locates its resource dir
  # relative to the REALPATH of the executable, so symlinking the
  # binaries wouldn't work either: reunite real copies of bin/ with a
  # complete lib/clang/19 in one GUIX-shaped store path.
  clangDarwin = pkgs.runCommand "clang-guix-19.1.7" {} ''
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
  # TWO depends trees per host, like upstream's two build passes:
  # build_macos.sh builds depends with NO_QT=1 under BASE_CACHE
  # .../GUIX/BUILD, build_macos_gui.sh the full tree under .../GUIX/GUI.
  dependsNoQtDarwinX86 = pkgs.callPackage ../lib/depends.nix {
    inherit version src darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "x86_64-apple-darwin";
    buildQt = false;
    crossInputs = darwinCrossInputs;
  };
  dependsNoQtDarwinArm64 = pkgs.callPackage ../lib/depends.nix {
    inherit version src darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "arm64-apple-darwin";
    buildQt = false;
    crossInputs = darwinCrossInputs;
  };
  dependsDarwinX86 = pkgs.callPackage ../lib/depends.nix {
    inherit version src darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "x86_64-apple-darwin";
    buildQt = true;
    crossInputs = darwinCrossInputs;
  };
  dependsDarwinArm64 = pkgs.callPackage ../lib/depends.nix {
    inherit version src darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "arm64-apple-darwin";
    buildQt = true;
    crossInputs = darwinCrossInputs;
  };

  # The 10 Mach-O binaries of each darwin release plus that host's three
  # published artifacts, built in upstream's two passes and packaged by its
  # own package.sh, all inside one chroot (see release.nix). No per-binary
  # gate: upstream publishes no per-binary hashes; the release prints them.
  # gate; the release build prints the hashes instead.
  bitcoindDarwinX86 = pkgs.callPackage ./release.nix {
    inherit version src sourceDateEpoch;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinX86;
    dependsNoQt = dependsNoQtDarwinX86;
    crossInputs = darwinCrossInputs;
    hostTriple = "x86_64-apple-darwin";
    pname = "bitcoind-darwin-x86_64";
  };
  bitcoindDarwinArm64 = pkgs.callPackage ./release.nix {
    inherit version src sourceDateEpoch;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinArm64;
    dependsNoQt = dependsNoQtDarwinArm64;
    crossInputs = darwinCrossInputs;
    hostTriple = "arm64-apple-darwin";
    pname = "bitcoind-darwin-arm64";
  };
  # The published darwin artifacts all come out of the `dist` output of the
  # release derivations: package.sh runs INSIDE them (its `deploy` target
  # needs the GUI pass's cmake build tree), so these are thin selections
  # plus the byte-match gate — see nix/lib/artifact.nix.
  mkArtifactDarwin = { bitcoindDarwin, file }:
    pkgs.callPackage ../lib/artifact.nix { } {
      packaged = bitcoindDarwin.dist;
      inherit file;
      expectedSha256 = upstreamSha256 file;
    };
  tarballDarwinX86 = mkArtifactDarwin {
    bitcoindDarwin = bitcoindDarwinX86;
    file = "bitcoin-${version}-x86_64-apple-darwin-unsigned.tar.gz";
  };
  tarballDarwinArm64 = mkArtifactDarwin {
    bitcoindDarwin = bitcoindDarwinArm64;
    file = "bitcoin-${version}-arm64-apple-darwin-unsigned.tar.gz";
  };
  zipDarwinX86 = mkArtifactDarwin {
    bitcoindDarwin = bitcoindDarwinX86;
    file = "bitcoin-${version}-x86_64-apple-darwin-unsigned.zip";
  };
  zipDarwinArm64 = mkArtifactDarwin {
    bitcoindDarwin = bitcoindDarwinArm64;
    file = "bitcoin-${version}-arm64-apple-darwin-unsigned.zip";
  };
  codesigningDarwinX86 = mkArtifactDarwin {
    bitcoindDarwin = bitcoindDarwinX86;
    file = "bitcoin-${version}-x86_64-apple-darwin-codesigning.tar.gz";
  };
  codesigningDarwinArm64 = mkArtifactDarwin {
    bitcoindDarwin = bitcoindDarwinArm64;
    file = "bitcoin-${version}-arm64-apple-darwin-codesigning.tar.gz";
  };

  # --- darwin signed artifacts -------------------------------------------
  # signapple (+ its elfesteem) pinned to GUIX's manifest, plus the release
  # detached signatures, reproduce the SIGNED .tar.gz/.zip. Only wired up
  # when detachedSigs is non-null (see default.nix).
  signapple = pkgs.callPackage ./signapple.nix { };
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
    dependsDarwinX86 dependsDarwinArm64 dependsNoQtDarwinX86 dependsNoQtDarwinArm64
    bitcoindDarwinX86 bitcoindDarwinArm64
    tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
    signapple codesigningDarwinX86 codesigningDarwinArm64;
} // pkgs.lib.optionalAttrs (detachedSigs != null) {
  # Only wired up when there are detached signatures to apply — see the
  # detachedSigs note in default.nix.
  inherit signedDarwinX86 signedDarwinArm64;
}
