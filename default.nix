{ pkgs ? import <nixpkgs> {}
# glibc 2.31 pulled from a separate nixpkgs pin (nixos-20.09 via flake.nix).
# Defaults to the active pkgs' glibc so `nix-build` (non-flake) still works,
# even though that flow will then use the current glibc, not 2.31.
, glibc231 ? pkgs.glibc
}:

let
  version = "31.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "sha256-C6DvXuo679lswXdL4nTD1ZSBLPrAmIgJ1wZzi7Bns+M=";

  # Downgrade binutils from nixpkgs' 2.44 to 2.41 (the version GUIX ships
  # in its package manifest, used by cross-binutils for the bitcoin cross
  # toolchain — see gnu/packages/base.scm:656 in GUIX). binutils version
  # changes affect linker layout decisions, section alignment, and (in
  # 2.44) the strictness of GNU property note merging.
  #
  # `outputs = ["out" "info" "man"]` avoids the multi-output reference
  # cycle that nixpkgs 25.11's binutils-unwrapped triggers when its
  # output-splitting machinery runs against the older 2.41 build.
  binutilsForGuix = pkgs.binutils-unwrapped.overrideAttrs (_: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    # Newer nixpkgs binutils patches may not apply to 2.41. Drop them.
    patches = [];
    outputs = [ "out" "info" "man" ];
  });

  # Build a gcc 14 / glibc 2.31 stdenv so the entire build (depends and the
  # final bitcoind link) uses glibc 2.31 — matching GUIX. The chain:
  #
  #   1. Wrap the existing gcc 14 with bintools/cc-wrapper scripts that
  #      point at glibc 2.31's lib dir, CRT files, and dynamic linker.
  #      That gives us `stdenvForGccRebuild` — a stdenv that compiles and
  #      links against glibc 2.31, but still ships the old libstdc++ built
  #      against the current glibc.
  #
  #   2. Rebuild gcc 14 itself inside `stdenvForGccRebuild`, applying
  #      GUIX's gcc-ssa-generation patch. The new gcc's libstdc++ is
  #      then compiled against glibc 2.31 and won't reference newer-
  #      glibc-only symbols (__libc_single_threaded from 2.32, the
  #      __isoc23_* family from 2.39).
  #
  #   3. Wrap the rebuilt gcc and use it as the final stdenv's CC.
  bintoolsWithGlibc231 = pkgs.wrapBintoolsWith {
    bintools = binutilsForGuix;
    libc = glibc231;
  };
  stdenvForGccRebuild = pkgs.overrideCC pkgs.gcc14Stdenv (pkgs.wrapCCWith {
    cc = pkgs.gcc14Stdenv.cc.cc;
    libc = glibc231;
    bintools = bintoolsWithGlibc231;
  });
  gcc14RebuiltWithGlibc231 = (pkgs.gcc14.cc.override {
    stdenv = stdenvForGccRebuild;
  }).overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./patches/gcc-ssa-generation.patch
    ];
    # Match GUIX's `linux-base-gcc` configure flags exactly, from
    # contrib/guix/manifest.scm:
    #
    #   (list "--enable-initfini-array=yes"
    #         "--enable-default-ssp=yes"
    #         "--enable-default-pie=yes"
    #         "--enable-host-bind-now=yes"
    #         "--enable-standard-branch-protection=yes"
    #         "--enable-cet=yes"
    #         "--enable-gprofng=no"
    #         "--disable-gcov"
    #         "--disable-libgomp"
    #         "--disable-libquadmath"
    #         "--disable-libsanitizer")
    #
    # nixpkgs already passes --enable-default-pie and (sometimes)
    # --enable-initfini-array; we add the rest verbatim.
    configureFlags = (old.configureFlags or []) ++ [
      "--enable-initfini-array=yes"
      "--enable-default-ssp=yes"
      "--enable-default-pie=yes"
      "--enable-host-bind-now=yes"
      "--enable-standard-branch-protection=yes"
      "--enable-cet=yes"
      "--enable-gprofng=no"
      "--disable-gcov"
      "--disable-libgomp"
      "--disable-libquadmath"
      "--disable-libsanitizer"
      # Disable NLS so libstdc++ doesn't compile gettext() calls into
      # the throw-helper functions (functexcept.o, cxx11-ios_failure.o).
      # With NLS=yes, libstdc++'s `_()` macro expands to `gettext()`;
      # with NLS=no, it's an identity macro. Upstream's GUIX-built
      # libstdc++ has NLS disabled (only dgettext, no gettext, in the
      # binary's dynsym), so matching this drops our gettext@GLIBC_2.2.5
      # entry — saves dynsym slot, .rela.plt entry, .plt entry, etc.
      "--disable-nls"
    ];
  });
  ccWithGlibc231 = pkgs.wrapCCWith {
    cc = gcc14RebuiltWithGlibc231;
    libc = glibc231;
    bintools = bintoolsWithGlibc231;
  };
  gcc14Glibc231Stdenv = pkgs.overrideCC pkgs.gcc14Stdenv ccWithGlibc231;

  depends = pkgs.callPackage ./depends.nix {
    inherit version url sha256;
    gcc14Stdenv = gcc14Glibc231Stdenv;
  };
  bitcoind = pkgs.callPackage ./bitcoind.nix {
    inherit version url sha256 depends;
    gcc14Stdenv = gcc14Glibc231Stdenv;
  };
  tarball = pkgs.callPackage ./tarball.nix {
    inherit version url sha256 bitcoind;
  };

  # --- aarch64 cross-compile spike (work in progress) ---
  # nixpkgs instantiated to cross-compile x86_64 -> aarch64-linux-gnu. We
  # use the GUIX target triple `aarch64-linux-gnu` (not nixpkgs' default
  # `aarch64-unknown-linux-gnu`) so the cross compiler is named
  # `aarch64-linux-gnu-gcc`, which is what Bitcoin's depends Makefile
  # invokes for HOST packages.
  pkgsCrossAarch64 = import pkgs.path {
    localSystem = "x86_64-linux";
    crossSystem = { config = "aarch64-linux-gnu"; };
  };

  # aarch64 cross glibc 2.31 — the same overrides flake.nix applies to the
  # native glibc231 (GUIX git source, no patches, GUIX configure flags,
  # -fomit-frame-pointer, postPatch/postInstall fixes for 2.31), applied to
  # the aarch64 cross glibc. Pointing the cross cc-wrapper's libc at this
  # makes all cross compiles use glibc 2.31 headers/CRTs (vs nixpkgs 2.40)
  # — the .text (inline functions) + dynsym/version gap driver.
  # NOTE: --enable-cet is x86-only and omitted.
  crossGlibc231 = pkgsCrossAarch64.glibc.overrideAttrs (old: {
    version = "2.31";
    src = pkgs.fetchgit {
      name = "glibc-2.31";
      url = "https://sourceware.org/git/glibc.git";
      rev = "7b27c450c34563a28e634cccb399cd415e71ebfe";
      hash = "sha256-wIq9cIHkI8HtsYa5UU1IfC8VIhXyz0vJau20WPJt+AQ=";
    };
    patches = [ ];
    configureFlags =
      (builtins.filter
        (f: !(pkgs.lib.hasPrefix "--enable-kernel" f
          || f == "--enable-stack-protector=strong"
          || f == "--enable-cet=permissive"
          || f == "--enable-fortify-source"))
        (old.configureFlags or [ ]))
      ++ [
        "--enable-stack-protector=all"
        "--enable-bind-now"
        "--disable-werror"
        "--disable-timezone-tools"
        "--disable-profile"
      ];
    # aarch64 keeps the non-leaf frame pointer at -O2 (omit only the leaf
    # one), unlike x86_64's glibc231 which omits both — see the frame-pointer
    # note in bitcoind-aarch64.nix. Without this, glibc's libc_nonshared.a
    # members (atexit, the stat wrappers) lose their frame setup and come out
    # ~12 bytes smaller than upstream's.
    #
    # -mbranch-protection=standard: glibc is built with the *stock* cross
    # gcc, which lacks GUIX's --enable-standard-branch-protection. The only
    # glibc code that ends up *in* the binary is the statically-linked
    # members (libc_nonshared.a's atexit/stat wrappers, csu's
    # __libc_csu_init/fini), and without branch protection they miss the
    # paciasp/autiasp (PAC) + bti landing pads upstream's glibc has — ~8
    # bytes/function. This flag is exactly what --enable-standard-branch-
    # protection defaults the compiler to, so it reproduces that codegen.
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = "-momit-leaf-frame-pointer -mbranch-protection=standard";
    };
    # Disable the same nixpkgs hardenings flake.nix's x86_64 glibc231 drops.
    # The decisive one is zerocallusedregs (-fzero-call-used-regs): it
    # appends register-zeroing before `ret` in glibc's nonshared members
    # (__libc_csu_init/fini), which upstream lacks — our csu objects were
    # coming out ~28/8 bytes larger without this.
    hardeningDisable = [
      "zerocallusedregs" "strictoverflow" "stackprotector"
      "stackclashprotection" "fortify" "fortify3"
    ];
    postPatch = ''
      sed -i 's/ot \$/ot:\n\ttouch $@\n$/' manual/Makefile
      echo "LDFLAGS-nscd += -static-libgcc" >> nscd/Makefile
    '';
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
      sed "/^GROUP/s|$out/lib/lib|$static/lib/lib|g" -i "$static"/lib/*.a
      cp $bin/bin/getconf $bin/bin/getconf_
      mv $bin/bin/getconf_ $bin/bin/getconf
    '';
  });

  # Downgrade the aarch64 cross binutils to GUIX's 2.41 (nixpkgs cross
  # ships 2.44; 2.44 relaxes aarch64 more aggressively → smaller
  # .text/.eh_frame than upstream). Override the *build-host* cross
  # binutils (the one that runs on x86_64 and targets aarch64) —
  # `stdenv.cc.bintools.bintools`, NOT `binutils-unwrapped` (which is the
  # aarch64-native binutils and can't run on the build machine). Mirrors
  # default.nix's native binutilsForGuix.
  crossBinutils241 = pkgsCrossAarch64.stdenv.cc.bintools.bintools.overrideAttrs (_: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    # Drop newer-binutils patches that may not apply to 2.41. Keep the
    # default cross outputs (incl. `dev`) — unlike the native
    # binutilsForGuix, the cross binutils' postInstall references $dev.
    patches = [ ];
  });
  crossBintools241 = pkgsCrossAarch64.stdenv.cc.bintools.override {
    bintools = crossBinutils241;
    libc = crossGlibc231;
  };

  # Full-attempt (gap-closing): rebuild the aarch64 cross gcc 14.3.0 with
  # GUIX's linux-base-gcc configure flags + the deterministic-SSA patch, so
  # ALL cross-compiled code (depends, glibc, bitcoind) gets GUIX's codegen
  # defaults — most importantly --enable-standard-branch-protection, which
  # emits BTI landing pads + PAC return-signing on aarch64 everywhere
  # (upstream has ~40.4k BTI vs ~34.5k from the stock cross gcc). This
  # mirrors default.nix's native gcc rebuild, but for the cross compiler.
  # (--enable-cet is x86-only and omitted here.)
  #
  # `libcCross = crossGlibc231` rebuilds the cross gcc (and its libstdc++)
  # *targeting* glibc 2.31 — the scoped analog of default.nix's
  # stdenvForGccRebuild. Setting the cc-wrapper/bintools `libc` to 2.31
  # alone broke linking (gcc/libgcc still built against 2.40 startfiles);
  # rebuilding gcc against 2.31 fixes that coherently, without the overlay
  # approach's breakage (overlaying glibc hit the x86_64 *build* glibc too).
  # This closes the remaining gap: 2.31 headers (inline functions → .text /
  # .eh_frame) + 2.31 dynsym/symbol versions.
  crossGuixGcc = pkgsCrossAarch64.stdenv.cc.override {
    bintools = crossBintools241;
    libc = crossGlibc231;
    cc = (pkgsCrossAarch64.stdenv.cc.cc.override {
      libcCross = crossGlibc231;
    }).overrideAttrs (old: {
      configureFlags = (old.configureFlags or [ ]) ++ [
        "--enable-standard-branch-protection=yes"
        "--enable-default-pie=yes"
        "--enable-default-ssp=yes"
        "--enable-initfini-array=yes"
        "--enable-host-bind-now=yes"
        "--enable-gprofng=no"
        "--disable-gcov"
        "--disable-libgomp"
        "--disable-libquadmath"
        "--disable-libsanitizer"
        "--disable-nls"
      ];
      patches = (old.patches or [ ]) ++ [ ./patches/gcc-ssa-generation.patch ];
    });
  };

  # aarch64 cross toolchain inputs: the GUIX-flags cross gcc wrapper
  # (provides aarch64-linux-gnu-gcc/g++ + gcc-ar/-nm/-ranlib) and its
  # bintools (aarch64-linux-gnu-ar/-strip/-objcopy/…).
  aarch64CrossInputs = [
    crossGuixGcc
    crossGuixGcc.bintools
  ];

  # Cross-build the depends tree (NO_QT for now) with a *native* build
  # stdenv (so the native helper tools — native_capnp, mpgen — use the
  # build machine's gcc) plus the aarch64 cross toolchain on PATH (so HOST
  # packages use aarch64-linux-gnu-gcc). Uses the GUIX-flags cross gcc +
  # binutils 2.41, rebuilt against glibc 2.31 (crossGlibc231 via libcCross
  # above). With 2.31 the binary's dynsym GLIBC symbol versions match
  # upstream exactly (325×2.17, 2×2.25, 2.27, 2.28, 4×2.29, 2.30; max 2.30)
  # and ~35 KB of .text inline-function delta closed. Remaining gap vs the
  # upstream aarch64 binary: .text ≈ -66 KB, .eh_frame ≈ -35 KB (codegen
  # iteration, like the x86_64 effort).
  dependsAarch64 = pkgs.callPackage ./depends.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "aarch64-linux-gnu";
    buildQt = false;
    crossInputs = aarch64CrossInputs;
  };
  bitcoindAarch64 = pkgs.callPackage ./bitcoind-aarch64.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsAarch64;
    crossInputs = aarch64CrossInputs;
  };
in {
  inherit depends bitcoind tarball dependsAarch64 bitcoindAarch64 crossGlibc231;
}
