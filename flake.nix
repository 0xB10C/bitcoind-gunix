{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # nixos-20.09 is the last NixOS release shipping glibc 2.31 — the same
    # glibc version used by Bitcoin Core's GUIX release builds. We pull
    # only glibc from here; everything else (gcc, build tools) comes from
    # the modern `nixpkgs` input.
    nixpkgs-glibc231.url = "github:NixOS/nixpkgs/nixos-20.09";
    nixpkgs-glibc231.flake = false;
  };

  outputs = { self, nixpkgs, nixpkgs-glibc231 }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pkgsGlibc231 = import nixpkgs-glibc231 { inherit system; };
      drvs = import ./default.nix {
        inherit pkgs;
        glibc231 = pkgsGlibc231.glibc;
      };
    in {
      packages.${system} = {
        inherit (drvs) depends bitcoind;
        default = drvs.bitcoind;
      };
    };
}
