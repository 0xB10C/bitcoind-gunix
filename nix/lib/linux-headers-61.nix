{ pkgs, pkgsCross }:
# GUIX's linux-libre-headers-6.1 at the guix pin in contrib/guix/libexec/
# prelude.bash (c5eee3336cc1: 6.1.166). The header version leaks into the
# .dbg (enumerator DIEs), so it must track the pin.
pkgsCross.linuxHeaders.overrideAttrs (o: {
  version = "6.1.166";
  src = pkgs.fetchurl {
    url = "mirror://kernel/linux/kernel/v6.x/linux-6.1.166.tar.xz";
    hash = "sha256-gY38dCFY0Y9wpqvM13t+Q2bLfyaohof5Ta45Kp8IlEk=";
  };
})
