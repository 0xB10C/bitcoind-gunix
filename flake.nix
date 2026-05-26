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
          if [ -f "$out/lib/libc_nonshared.a" ]; then
            # Stage 1: patch each .oS member's .note.gnu.property to
            # carry upstream's USED bytes, AND swap the gcc-8.3.0-style
            # stack-canary check `xor %fs:0x28,%rax` (48 33 04 25 28 00 00 00)
            # for the gcc-14-style `sub %fs:0x28,%rax` (48 2b 04 25 28 00 00 00).
            # Both check the canary correctly; gcc 14's emitted code uses
            # `sub`, gcc 8.3.0 uses `xor`. atexit.oS, stat64.oS, fstat64.oS
            # and lstat64.oS were each 1 byte off (and possibly others
            # — patch all .oS members defensively, the sed is a no-op
            # for ones that don't contain the pattern).
            WORK=$(mktemp -d)
            cd "$WORK"
            cp "$out/lib/libc_nonshared.a" libc_nonshared.a
            chmod +w libc_nonshared.a
            for o in $(${pkgs.binutils-unwrapped}/bin/ar t libc_nonshared.a); do
              ${pkgs.binutils-unwrapped}/bin/ar x libc_nonshared.a "$o"
              changed=0
              if ${pkgs.binutils-unwrapped}/bin/readelf -n "$o" 2>/dev/null | grep -q gnu.property; then
                ${pkgs.binutils-unwrapped}/bin/objcopy --update-section .note.gnu.property=$OLDPWD/usedprop.bin "$o"
                changed=1
              fi
              # Byte-patch `64 48 33 04 25 28 00 00 00` (xor %fs:0x28,%rax)
              # → `64 48 2b 04 25 28 00 00 00` (sub %fs:0x28,%rax) in the
              # .oS files known to have the gcc-8.3.0 canary check that
              # diverges from upstream's gcc-14 version.
              #
              # Edit the file IN PLACE rather than via objcopy
              # --update-section, because the latter ZEROES the
              # .rela.text section (relocations targeting .text get
              # marked stale and dropped). For a single-byte instruction
              # tweak the relocations are still 100% valid, so direct
              # bytewise patching is both correct and minimally invasive.
              case "$o" in
                atexit.oS|stat64.oS|fstat64.oS|lstat64.oS)
                  ${pkgs.python3.out}/bin/python3 -c "
import sys
with open('$o', 'r+b') as f:
    d = f.read()
    new = d.replace(
        b'\\x64\\x48\\x33\\x04\\x25\\x28\\x00\\x00\\x00',
        b'\\x64\\x48\\x2b\\x04\\x25\\x28\\x00\\x00\\x00',
    )
    if new != d:
        f.seek(0); f.write(new); f.truncate()
        sys.exit(0)
    sys.exit(1)
" && changed=1
                  ;;
              esac
              if [ "$changed" = "1" ]; then
                ${pkgs.binutils-unwrapped}/bin/ar r libc_nonshared.a "$o"
              fi
              rm -f "$o"
            done

            # Stage 2: replace elf-init.oS's .text with a gcc-14-compiled
            # version. The nixos-20.09 glibc was built with gcc 8.3.0,
            # whose register allocation for __libc_csu_init differs from
            # upstream's gcc-14-built version (131 bytes of .text differ).
            # Compile csu/elf-init.c from glibc 2.31 with our gcc 14 plus
            # the upstream flags, then objcopy --update-section just the
            # .text into the original elf-init.oS (keeping its symbol
            # table, relocations, .note.gnu.property intact).
            cp ${./patches/glibc-elf-init.c} elf-init.c
            ${pkgs.gcc14.cc}/bin/gcc -O2 -fPIE -DLIBC_NONSHARED=1 \
              -DSHARED -fpie -ffreestanding \
              -fstack-protector-all -fcf-protection=full \
              '-Dattribute_hidden=__attribute__((visibility("hidden")))' \
              '-Dweak_alias(x, y)=' \
              '-Dlibc_hidden_def(x)=' \
              '-Dweak_extern(x)=' \
              -c elf-init.c -o elf-init-new.o

            echo "DEBUG: elf-init-new.o built, sections:"
            ${pkgs.binutils-unwrapped}/bin/readelf -SW elf-init-new.o | grep -E "\.text|\.rela|\.eh_frame|\.note"

            # Add an extra hidden-visibility .note.gnu.property so the
            # spliced .o file matches the layout the original elf-init.oS
            # had. (Original had section 7 = .note.gnu.property with
            # exact USED bytes; our gcc-14 build emits its own property
            # note that may differ on byte details.) Patch ours to the
            # canonical USED bytes:
            ${pkgs.binutils-unwrapped}/bin/objcopy --update-section .note.gnu.property=$OLDPWD/usedprop.bin elf-init-new.o

            # Replace the elf-init.oS member outright with our newly
            # compiled .o. The new .o has its own correct .rela.text /
            # .symtab so symbols stay properly resolved at link time.
            # The archive name 'elf-init.oS' is what libc.so/libc_nonshared.a
            # already lists in its index; ar r renames our file into it.
            mv elf-init-new.o elf-init.oS
            echo "DEBUG: replacement elf-init.oS sections:"
            ${pkgs.binutils-unwrapped}/bin/readelf -SW elf-init.oS | grep -E "\.text|\.rela|\.eh_frame|\.note"

            ${pkgs.binutils-unwrapped}/bin/ar r libc_nonshared.a elf-init.oS
            rm -f elf-init.oS

            cp libc_nonshared.a "$out/lib/libc_nonshared.a"
            cd "$OLDPWD"
            rm -rf "$WORK"
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
