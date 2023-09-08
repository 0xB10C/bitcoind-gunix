{ pkgs ? import <nixpkgs> {} }:

let
  version = "24.1";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "8a0a3db3b2d9cc024e897113f70a3a65d8de831c129eb6d1e26ffa65e7bfaf4e";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
