{ pkgs, pkgsCross }:
pkgsCross.stdenv.cc.bintools.bintools.overrideAttrs (old: {
  version = "2.41";
  src = pkgs.fetchurl {
    url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
    sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
  };
  patches = [ ];
  configureFlags =
    (builtins.filter (f: f != "--with-system-zlib") (old.configureFlags or [ ]))
    ++ [ "--enable-compressed-debug-sections=all" ];
})
