{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # nixos-20.09 is the last NixOS release shipping glibc 2.31 — the same
    # glibc version used by Bitcoin Core's GUIX release builds. We pull
    # only glibc from here; everything else (gcc, build tools) comes from
    # the modern `nixpkgs` input.
    nixpkgs-glibc231.url = "github:NixOS/nixpkgs/nixos-20.09";
    nixpkgs-glibc231.flake = false;
  };

  outputs = { self, nixpkgs, nixpkgs-glibc231 }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pkgsGlibc231 = import nixpkgs-glibc231 { inherit system; };
      # Rebuild glibc 2.31 with the same configure flags GUIX uses (see
      # contrib/guix/manifest.scm `define-public glibc-2.31`):
      #
      #   --enable-stack-protector=all
      #   --enable-cet
      #   --enable-bind-now
      #   --disable-werror
      #   --disable-timezone-tools
      #   --disable-profile
      #
      # Adding --enable-cet is what populates the resulting CRT objects
      # (Scrt1.o, crt[in].o) with the CET property notes, which the
      # linker then propagates into the final bitcoind as the
      # .note.gnu.property section — currently absent in our binary.
      glibc231 = pkgsGlibc231.glibc.overrideAttrs (old: {
        configureFlags = (old.configureFlags or []) ++ [
          "--enable-stack-protector=all"
          "--enable-cet"
          "--enable-bind-now"
          "--disable-werror"
          "--disable-timezone-tools"
          "--disable-profile"
        ];
        # Drop nixpkgs' allow-kernel-2.6.32.patch — it hardcodes the
        # .note.ABI-tag to 2.6.32 regardless of --enable-kernel. We want
        # 3.2.0 (matching upstream's GUIX-built binary). The patch's
        # original purpose was wider runtime-compat for nixpkgs users,
        # which isn't a goal here.
        patches = builtins.filter
          (p: !(pkgs.lib.hasSuffix "allow-kernel-2.6.32.patch" (toString p)))
          (old.patches or []);
      });
      drvs = import ./default.nix {
        inherit pkgs;
        inherit glibc231;
      };
    in {
      packages.${system} = {
        inherit (drvs) depends bitcoind;
        default = drvs.bitcoind;
      };
    };
}
