{ pkgs ? import <nixpkgs> {} }:

let
  version = "25.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "sha256-XfZ89CyjuaDDjNr+xbu1F9pbWNJR8yyNKkdRH5vh68I=";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
