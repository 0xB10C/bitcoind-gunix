{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  # All toolchain construction (the GUIX-exact toolchains for every target,
  # incl. glibc 2.31 / binutils 2.46 / gcc 14.3.0 with GUIX's configure
  # flags) lives in default.nix and nix/<target>/.
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
          lib = nixpkgs.lib;
        in
        # Everything default.nix defines, minus the handful of attrs that are
        # package SETS rather than derivations (pkgsCrossMingw,
        # llvmPackages1914 and the per-target <arch>Cross bundles) — a flake
        # `packages` attrset may only hold derivations, and three of those
        # bundles used to be listed here by hand. Deriving the list both
        # fixes that and stops it drifting out of sync with default.nix.
        lib.filterAttrs (_: lib.isDerivation) drvs // {
          # noncodesigned.SHA256SUMS over all 21 artifacts is the default
          # build target.
          default = drvs.noncodesignedSha256sums;
        });
    };
}
