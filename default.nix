{ pkgs ? import <nixpkgs> {} }:

let
  version = "ec5d1c372b20d49147813aa0392195a3642b86a1";
  url = "https://github.com/bitcoin/bitcoin/archive/${version}.tar.gz";
  sha256 = "sha256-TFtRwFmLK1Q7HrSJa4StLASNgd37cbxqz2HTzqojvtY=";

  depends = pkgs.callPackage ./depends.nix { inherit version url sha256; };
  bitcoind = pkgs.callPackage ./bitcoind.nix { inherit url sha256 depends; };
in {
  depends = depends;
  bitcoind = bitcoind;
}
