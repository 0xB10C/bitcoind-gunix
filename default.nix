{ pkgs ? import <nixpkgs> {} }:

let
  version = "5170ec1ae35d67923c5a4245cb4456aa2dd97385";
  url = "https://github.com/bitcoin/bitcoin/archive/${version}.tar.gz";
  sha256 = "sha256-fA1qL7OLafqK1fruve9mZYgAASoEvZe9hPCdf9Mx3eE";

  depends = pkgs.callPackage ./depends.nix {
                inherit version url sha256;
                stdenv = pkgs.gcc13Stdenv;
        };
  bitcoind = pkgs.callPackage ./bitcoind.nix {
                inherit url sha256 depends;
                stdenv = pkgs.gcc13Stdenv;
        };
in {
  depends = depends;
  bitcoind = bitcoind;
}
