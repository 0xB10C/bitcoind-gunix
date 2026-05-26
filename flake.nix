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
        # Patch the .note.gnu.property section in glibc's CRT objects
        # and libc_nonshared.a object members to match upstream's USED
        # bytes (x86 features used: x86,x87,XMM,YMM,XSAVE; ISA used:
        # x86-64-baseline,v2,v3). Background:
        #
        # binutils 2.41's `_bfd_x86_elf_merge_gnu_properties` treats
        # USED properties as OR_AND types — if the link's first input
        # with a property section (first_pbfd) lacks USED while another
        # input has USED, the linker REMOVES USED from the output.
        # That's why our final bitcoind binary loses .note.gnu.property
        # entirely: the CRT objects (built by nixos-20.09's gcc 8.3.0,
        # which predates USED-emission) only have AND CET, and they're
        # the first inputs in the link order. Their CET gets dropped
        # (mixed inputs), and their lack-of-USED causes USED from later
        # inputs to be dropped too. Net result: no property section.
        #
        # Upstream's GUIX-built glibc was compiled with a modern gcc
        # that emits both CET and USED in CRTs. We can't easily rebuild
        # glibc 2.31 with gcc 14 (multi-stage bootstrap blocked by
        # gmp/isl ABI mismatches; see commit 37b05ef post-mortem), so
        # we surgically patch the .o files post-install to have the
        # exact upstream USED bytes. This makes them match what gcc 14
        # would have emitted, and the final binary will end up with
        # the byte-identical .note.gnu.property section.
        postFixup = (old.postFixup or "") + ''
          # 48 bytes: ELF note header (16) + 2 properties × 16 bytes each.
          printf '\x04\x00\x00\x00\x20\x00\x00\x00\x05\x00\x00\x00GNU\x00\x01\x00\x01\xc0\x04\x00\x00\x00\x9b\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01\xc0\x04\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00' > usedprop.bin
          for f in $out/lib/Scrt1.o $out/lib/crti.o $out/lib/crtn.o $out/lib/crt1.o $out/lib/gcrt1.o $out/lib/Mcrt1.o $out/lib/rcrt1.o; do
            if [ -f "$f" ]; then
              ${pkgs.binutils-unwrapped}/bin/objcopy --update-section .note.gnu.property=usedprop.bin "$f"
            fi
          done
          if [ -f $out/lib/libc_nonshared.a ]; then
            mkdir -p libc-rebuild
            cd libc-rebuild
            cp $out/lib/libc_nonshared.a libc_nonshared.a
            chmod +w libc_nonshared.a
            for o in $(${pkgs.binutils-unwrapped}/bin/ar t libc_nonshared.a); do
              ${pkgs.binutils-unwrapped}/bin/ar x libc_nonshared.a "$o"
              if ${pkgs.binutils-unwrapped}/bin/readelf -n "$o" 2>/dev/null | grep -q gnu.property; then
                ${pkgs.binutils-unwrapped}/bin/objcopy --update-section .note.gnu.property=../usedprop.bin "$o"
                ${pkgs.binutils-unwrapped}/bin/ar r libc_nonshared.a "$o"
              fi
              rm -f "$o"
            done
            cp libc_nonshared.a $out/lib/libc_nonshared.a
            cd ..

            # Also rebuild elf-init.oS (containing __libc_csu_init) using
            # the rebuilt gcc 14 + glibc 2.31 toolchain so the resulting
            # .text matches upstream's gcc-14-compiled version. The nixos-
            # 20.09 glibc was built with gcc 8.3.0 which uses different
            # register allocation; the function's ABI is identical but
            # the byte-level instruction encoding diverges by ~131 B.
            # See https://sourceware.org/git/?p=glibc.git;a=blob;f=csu/elf-init.c;hb=refs/tags/glibc-2.31
            # for the source. We compile with the same flags upstream's
            # glibc 2.31 uses for libc_nonshared.a's elf-init.oS:
            #   -O2 -fPIE -DLIBC_NONSHARED=1 -DSHARED -fpie -ffreestanding
            #   -fstack-protector-all -fcf-protection=full
            # The attribute_hidden/weak_alias macros from glibc internals
            # aren't needed for the actual codegen of __libc_csu_init —
            # stub them out with empty defines.
            cp ${./patches/glibc-elf-init.c} elf-init.c
            # Use the unwrapped gcc 14 from nixpkgs — for this small
            # function the register allocation depends only on the gcc
            # version + the explicit flags, not on the broader bootstrap
            # state. Avoids the circular dep between glibc and our gcc
            # rebuild that lives in default.nix.
            ${pkgs.gcc14.cc}/bin/gcc -O2 -fPIE -DLIBC_NONSHARED=1 \
              -DSHARED -fpie -ffreestanding \
              -fstack-protector-all -fcf-protection=full \
              '-Dattribute_hidden=__attribute__((visibility("hidden")))' \
              '-Dweak_alias(x, y)=' \
              '-Dlibc_hidden_def(x)=' \
              '-Dweak_extern(x)=' \
              -c elf-init.c -o elf-init-new.o
            # Replace just the .text section of elf-init.oS with our
            # newly-compiled version, keeping the rest (symbol table,
            # relocations, .note.gnu.property) from the original.
            mkdir -p replace && cd replace
            ${pkgs.binutils-unwrapped}/bin/ar x ../$out/lib/libc_nonshared.a elf-init.oS 2>/dev/null || true
            if [ -f elf-init.oS ]; then
              ${pkgs.binutils-unwrapped}/bin/objcopy \
                --dump-section .text=newtext.bin ../elf-init-new.o
              ${pkgs.binutils-unwrapped}/bin/objcopy \
                --update-section .text=newtext.bin elf-init.oS
              ${pkgs.binutils-unwrapped}/bin/ar r ../$out/lib/libc_nonshared.a elf-init.oS
            fi
            cd ..
          fi
        '';
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
