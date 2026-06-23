{ pkgs, version, url, sha256, buildSystem, sourceDateEpoch }:

let
  # --- x86_64 cross-to-self toolchain ---
  # GUIX builds the x86_64 release with a *cross* toolchain targeting the
  # vendor-less triple `x86_64-linux-gnu`, even though the build host is
  # x86_64. Mirror that: instantiate nixpkgs cross-to-self. nixpkgs treats
  # this as a real cross build (hostPlatform.config `x86_64-linux-gnu` !=
  # buildPlatform.config `x86_64-unknown-linux-gnu`), so we get prefixed
  # tools (`x86_64-linux-gnu-gcc`) — the exact analog of pkgsCrossAarch64.
  # As of 2026-06-10 this IS the canonical x86_64 toolchain (the former
  # native one is removed — see the NOTE above); it is also what makes the
  # .dbg target-triple divergence fixable (CLAUDE.md "Task #2 finding").
  pkgsCrossX86 = import pkgs.path {
    localSystem = buildSystem;
    crossSystem = { config = "x86_64-linux-gnu"; };
  };

  # x86_64-linux-gnu cross binutils 2.41 — same override as the aarch64
  # crossBinutils241: take the build-host cross binutils (runs on the build
  # machine, emits/targets x86_64-linux-gnu) and downgrade it to GUIX's 2.41.
  # Match GUIX's binutils compression config (gnu/packages/base.scm):
  # --enable-compressed-debug-sections=all makes gas/ld/objcopy default
  # to zlib-gabi-compressing debug sections — that's why every .debug_*
  # section in the upstream .dbg files is SHF_COMPRESSED (split-debug.sh
  # passes no explicit flag). And GUIX does NOT use --with-system-zlib,
  # so the deflate bytes come from binutils' bundled zlib — drop
  # nixpkgs' --with-system-zlib so ours come from the same bundled code
  # (identical 2.41 tarball ⇒ identical compressed bytes).
  crossBinutils241X86 = import ../lib/cross-binutils-241.nix { inherit pkgs; pkgsCross = pkgsCrossX86; };

  # Stock cross gcc14 wrapper, adjusted on two axes, used as
  # crossGlibc231X86's forced CC. glibc's statically-linked members carry
  # debug info (see crossGlibc231X86) and their DW_AT_producer must match
  # upstream's, which records NO frame-pointer and NO pie flags:
  # - the cc is rebuilt with --enable-default-pie: glibc's configure
  #   detects a default-PIE compiler (like GUIX's linux-base-gcc) and then
  #   does NOT pass an explicit -fpie to the csu/crt objects — same
  #   codegen, clean producer. (The full crossGuixGccX86 can't be used
  #   here: it depends on this very glibc via libcCross.)
  # - the rebuilt cc also bakes --with-as/--with-ld = cross binutils 2.41
  #   (the stock cc bakes the 2.46 wrapper): gas GENERATES the
  #   .debug_line programs (and assembles the .S CUs entirely), and the
  #   2.46 encoding diverges from upstream's GUIX-2.41 one. Code sections
  #   were already byte-identical under either gas; this aligns the debug.
  # - the wrapper's -fno-omit-frame-pointer injection is stripped so the
  #   -O2 default (omit) applies without explicit override flags.
  # Kernel headers pinned to GUIX's version (manifest.scm:
  # linux-libre-headers-6.1 = 6.1.119; vanilla 6.1.119's installed uapi
  # headers are equivalent — deblobbing doesn't touch them). The headers
  # version is visible in the .dbg: bitcoind's netlink code records
  # <linux/rtnetlink.h> enum DIEs, and newer headers (nixpkgs' 6.18) add
  # enumerators (RTM_NEWMULTICAST, RTA_FLOWLABEL, …) upstream's 6.1 lacks.
  # Used for glibc's --with-headers (and hence the cross gcc's sys-include
  # copies that bitcoind compiles against). Keep nixpkgs' no-relocs.patch.
  linuxHeaders61 = import ../lib/linux-headers-61.nix { inherit pkgs; pkgsCross = pkgsCrossX86; };

  gcc14X86NoFpCC = pkgsCrossX86.buildPackages.gcc14.cc.overrideAttrs (o: {
    configureFlags = (o.configureFlags or [ ]) ++ [
      "--enable-default-pie=yes"
      "--with-as=${crossBinutils241X86}/bin/x86_64-linux-gnu-as"
      "--with-ld=${crossBinutils241X86}/bin/x86_64-linux-gnu-ld"
    ];
  });
  gcc14X86NoFp = (pkgsCrossX86.buildPackages.gcc14.override {
    cc = gcc14X86NoFpCC;
  }).overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      substituteInPlace $out/nix-support/cc-cflags-before \
        --replace-fail "-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer" ""
    '';
  });

  # x86_64-linux-gnu cross glibc 2.31 — GUIX git source, GUIX configure
  # flags incl. the x86-only --enable-cet, frame-pointer omission,
  # hardeningDisable, 2.31 porting fixes (no nss seds, no C.UTF-8 locale
  # gen), structured like the aarch64 crossGlibc231. x86 deltas vs
  # the aarch64 one: --enable-cet added; NIX_CFLAGS_COMPILE omits BOTH frame
  # pointers (x86_64 gcc omits both at -O2; aarch64 keeps the non-leaf one)
  # and needs no -mbranch-protection (that's the aarch64 PAC/BTI analog of
  # CET, which glibc's own --enable-cet handles here).
  crossGlibc231X86 = (pkgsCrossX86.glibc.override {
    stdenv = pkgsCrossX86.gcc14Stdenv;
    linuxHeaders = linuxHeaders61;
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
        "--enable-cet"
        "--enable-bind-now"
        "--disable-werror"
        "--disable-timezone-tools"
        "--disable-profile"
        # Upstream's csu/crt DW_AT_producer has NO -fpie: glibc's
        # static-pie machinery is what passes it explicitly, so GUIX's
        # build had static-pie off. The codegen stays PIE because the
        # forced CC is default-PIE (gcc14X86NoFpCC above), like GUIX's.
        "--disable-static-pie"
      ];
    env = (old.env or { }) // {
      # NO frame-pointer flags (upstream's glibc DW_AT_producer records
      # bare `-g -O2`; the -O2 default omits both FPs — codegen identical,
      # and the forced CC below is the NoFp wrapper so nothing injects
      # -fno-omit-frame-pointer). The debug-prefix-map rewrites our source
      # dir to GUIX's ephemeral build dir: glibc compiles with CWD in the
      # source subdirs, so DW_AT_comp_dir is <srcdir>/<subdir> — upstream's
      # is /tmp/guix-build-glibc-cross-….drv-0/source/<subdir>. (Prefix-map
      # flags are not recorded in DW_AT_producer.) The ffile maps rewrite
      # the forced CC's internal header dir (stddef.h etc. reachable from
      # elf-init.c) and the kernel headers (--with-headers, reachable from
      # the stat wrappers' <linux/…>/<asm-generic/…> includes) to the /usr
      # spellings GUIX's store→/usr maps produce.
      NIX_CFLAGS_COMPILE = "-fdebug-prefix-map=/build/glibc-2.31=/tmp/guix-build-glibc-cross-x86_64-linux-gnu-2.31.drv-0/source"
        + " -ffile-prefix-map=${gcc14X86NoFpCC}/lib/gcc=/usr/lib/gcc"
        + " -ffile-prefix-map=${linuxHeaders61}/include=/usr/include";
      # Skip glibc's C++ link test — same reasoning as the native glibc231
      # and the aarch64 crossGlibc231: the build stdenv's libstdc++ is gcc
      # 15's, built against a modern glibc, and won't link against the 2.31
      # being built. C++ is test-only; the installed glibc is pure C.
      libc_cv_cxx_link_ok = "no";
    };
    # Keep the debug info: glibc builds with its default `-g -O2`, and the
    # statically-linked members' DWARF (atexit, elf-init/__libc_csu_init,
    # the stat wrappers, csu CRT .S files) flows into bitcoind's .dbg —
    # upstream's .dbg carries those 12 CUs. nixpkgs' separateDebugInfo was
    # what removed them (its fixup splits + strips every object, and its
    # setup hook adds `-ggdb -Wa,--compress-debug-sections` — the -ggdb
    # would be recorded in DW_AT_producer; upstream records bare -g -O2,
    # glibc's own configure default). The stripped runtime binaries are
    # unaffected: debug sections never change code layout; the 10-hash
    # gate verifies.
    separateDebugInfo = false;
    dontStrip = true;
    # glibc is a stdenv bootstrap component, so the `.override { stdenv }`
    # above is silently ignored for the compiler choice — force the
    # build→target cross gcc 14.3.0 via CC (CC only, not CXX — see the
    # aarch64 crossGlibc231's note). Same fix as there, but through the
    # NoFp wrapper variant (see gcc14X86NoFp above).
    # Also drop the -frandom-seed=<out-hash> appended by nixpkgs'
    # reproducible-builds hook — it would be recorded in DW_AT_producer.
    preConfigure = (old.preConfigure or "") + ''
      export CC=${gcc14X86NoFp}/bin/x86_64-linux-gnu-gcc
      export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')
    '';
    makeFlags = (old.makeFlags or [ ]) ++ [
      "CC=${gcc14X86NoFp}/bin/x86_64-linux-gnu-gcc"
    ];
    hardeningDisable = [
      "zerocallusedregs" "strictoverflow" "stackprotector"
      "stackclashprotection" "fortify" "fortify3"
      "strictflexarrays1" "libcxxhardeningfast"
      # "pic": the wrapper's default -fPIC injection breaks glibc's
      # pie-default detection (an explicit -fPIC supersedes the compiler's
      # default-PIE mode, so configure's __PIE__ conftest sees plain PIC →
      # "-fPIE is default: no" → glibc links its internal programs with
      # the non-PIE crt1/crtbegin while the default-PIE driver links PIE →
      # crtbegin R_X86_64_32 link failure). It would also be recorded in
      # DW_AT_producer of every member where glibc passes no own pic/pie
      # flag; upstream (wrapper-less GUIX) has no such flag. glibc passes
      # its own -fPIC where it matters (.os/.oS objects).
      "pic"
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
      # Keep the static libs (libc.a, libm.a, …) in $out/lib next to the
      # shared ones, like GUIX's glibc — do NOT split them into the
      # $static output as nixpkgs does. `-static` links (e.g. Qt's
      # configure-time feature checks: FindWrapRt's clock_gettime, the
      # posix_shm/posix_sem probes — Qt is configured -static) must find
      # -lc/-lm via the wrapper's normal library path, exactly as in
      # GUIX's container; with the split they failed ("cannot find -lc"),
      # silently turning OFF upstream-ON Qt features (the posix ipc ones
      # cost bitcoin-qt.dbg/bitcoin-gui.dbg two STT_FILE symtab entries).
      # The $static output remains declared but empty.
      mkdir -p $static/lib
      cp $bin/bin/getconf $bin/bin/getconf_
      mv $bin/bin/getconf_ $bin/bin/getconf
    '';
  });

  crossBintools241X86 = pkgsCrossX86.stdenv.cc.bintools.override {
    bintools = crossBinutils241X86;
    libc = crossGlibc231X86;
  };

  # x86_64-linux-gnu cross gcc 14.3.0 with GUIX's linux-base-gcc flags +
  # the deterministic-SSA patch, rebuilt against glibc 2.31 via libcCross,
  # structured like the aarch64 crossGuixGcc. x86 deltas vs the aarch64
  # one:
  #
  # - `--enable-cet=yes` (x86-only, omitted on aarch64).
  # - `--with-as` re-pointed at cross binutils 2.41. nixpkgs bakes --with-as
  #   into cross gcc (verified: it points at the 2.46 cross binutils
  #   wrapper), and gas's alignment-NOP fill order changed in 2.46
  #   (short-first; 2.41 = GUIX emits long-first), which diverges the
  #   inter-function padding of the statically-linked libgcc/libstdc++ on
  #   x86 — the bug the former native gcc rebuild fixed by PATH-shadowing
  #   `as` (cross gcc has --with-as, so overriding it is enough). Appending
  #   a second --with-as wins (autoconf last-takes-precedence). aarch64
  #   never hit this: fixed-width 4-byte instructions leave gas no
  #   NOP-size choice.
  # - target libs assembled with -Wa,-mrelax-relocations=no — the x86-only
  #   GOTPCRELX reloc issue:
  #   without it the final link relaxes libstdc++'s _S_timezones GOT
  #   accesses that upstream keeps.
  crossGuixGccX86 = pkgsCrossX86.stdenv.cc.override {
    bintools = crossBintools241X86;
    libc = crossGlibc231X86;
    cc = (pkgsCrossX86.buildPackages.gcc14.cc.override {
      libcCross = crossGlibc231X86;
    }).overrideAttrs (old: {
      configureFlags = (old.configureFlags or [ ]) ++ [
        "--enable-standard-branch-protection=yes"
        "--enable-cet=yes"
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
        "--with-as=${crossBinutils241X86}/bin/x86_64-linux-gnu-as"
        "--with-ld=${crossBinutils241X86}/bin/x86_64-linux-gnu-ld"
      ];
      patches = (old.patches or [ ]) ++ [ ../patches/gcc-ssa-generation.patch ];
      # gcc/common/builder.nix
      # seeds makeFlagsArray with the *_FOR_TARGET flags, so re-appending
      # here wins and gas (2.41, default relaxable) emits non-relaxable
      # R_X86_64_GOTPCREL in libgcc/libstdc++.
      #
      # The -fdebug-prefix-map rewrites the libgcc objects' DW_AT_comp_dir
      # (/build/build/x86_64-linux-gnu/libgcc) to GUIX's ephemeral gcc
      # build dir — upstream bitcoind.dbg carries libgcc2.c/unwind-dw2*
      # CUs with that comp_dir, and the relative source shape matches ours
      # (…/build sibling of …/gcc-14.3.0), so one map covers name+dir.
      # Debug info for libgcc only, with upstream's exact DW_AT_producer
      # `-g -g -g -O2 -O2 -O2`. The libgcc compile line is (verified from
      # the build log): $(FLAGS_FOR_TARGET) $(CFLAGS_FOR_TARGET)
      # [LIBGCC2_CFLAGS = literal -O2 + $(GCC_CFLAGS)(=CFLAGS_FOR_TARGET)
      # + LIBGCC2_DEBUG_CFLAGS(-g) + …]. With `-g` appended to
      # CFLAGS_FOR_TARGET only, -g appears 3× (CFLAGS + GCC_CFLAGS +
      # DEBUG_CFLAGS) ✓; -O2 would appear 4× (FLAGS + CFLAGS + GCC_CFLAGS
      # + the literal), so FLAGS_FOR_TARGET gets EXTRA's -O2 stripped → 3×.
      # Optimization is unaffected (CFLAGS_FOR_TARGET still carries -O2).
      # CXXFLAGS_FOR_TARGET gets NO -g: upstream's .dbg has no libstdc++
      # CUs, so libstdc++ stays debug-less (crtstuff is always -g0).
      # The ffile map rewrites the glibc header dir that libgcc's CUs
      # (unwind-dw2-fde-dip.c includes <elf.h>/<link.h>) record via our
      # -idirafter, to the /usr spelling GUIX's store→/usr maps produce.
      preBuild = (old.preBuild or "") + ''
        EXTRA_SANS_O2="''${EXTRA_FLAGS_FOR_TARGET/-O2 /}"
        GUIXMAPS="-fdebug-prefix-map=/build/build=/tmp/guix-build-gcc-cross-x86_64-linux-gnu-14.3.0.drv-0/build -ffile-prefix-map=${pkgs.lib.getDev crossGlibc231X86}/include=/usr/include"
        makeFlagsArray+=(
          "CFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET -Wa,-mrelax-relocations=no $GUIXMAPS -g"
          "CXXFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET -Wa,-mrelax-relocations=no $GUIXMAPS"
          "FLAGS_FOR_TARGET=$EXTRA_SANS_O2 $EXTRA_LDFLAGS_FOR_TARGET -Wa,-mrelax-relocations=no $GUIXMAPS"
        )
      '';
      # Keep the target libs' objects unstripped (nixpkgs' fixup strip
      # removed libgcc's debug info; upstream bitcoind.dbg carries the
      # libgcc2.c + unwind-dw2* CUs), but strip libstdc++/libsupc++:
      # upstream's .dbg has no CUs from them. CXXFLAGS_FOR_TARGET carries
      # no -g, but libsupc++'s C members (cp-demangle.c) are compiled with
      # CFLAGS_FOR_TARGET and would otherwise leak a CU into the link.
      # Stripping .a member debug never affects the code sections that end
      # up in the binaries (the 10-hash gate verifies).
      dontStrip = true;
      postFixup = (old.postFixup or "") + ''
        find $out -name 'libstdc++*.a' -o -name 'libsupc++*.a' | while read -r f; do
          ${crossBinutils241X86}/bin/x86_64-linux-gnu-objcopy \
            --enable-deterministic-archives --strip-debug "$f"
        done
      '';
    });
  };

  # x86_64-linux-gnu cross toolchain inputs — the cross-to-self analog of
  # aarch64CrossInputs. Prefix-only binaries (x86_64-linux-gnu-gcc/-objcopy/
  # …), so they never shadow the native build compiler on PATH.
  x86CrossInputs = [
    crossGuixGccX86
    crossGuixGccX86.bintools
  ];

  # Wrapper variant for the bitcoind compile that does NOT inject
  # `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` (nixpkgs' cross
  # cc-wrapper puts those in cc-cflags-before). With the injection gone,
  # nix/x86_64-linux-gnu/release.nix no longer needs the explicit -fomit-frame-pointer
  # override — and that matters for the .dbg: every explicit flag is
  # recorded in DW_AT_producer, while upstream GUIX compiles with bare
  # `-O2 -g` (the x86_64 -O2 default omits both frame pointers), so its
  # producer strings carry NO frame-pointer flags. Identical codegen, but
  # the producer string must match byte-for-byte for .dbg parity.
  # depends keeps the regular wrapper (its objects carry no debug info, so
  # producer strings don't matter there and its drv stays unchanged).
  crossGuixGccX86NoFp = crossGuixGccX86.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      substituteInPlace $out/nix-support/cc-cflags-before \
        --replace-fail "-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer" ""
    '';
  });
  x86CrossInputsNoFp = [
    crossGuixGccX86NoFp
    crossGuixGccX86NoFp.bintools
  ];

  # The canonical x86_64 release build, through the cross-to-self toolchain
  # like GUIX. nix/lib/depends.nix's hostTriple already defaults to
  # "x86_64-linux-gnu" (HOST= forces depends' cross-compile mode either
  # way); passing crossInputs makes the HOST packages use the prefixed
  # cross tools (the native helper tools use the plain gcc14Stdenv, exactly
  # like dependsAarch64).
  depends = pkgs.callPackage ../lib/depends.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "x86_64-linux-gnu";
    buildQt = true;
    crossInputs = x86CrossInputs;
  };
  bitcoind = pkgs.callPackage ./release.nix {
    inherit version url sha256 depends;
    inherit (pkgs) gcc14Stdenv;
    crossInputs = x86CrossInputsNoFp;
    guixGcc = crossGuixGccX86.cc;
    linuxHeaders = linuxHeaders61;
  };
  tarball = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256 sourceDateEpoch bitcoind;
  };
  # rc1: tarball + debugTarball pass null expectedSha256 — no upstream
  # SHA256SUMS to gate against yet.
  debugTarball = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256 sourceDateEpoch bitcoind;
    debug = true;
  };
in {
  inherit depends bitcoind tarball debugTarball
    crossGlibc231X86 crossGuixGccX86 crossGuixGccX86NoFp;
}
