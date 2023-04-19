{ pkgs ? import <nixpkgs> {} }:

let
  version = "24.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "9cfa4a9f4acb5093e85b8b528392f0f05067f3f8fafacd4dcfe8a396158fd9f4";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
