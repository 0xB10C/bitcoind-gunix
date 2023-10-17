{ pkgs ? import <nixpkgs> {} }:

let
  version = "5e65a38896525cdb84f25e0968cc230e147cfc9b";
  url = "https://github.com/hebasto/bitcoin/archive/${version}.tar.gz";
  sha256 = "sha256-rKfPjUTmyVIJ2Sy8aETA12eXkzcGDy/Rbrj10rNeNj8=";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
