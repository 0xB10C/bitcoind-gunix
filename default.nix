{ pkgs ? import <nixpkgs> {} }:

let
  version = "26.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "sha256-qx2ZJ24o22LR2fOQHoWsNY1/Hry5QtNIqcTkbw/NwKE=";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
