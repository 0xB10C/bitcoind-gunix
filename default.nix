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
    # Assemble this gcc's target libs (libstdc++, libgcc) with OUR binutils
    # 2.41 (GUIX's version), not nixos-26.05's default 2.46. bitcoind links
    # these libs statically from $cc/lib (verified via `ld -t`), so their
    # assembler (gas) determines the bytes. binutils 2.46 changed the
    # alignment-NOP fill order (short-first; 2.41/2.44 emit long-first),
    # diverging libgcc/libstdc++ inter-function padding (e.g.
    # btree_release_tree_recursively at 0x181633) from upstream's GUIX-2.41
    # build — confirmed by byte-diffing our binary vs the upstream dae69848…
    # release at that offset.
    #
    # Setting depsBuildTarget alone is NOT enough: the gcc derivation also
    # pulls a 2.46 `as` onto PATH via depsBuildBuild (= buildPackages.stdenv.cc
    # = the gcc-wrapper-15.2.0 build compiler, which propagates
    # binutils-wrapper-2.46), and that 2.46 `as` wins the PATH lookup when the
    # newly-built xgcc assembles the target libs. Since this gcc is native
    # (no --with-as), the assembler is resolved purely from PATH at build time.
    # So we ALSO shadow `as` with the 2.41 one at the very front of PATH for
    # the whole gcc build (preConfigure below). A global binutils overlay would
    # be the "clean" version but breaks the 26.05 stdenv bootstrap.
    depsBuildTarget = [ bintoolsWithGlibc231 pkgs.patchelf ];
    preConfigure = (old.preConfigure or "") + ''
      # Shadow `as` (and the target-triple-prefixed alias) with binutils 2.41's
      # so xgcc assembles libgcc/libstdc++ with the GUIX NOP-fill order.
      mkdir -p "$TMPDIR/forceas/bin"
      ln -sf ${binutilsForGuix}/bin/as "$TMPDIR/forceas/bin/as"
      ln -sf ${binutilsForGuix}/bin/as "$TMPDIR/forceas/bin/x86_64-unknown-linux-gnu-as"
      ln -sf ${binutilsForGuix}/bin/as "$TMPDIR/forceas/bin/x86_64-pc-linux-gnu-as"
      export PATH="$TMPDIR/forceas/bin:$PATH"
    '';
    # Force NON-relaxable GOT relocs (R_X86_64_GOTPCREL, not …GOTPCRELX) in the
    # target libs: gas honors the LAST -mrelax-relocations, and 2.41's default
    # is relaxable. Must be in preBuild — gcc/common/builder.nix overwrites
    # EXTRA_FLAGS_FOR_TARGET for native builds, then seeds makeFlagsArray with
    # CXXFLAGS_FOR_TARGET; re-appending later wins. Without this the final link
    # relaxes libstdc++'s std::__timepunct_cache<>::_S_timezones GOT accesses
    # to direct, dropping 2 .got entries and rippling .text/.eh_frame (all 10
    # hashes off). Upstream keeps those GOT entries.
    preBuild = (old.preBuild or "") + ''
      makeFlagsArray+=(
        "CFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET -Wa,-mrelax-relocations=no"
        "CXXFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET -Wa,-mrelax-relocations=no"
        "FLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET -Wa,-mrelax-relocations=no"
      )
    '';
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
  # Built with the gcc-14 cross stdenv (nixos-26.05's default is gcc 15.2.0;
  # the glibc CRT/nonshared members linked into the binaries must be gcc-14 —
  # same reasoning as flake.nix's native glibc231).
  crossGlibc231 = (pkgsCrossAarch64.glibc.override {
    stdenv = pkgsCrossAarch64.gcc14Stdenv;
  }).overrideAttrs (old: {
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
      # Skip glibc's C++ link test — same nixos-26.05 reasoning as the native
      # glibc231 (flake.nix): the cross build stdenv's libstdc++ is gcc 15's,
      # built against a modern glibc, and won't link against the 2.31 being
      # built. C++ is test-only here too; the installed glibc is pure C.
      libc_cv_cxx_link_ok = "no";
    };
    # Force the cross C compiler to gcc 14.3.0 (GUIX's version), exactly as
    # flake.nix does for the native glibc231. glibc is a stdenv bootstrap
    # component, so `.override { stdenv = … }` is ignored — on nixos-26.05 the
    # cross glibc would otherwise build with the bootstrap cross gcc 15.2.0,
    # giving __libc_csu_init the gcc-15 register allocation (diverges from
    # upstream's gcc-14 codegen). Force CC only (not CXX — see flake.nix:
    # forcing CXX breaks glibc's cstdlib/cmath generation; the shipped glibc
    # is all C). `aarch64-linux-gnu-gcc` is the cross gcc14's driver name
    # (targetPrefix = "aarch64-linux-gnu-").
    preConfigure = (old.preConfigure or "") + ''
      export CC=${pkgsCrossAarch64.buildPackages.gcc14}/bin/aarch64-linux-gnu-gcc
    '';
    makeFlags = (old.makeFlags or [ ]) ++ [
      "CC=${pkgsCrossAarch64.buildPackages.gcc14}/bin/aarch64-linux-gnu-gcc"
    ];
    # Disable the same nixpkgs hardenings flake.nix's x86_64 glibc231 drops.
    # The decisive one is zerocallusedregs (-fzero-call-used-regs): it
    # appends register-zeroing before `ret` in glibc's nonshared members
    # (__libc_csu_init/fini), which upstream lacks — our csu objects were
    # coming out ~28/8 bytes larger without this.
    hardeningDisable = [
      "zerocallusedregs" "strictoverflow" "stackprotector"
      "stackclashprotection" "fortify" "fortify3"
      # New nixos-26.05 cross cc-wrapper defaults GUIX doesn't apply (see
      # bitcoind.nix). strictflexarrays1 is codegen-affecting;
      # libcxxhardeningfast is libc++-only (no-op for us).
      "strictflexarrays1" "libcxxhardeningfast"
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
  # NB: base the compiler on `gcc14`, not `stdenv.cc.cc` — nixos-26.05's
  # default cross gcc is 15.2.0; we need GUIX's 14.3.0. The cc-wrapper itself
  # (stdenv.cc) only contributes version-independent flags (-march=armv8-a,
  # the frame-pointer defaults), so overriding just its `cc` is enough.
  crossGuixGcc = pkgsCrossAarch64.stdenv.cc.override {
    bintools = crossBintools241;
    libc = crossGlibc231;
    cc = (pkgsCrossAarch64.gcc14.cc.override {
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

  # Cross-build the full depends tree (incl. the Qt6 GUI tree) with a *native*
  # build stdenv (so the native helper tools — native_capnp, mpgen, native_qt
  # — use the build machine's gcc) plus the aarch64 cross toolchain on PATH
  # (so HOST packages use aarch64-linux-gnu-gcc). Uses the GUIX-flags cross
  # gcc + binutils 2.41, rebuilt against glibc 2.31 (crossGlibc231 via
  # libcCross above) — which makes all 10 cross-built binaries byte-match the
  # upstream aarch64 release (the dynsym GLIBC symbol versions, .text/.eh_frame
  # all line up; see CLAUDE.md's aarch64 section).
  dependsAarch64 = pkgs.callPackage ./depends.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "aarch64-linux-gnu";
    buildQt = true;
    crossInputs = aarch64CrossInputs;
  };
  bitcoindAarch64 = pkgs.callPackage ./bitcoind-aarch64.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsAarch64;
    crossInputs = aarch64CrossInputs;
  };
  tarballAarch64 = pkgs.callPackage ./tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindAarch64;
    arch = "aarch64-linux-gnu";
    expectedSha256 = "4de1d568dedd48604f75132421bc0abeca432639589b49a3909c81db3a813112";
  };
in {
  inherit depends bitcoind tarball dependsAarch64 bitcoindAarch64 tarballAarch64 crossGlibc231;
}
