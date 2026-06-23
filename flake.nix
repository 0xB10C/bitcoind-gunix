{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # nixos-24.05 still ships gcc11 (= 11.4.0), which 26.05 removed. Used
    # ONLY to build the gcc 11.4.0 mingw cross for the NSIS 3.10 installer
    # stubs — GUIX compiles those with its default cross-gcc (= gcc-11 =
    # 11.4.0), not the bitcoin base-gcc 14.3.0. 24.05's mingw cross binutils
    # is already 2.41 (GUIX's), so only mingw-w64 needs pinning to 12.0.0.
    nixpkgs2405.url = "github:NixOS/nixpkgs/nixos-24.05";
  };

  # All toolchain construction (the GUIX-exact cross toolchains for
  # x86_64-linux-gnu and aarch64-linux-gnu, incl. glibc 2.31 / binutils
  # 2.41 / gcc 14.3.0 with GUIX's configure flags) lives in default.nix.
  #
  # "Cross everywhere": the same pipeline is exposed for every supported
  # BUILD host; package attr names refer to the TARGET. So
  # packages.x86_64-linux.bitcoind is the x86_64 release built
  # cross-to-self on x86_64, and packages.aarch64-linux.bitcoind is the
  # same x86_64 release cross-compiled on an aarch64 host — every
  # derivation gates the same upstream hashes, so a successful build on
  # ANY host proves byte-identity. (x86_64-hosted builds are the ones
  # routinely exercised; aarch64-hosted builds re-assert the same gates.)
  outputs = { nixpkgs, nixpkgs2405, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          pkgs2405 = import nixpkgs2405 { inherit system; };
          drvs = import ./default.nix { inherit pkgs pkgs2405; };
        in {
          inherit (drvs) depends bitcoind tarball debugTarball dependsAarch64 bitcoindAarch64 tarballAarch64
            debugTarballAarch64 dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64
            dependsArmhf bitcoindArmhf tarballArmhf debugTarballArmhf
            dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64
            riscv64Cross armhfCross ppc64Cross
            crossGlibc231 crossGlibc231X86 crossGuixGccX86
            clangDarwin lldDarwin llvmDarwin darwinSdk
            dependsDarwinX86 dependsDarwinArm64 bitcoindDarwinX86 bitcoindDarwinArm64
            tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
            signapple
            mingwGuixGcc mingwGuixGccNoFp mingwBinutils241 dependsMingw
            mingwCrtStdenv mingwCrt
            bitcoindMingw bitcoindMingwNoGate unsignedZipMingw debugZipMingw
            nsisGcc11 nsis310 setupExeMingw
            pkgsCrossMingwNsis nsisCrtBootSet nsisCrtStdenv;
          default = drvs.bitcoind;
        });
    };
}
