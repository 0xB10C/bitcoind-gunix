{ pkgs ? import <nixpkgs> {} }:

let
  version = "27.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "sha256-nB7mUdOxV7rMwziL4ouM87/O/NJJO5Q3Ja1gQMprFGs=";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
