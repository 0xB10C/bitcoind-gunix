{ pkgs, pkgsCross }:
# GUIX's base-binutils (contrib/guix/manifest_build.scm): a FRESH
# binutils-2.46.0 origin (so no patches — neither guix's 2.44 ones nor
# nixpkgs'), guix's stock binutils configure flags (compressed debug
# sections, deterministic archives, bundled zlib) + --enable-gprofng=no.
# nixpkgs' own 2.46 is the binutils-with-gold tarball with 8 patches and
# --with-system-zlib/--enable-gold, so it is overridden back to vanilla.
pkgsCross.stdenv.cc.bintools.bintools.overrideAttrs (old: {
  version = "2.46.0";
  src = pkgs.fetchurl {
    url = "mirror://gnu/binutils/binutils-2.46.0.tar.bz2";
    hash = "sha256-DzFSYyoqnOBm8glj6btAr3z4W5tsQJ7Ykv0GduhOzRI=";
  };
  patches = [ ];
  # nixpkgs' recipe targets the binutils-with-gold tarball and seds
  # gold/Makefile.in in preConfigure; the plain tarball has no gold/.
  preConfigure = builtins.replaceStrings [ " gold/Makefile.in" ] [ "" ] (old.preConfigure or "");
  passthru = (old.passthru or { }) // { hasGold = false; };
  configureFlags =
    (builtins.filter (f: f != "--with-system-zlib" && f != "--enable-gold")
      (old.configureFlags or [ ]))
    ++ [ "--enable-compressed-debug-sections=all" ];
})
