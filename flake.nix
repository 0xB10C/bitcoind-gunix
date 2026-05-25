{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # nixos-20.09 ships glibc 2.31 — the version GUIX uses.
    nixpkgs-glibc231.url = "github:NixOS/nixpkgs/nixos-20.09";
    nixpkgs-glibc231.flake = false;
  };

  outputs = { self, nixpkgs, nixpkgs-glibc231 }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      pkgsGlibc231 = import nixpkgs-glibc231 { inherit system; };

      # Rebuild glibc 2.31 with GUIX's configureFlags from
      # contrib/guix/manifest.scm `define-public glibc-2.31`.
      glibc231 = pkgsGlibc231.glibc.overrideAttrs (old: {
        configureFlags = (old.configureFlags or []) ++ [
          "--enable-stack-protector=all"
          "--enable-cet"
          "--enable-bind-now"
          "--disable-werror"
          "--disable-timezone-tools"
          "--disable-profile"
        ];
        # Drop nixpkgs' allow-kernel-2.6.32.patch — it hardcodes
        # .note.ABI-tag to 2.6.32 regardless of --enable-kernel.
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
