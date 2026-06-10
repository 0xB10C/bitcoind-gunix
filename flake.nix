{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  # All toolchain construction (the GUIX-exact cross toolchains for
  # x86_64-linux-gnu — cross-to-self — and aarch64-linux-gnu, incl. glibc
  # 2.31 / binutils 2.41 / gcc 14.3.0 with GUIX's configure flags) lives in
  # default.nix. The former flake-level native glibc231 override was removed
  # 2026-06-10 together with the native toolchain it served, when the
  # cross-to-self build became the canonical x86_64 path (it reproduces the
  # same 10 binaries + tarball).
  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      drvs = import ./default.nix { inherit pkgs; };
    in {
      packages.${system} = {
        inherit (drvs) depends bitcoind tarball dependsAarch64 bitcoindAarch64 tarballAarch64
          crossGlibc231 crossGlibc231X86 crossGuixGccX86;
        default = drvs.bitcoind;
      };
    };
}
