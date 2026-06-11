{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          drvs = import ./default.nix { inherit pkgs; };
        in {
          inherit (drvs) depends bitcoind tarball debugTarball dependsAarch64 bitcoindAarch64 tarballAarch64
            debugTarballAarch64 dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64
            crossGlibc231 crossGlibc231X86 crossGuixGccX86;
          default = drvs.bitcoind;
        });
    };
}
