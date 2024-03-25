{ pkgs ? import <nixpkgs> {} }:

let
  version = "a2ba8f3366663a9f449c5bd9ce765ecfdd7a20bf";
  url = "https://github.com/hebasto/bitcoin/archive/${version}.tar.gz";
  sha256 = "sha256-+Fci8ksyIt/gfGsuNwdCPbhI1VivVAa1cbU1o1/WR4Y=";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
