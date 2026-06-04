{
  description = "bitcoind-gunix: reproduce GUIX bitcoind binary in Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      # Build glibc 2.31 with nixpkgs-25.11's stdenv, which uses gcc 14.3.0
      # — the *same* compiler version GUIX uses for its release toolchain.
      # We take 25.11's modern glibc derivation and override it down to
      # 2.31, fetching the exact source GUIX uses
      # (contrib/guix/manifest.scm `define-public glibc-2.31`: the 2.31
      # stable branch at commit 7b27c450). Building the CRTs and
      # libc_nonshared.a objects with gcc 14 — rather than nixos-20.09's
      # gcc 8.3.0 — makes them carry the right .note.gnu.property USED
      # bytes, the gcc-14 `sub %fs:0x28,%rax` canary check, and the
      # gcc-14 __libc_csu_init register allocation natively, so no
      # post-install byte patching is needed.
      #
      # GUIX's glibc-2.31 configure flags (same manifest):
      #   --enable-stack-protector=all --enable-cet --enable-bind-now
      #   --disable-werror --disable-timezone-tools --disable-profile
      glibc231 = pkgs.glibc.overrideAttrs (old: {
        version = "2.31";
        src = pkgs.fetchgit {
          # Name the checkout glibc-2.31 so the unpacked sourceRoot matches
          # the `../glibc-2*/localedata/SUPPORTED` glob in the postInstall.
          name = "glibc-2.31";
          url = "https://sourceware.org/git/glibc.git";
          rev = "7b27c450c34563a28e634cccb399cd415e71ebfe";
          hash = "sha256-wIq9cIHkI8HtsYa5UU1IfC8VIhXyz0vJau20WPJt+AQ=";
        };
        # 25.11's patches target glibc 2.40; none apply to 2.31. GUIX's
        # two glibc patches (guix-prefix, riscv-jumptarget) are irrelevant
        # on x86_64, matching the empty set used for the release binary.
        patches = [ ];
        # Drop the 25.11 configure flags that diverge from GUIX, then add
        # GUIX's. Most important: --enable-kernel=3.10.0 sets the
        # .note.ABI-tag to 3.10.0, but upstream's binary is 3.2.0 (glibc
        # 2.31's default arch_minimum_kernel — GUIX doesn't set
        # --enable-kernel). Also drop 25.11's stack-protector=strong /
        # cet=permissive / fortify-source so they don't fight the GUIX
        # values (and fortify-source isn't applied by GUIX at all).
        configureFlags =
          (builtins.filter
            (f: !(pkgs.lib.hasPrefix "--enable-kernel" f
              || f == "--enable-stack-protector=strong"
              || f == "--enable-cet=permissive"
              || f == "--enable-fortify-source"))
            (old.configureFlags or [ ]))
          ++ [
            "--enable-stack-protector=all"
            "--enable-cet"
            "--enable-bind-now"
            "--disable-werror"
            "--disable-timezone-tools"
            "--disable-profile"
          ];
        # nixpkgs' gcc-wrapper injects -fno-omit-frame-pointer, which adds
        # a frame-pointer prologue to glibc's csu objects (notably
        # __libc_csu_init in elf-init.oS). Upstream omits the frame pointer
        # at -O2. Append the omit flags so they win over the wrapper's
        # cc-cflags-before. (25.11 glibc uses a structured `env`.)
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = "-fomit-frame-pointer -momit-leaf-frame-pointer";
        };
        # GUIX's toolchain applies none of nixpkgs' compile hardenings.
        # The decisive one here is zerocallusedregs (-fzero-call-used-regs):
        # it appends register-zeroing xors before `ret` in glibc's
        # nonshared members (__libc_csu_init, the stat wrappers), which
        # upstream lacks. Disable the same set bitcoind does. Stack canaries
        # are unaffected — they come from glibc's own
        # --enable-stack-protector=all, not nixpkgs' stackprotector flag.
        hardeningDisable = [
          "zerocallusedregs" "strictoverflow" "stackprotector"
          "stackclashprotection" "fortify" "fortify3"
        ];
        # 25.11's postPatch seds nss/nss_files_fopen.c and
        # include/nss_files.h, which don't exist in 2.31. Keep only the
        # two 2.31-safe substitutions.
        postPatch = ''
          sed -i 's/ot \$/ot:\n\ttouch $@\n$/' manual/Makefile
          echo "LDFLAGS-nscd += -static-libgcc" >> nscd/Makefile
        '';
        # 25.11's postInstall generates the C.UTF-8 locale, but glibc 2.31
        # ships no locales/C definition (C.UTF-8 landed in 2.35).
        # Reconstruct the output-splitting steps without locale generation.
        postInstall = ''
          moveToOutput bin/getent $getent

          test -f $out/etc/ld.so.cache && rm $out/etc/ld.so.cache

          if test -n "$linuxHeaders"; then
              (cd $dev/include && \
               ln -sv $(ls -d $linuxHeaders/include/* | grep -v scsi\$) .)
          fi

          if test -n "$is64bit"; then
              ln -s lib $out/lib64
          fi

          rm -rf $out/var $bin/bin/sln

          ln -sf $out/lib/libpthread.so.0 $out/lib/libpthread.so
          ln -sf $out/lib/librt.so.1 $out/lib/librt.so
          ln -sf $out/lib/libdl.so.2 $out/lib/libdl.so
          test -f $out/lib/libutil.so.1 && ln -sf $out/lib/libutil.so.1 $out/lib/libutil.so
          touch $out/lib/libpthread.a

          mkdir -p $static/lib
          mv $out/lib/*.a $static/lib
          mv $static/lib/lib*_nonshared.a $out/lib
          test -f $out/lib/libutil.so.1 || mv $static/lib/libutil.a $out/lib
          sed "/^GROUP/s|$out/lib/lib|$static/lib/lib|g" \
            -i "$static"/lib/*.a

          cp $bin/bin/getconf $bin/bin/getconf_
          mv $bin/bin/getconf_ $bin/bin/getconf
        '';
      });
      drvs = import ./default.nix {
        inherit pkgs;
        inherit glibc231;
      };
    in {
      packages.${system} = {
        inherit (drvs) depends bitcoind tarball dependsAarch64 bitcoindAarch64 tarballAarch64 crossGlibc231;
        default = drvs.bitcoind;
      };
    };
}
