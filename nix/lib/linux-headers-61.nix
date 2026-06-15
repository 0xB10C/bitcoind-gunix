{ pkgs, pkgsCross }:
pkgsCross.linuxHeaders.overrideAttrs (o: {
  version = "6.1.119";
  src = pkgs.fetchurl {
    url = "mirror://kernel/linux/kernel/v6.x/linux-6.1.119.tar.xz";
    hash = "sha256-rs2vOdCoRKgc5MZ9na/4l56Ti7aQ309nn7u0lP5CMng=";
  };
})
