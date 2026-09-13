{ pkgs, pkgs2405, version, src, buildSystem, sourceDateEpoch, detachedSigs, upstreamSha256 }:

let
  # === win64 (x86_64-w64-mingw32) cross-compile ============================
  # GUIX's win64 toolchain (manifest.scm make-mingw-pthreads-cross-toolchain):
  # binutils 2.41 + binutils-unaligned-default.patch, mingw-w64 12.0.0 CRT +
  # winpthreads (POSIX threads), gcc 14.3.0 (mingw-w64-base-gcc:
  # --enable-threads=posix --enable-default-ssp=yes --enable-host-bind-now=yes
  # --disable-gcov --disable-libgomp) + gcc-ssa-generation.patch. nixpkgs'
  # pkgsCross.mingwW64 defaults to mcf threads / gcc 15.2.0 / binutils 2.46 /
  # mingw-w64 13.0.0, so all four are pinned. msvcrt (not ucrt) CRT — GUIX
  # passes --with-default-msvcrt=msvcrt (12.0.0 flipped the default to UCRT).
  mingwTriple = "x86_64-w64-mingw32";

  # GUIX builds the mingw-w64 CRT + winpthreads with the cross binutils 2.41
  # (+ unaligned patch); nixpkgs' bootstrap uses 2.46, whose alignment NOP-fill
  # ORDER is reversed (short-first vs 2.41's long-first) — visible in the CRT's
  # pre_c_init padding at the very start of every .exe's .text. (The bootstrap
  # gcc is 15.2.0 vs GUIX's 14.3.0, but those produce byte-identical CRT objects
  # here, so only the binutils matters.) Build the CRT/winpthreads with the
  # bootstrap stdenvNoLibc gcc but its bintools swapped to 2.41. From a SEPARATE
  # clean cross import (mingwBootSet) to avoid a splice cycle with pkgsCrossMingw's
  # windows override; using stdenvNoLibc.cc (NOT gccWithoutTargetLibc, which
  # drags in a broken, uncacheable target-bash).
  mingwBootSet = import pkgs.path {
    localSystem = buildSystem;
    crossSystem = { config = mingwTriple; libc = "msvcrt"; };
    config.allowUnsupportedSystem = true;
  };
  # PLAIN binutils 2.41 for the CRT/winpthreads — NO unaligned-default patch.
  # GUIX's make-mingw-w64 (CRT + winpthreads) passes no #:xbinutils, so it uses
  # the UNPATCHED cross-binutils; only the final gcc's binutils
  # (binutils-mingw-patches) gets the patch. With the patch, gas encodes
  # aligned vector moves as unaligned (movaps→movups), which diverged the CRT's
  # _FindPESectionExec etc. (ours movups 0f11, upstream movaps 0f29).
  # v32.x branch-off (guix pin c5eee3336cc1): that UNPATCHED default is now
  # guix's (cross-binutils "x86_64-w64-mingw32") = binutils 2.44 with
  # base.scm's two patches + cross-base.scm's mingw pair (windres,
  # deterministic) and --enable-compressed-debug-sections=no. The same
  # toolchain also builds the NSIS stubs (make-nsis's xbinutils).
  mingwCrtBinutils241 = mingwBootSet.stdenv.cc.bintools.bintools.overrideAttrs (old: {
    version = "2.44";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.44.tar.bz2";
      hash = "sha256-9mOQpmH6oRfQD6suec8tydCXtCzClr8/hnfR57RS3Do=";
    };
    patches = [
      ../patches/binutils-2.41-fix-cross.patch
      ../patches/binutils-loongson-workaround.patch
      ../patches/binutils-cross-windres.patch
      ../patches/binutils-mingw-w64-deterministic.patch
    ];
    # plain tarball has no gold/ (see lib/cross-binutils-246.nix)
    preConfigure = builtins.replaceStrings [ " gold/Makefile.in" ] [ "" ] (old.preConfigure or "");
    passthru = (old.passthru or { }) // { hasGold = false; };
    configureFlags =
      (builtins.filter (f: f != "--with-system-zlib" && f != "--enable-gold")
        (old.configureFlags or [ ]))
      ++ [ "--enable-compressed-debug-sections=no" ];
  });
  # GUIX builds the CRT/winpthreads with base-gcc 14.3.0; gcc 15 diverges from
  # 14 on the CRT (verified: crtexe.c __tmainCRTStartup is 16 B bigger under
  # gcc15 — dllimport `mov`/IAT becomes `lea`/auto-import), so we need a gcc 14
  # NOLIBC cross cc. Reconstruct it as the gcc14 cc with the same nolibc args
  # the bootstrap uses, + --with-as/--with-ld=2.41 (the bootstrap BAKES
  # --with-as=2.46, which also reverses the alignment NOP-fill order). This
  # UNWRAPPED cc does NOT pull the target-bash that the gccWithoutTargetLibc
  # WRAPPER drags in — we wrap it with the clean stdenvNoLibc.cc wrapper below.
  # Build it by SWAPPING the gcc 14.3.0 source into the bootstrap nolibc gcc15
  # cc via overrideAttrs (NOT .override) — this keeps every other input
  # (binutils-wrapper, the buildable target-bash, mingw headers) byte-identical
  # to the working gcc15 path. Constructing a nolibc gcc14 fresh with .override
  # instead yields a different binutils-wrapper whose target-bash can't build
  # (bash doesn't cross-compile to mingw and isn't cached for this triple).
  # Append --with-as/--with-ld=2.41 (the bootstrap BAKES --with-as=2.46, which
  # reverses the alignment NOP-fill order). gcc14's own src + patches; relax the
  # version self-check.
  mingwCc14Unwrapped = mingwBootSet.stdenvNoLibc.cc.cc.overrideAttrs (old: {
    inherit (mingwBootSet.buildPackages.gcc14.cc) version src;
    patches = mingwBootSet.buildPackages.gcc14.cc.patches;
    postPatch = builtins.replaceStrings [ "15.2.0" ] [ "14.3.0" ] (old.postPatch or "");
    configureFlags = (old.configureFlags or [ ]) ++ [
      "--with-as=${mingwCrtBinutils241}/bin/${mingwTriple}-as"
      "--with-ld=${mingwCrtBinutils241}/bin/${mingwTriple}-ld"
    ];
    # HAVE_GAS_CFI_DIRECTIVE=1 (see mingwGuixGcc) so the CRT/winpthreads
    # .debug_frame is gas-generated (CIE v1, RA col 32), matching upstream.
    preConfigure = (old.preConfigure or "") + ''
      export OBJDUMP_FOR_TARGET=${mingwCrtBinutils241}/bin/${mingwTriple}-objdump
      export gcc_cv_objdump=${mingwCrtBinutils241}/bin/${mingwTriple}-objdump
      export gcc_cv_as_cfi_directive=yes
      export gcc_cv_as_cfi_advance_working=yes
        export gcc_cv_as_cfi_personality_directive=yes
        export gcc_cv_as_cfi_sections_directive=yes
    '';
  });
  # NOLIBC stdenv for the CRT (mingw_w64) itself — it only emits .o/.a, no
  # shared link, so it can't (and mustn't) depend on a target libc.
  # Strip the wrapper's -fno-omit-frame-pointer / -mno-omit-leaf-frame-pointer
  # from a wrapped cc so the CRT/winpthreads build with the bare -O2 default
  # (omit BOTH) — matching GUIX's flag-free base-gcc producer (NO frame-pointer
  # flag recorded in DW_AT_producer) with byte-identical codegen (x86_64 -O2
  # omits FP by default). Doing it via the wrapper (not NIX_CFLAGS) leaves the
  # producer clean, like bitcoind's mingwGuixGccNoFp.
  stripMingwFpFlags = wrappedCc: wrappedCc.overrideAttrs (o: {
    # The flags live in cc-cflags-before on 26.05; older cc-wrappers (24.05,
    # for the NSIS gcc11) may not create that file or inject the flags at all
    # (then -O2 already omits the FP) — so guard the file and replace quietly.
    postFixup = (o.postFixup or "") + ''
      if [ -f $out/nix-support/cc-cflags-before ]; then
        substituteInPlace $out/nix-support/cc-cflags-before \
          --replace-quiet "-fno-omit-frame-pointer" "" \
          --replace-quiet "-mno-omit-leaf-frame-pointer" ""
      fi
    '';
  });
  mingwCrtStdenv =
    let
      bintools241 = mingwBootSet.stdenvNoLibc.cc.bintools.override {
        bintools = mingwCrtBinutils241;
      };
      cc241 = stripMingwFpFlags (mingwBootSet.stdenvNoLibc.cc.override {
        cc = mingwCc14Unwrapped;
        bintools = bintools241;
      });
    in mingwBootSet.overrideCC mingwBootSet.stdenvNoLibc cc241;
  # CRT-AWARE stdenv for winpthreads, which links a shared libwinpthread (needs
  # dllcrt2.o / -lmingw32 / -lmsvcrt …). Same clean wrapper + 2.41 as, but with
  # libc = the boot set's CRT so the link resolves. bitcoind statically links
  # libwinpthread.a (the .o content, compiled from our 12.0.0 source by this
  # gcc), so which CRT the *shared* link uses never reaches the final binary.
  mingwPthreadsStdenv =
    let
      bootCrt = mingwBootSet.windows.mingw_w64;
      bintools241 = mingwBootSet.stdenvNoLibc.cc.bintools.override {
        bintools = mingwCrtBinutils241;
        libc = bootCrt;
      };
      cc241 = stripMingwFpFlags (mingwBootSet.stdenvNoLibc.cc.override {
        cc = mingwCc14Unwrapped;
        bintools = bintools241;
        libc = bootCrt;
        noLibc = false;
      });
    in mingwBootSet.overrideCC mingwBootSet.stdenvNoLibc cc241;

  pkgsCrossMingw = import pkgs.path {
    localSystem = buildSystem;
    crossSystem = { config = mingwTriple; libc = "msvcrt"; };
    config.allowUnsupportedSystem = true;
    overlays = [
      (final: prev: {
        # mingw-w64: GUIX's pin (c5eee3336cc1) is 13.0.0 == nixpkgs-26.05's,
        # so the former 12.0.0 headers override is gone. The CRT (mingw_w64)
        # and winpthreads (pthreads) both `inherit (mingw_w64_headers)
        # version src`.
        windows = prev.windows.overrideScope (wfinal: wprev: {
          # The mingw-w64 CRT (crt2.o etc.) and winpthreads are built by
          # nixpkgs' bootstrap cc-wrapper (crossThreadsStdenv), which injects
          # -fno-omit-frame-pointer. GUIX builds them with bare cross-gcc → -O2
          # omits the frame pointer. Those CRT objects are linked into every
          # .exe, so their FP prologues leak into the shipped binaries (the
          # startup code at the bottom of .text). Override the injection so the
          # CRT/winpthreads match GUIX's flag-free -O2 codegen.
          # Also disable the nixpkgs hardenings GUIX's bare base-gcc doesn't
          # apply: zerocallusedregs (-fzero-call-used-regs appends register-
          # zeroing `xor`s before returns — visible in the CRT/winpthreads
          # functions linked into every .exe), plus the rest of the set
          # bitcoind/depends drop. GUIX's CRT is built by plain base-gcc with
          # none of these.
          # Build the CRT + winpthreads with the gcc 14.3.0 / binutils 2.41
          # NOLIBC stdenv (mingwCrtStdenv) instead of nixpkgs' bootstrap 15.2.0
          # / 2.46 — see mingwCrtStdenv. Plus the FP + hardening overrides so
          # the codegen matches GUIX's flag-free -O2 base-gcc CRT.
          # -g + the GUIX ephemeral comp_dir map so the CRT/winpthreads debug
          # info (which strip moves into each .dbg) byte-matches upstream. GUIX
          # builds both in ONE drv at /tmp/guix-build-mingw-w64-x86_64-winpthreads-
          # 12.0.0.drv-0/mingw-w64-v12.0.0/{mingw-w64-crt,mingw-w64-libraries/
          # winpthreads}; nixpkgs builds at /build/mingw-w64-v12.0.0 (same shape),
          # so one prefix map covers both comp_dirs. dontStrip keeps the .o debug.
          # Only the comp_dir prefix-map — NO -g here. The CRT/winpthreads
          # autotools build already passes -g -O2 (autoconf default CFLAGS /
          # the mingw makefiles), so adding our own -g would record a SECOND -g
          # in DW_AT_producer (upstream has exactly one). dontStrip keeps the
          # makefile-emitted debug info; the map rewrites its comp_dir to GUIX's.
          mingwCrtDbgFlags = " -fdebug-prefix-map=/build/mingw-w64-v13.0.0="
            + "/tmp/guix-build-mingw-w64-x86_64-winpthreads-13.0.0.drv-0/mingw-w64-v13.0.0"
            # gcc builtin headers (xmmintrin.h, stddef.h, …) that a few CRT/
            # winpthreads files pull resolve to the boot gcc's own
            # lib/gcc/<triple>/14.3.0/include; upstream records them as
            # /usr/lib/gcc/<triple>/14.3.0/include (GUIX's gcc store→/usr).
            + " -ffile-prefix-map=${mingwCc14Unwrapped}/lib/gcc/${mingwTriple}/14.3.0/include"
            + "=/usr/lib/gcc/${mingwTriple}/14.3.0/include";
          # Drop the -frandom-seed=<out-hash> nixpkgs' reproducible-builds hook
          # appends — it lands in DW_AT_producer (upstream has none). Codegen is
          # unchanged (the stripped CRT already byte-matches with it present).
          mingwCrtSeedStrip = ''
            export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')
          '';
          # The CRT/winpthreads .debug_line directory tables must record the
          # headers from the IN-SOURCE split tree (mingw-w64-headers/{include,
          # crt,defaults/include,direct-x/include}), NOT nixpkgs' MERGED
          # mingw_w64_headers package (one flat include/) — GUIX's make-mingw-w64
          # sets CROSS_C_INCLUDE_PATH to exactly those source subdirs (mingw.scm
          # setenv phase). Mirror it: -isystem the in-source dirs in GUIX's order
          # so each header resolves to the same split dir GUIX records (corecrt.h
          # → .../crt, winnt.h → .../include), searched BEFORE the boot gcc's
          # baked sys-include (the merged headers, which then never resolve → are
          # never recorded). The existing /build/mingw-w64-v12.0.0 → ephemeral map
          # rewrites them to GUIX's /tmp/.../mingw-w64-headers/* spellings. Both
          # the crt and winpthreads nixpkgs drvs unpack the full source, so
          # /build/mingw-w64-v12.0.0/mingw-w64-headers is present in each.
          mingwCrtHeaderInc =
            let base = "/build/mingw-w64-v13.0.0/mingw-w64-headers";
            in " -isystem ${base}"
              + " -isystem ${base}/include"
              + " -isystem ${base}/crt"
              + " -isystem ${base}/defaults/include"
              + " -isystem ${base}/direct-x/include";
          mingw_w64 = (wprev.mingw_w64.override { stdenv = mingwCrtStdenv; }).overrideAttrs (o: {
            hardeningDisable = (o.hardeningDisable or [ ]) ++ [
              "zerocallusedregs" "strictoverflow" "stackprotector"
              "stackclashprotection" "fortify" "fortify3"
              "strictflexarrays1" "libcxxhardeningfast" "format"
            ];
            dontStrip = true;
            separateDebugInfo = false;
            # ac_cv_prog_cc_c23=no: nixpkgs runs autoreconfHook, and autoconf
            # 2.72's AC_PROG_CC appends -std=gnu23 to CC (the newest std the
            # bootstrap gcc supports) → recorded in the crt's DW_AT_producer
            # (the per-file -std=gnu99 wins for codegen, but gnu23 stays in the
            # string). GUIX's older configure never probes C23. Same cache var
            # as gawk530.
            configureFlags = (o.configureFlags or [ ]) ++ [ "ac_cv_prog_cc_c23=no" ];
            preConfigure = (o.preConfigure or "") + wfinal.mingwCrtSeedStrip;
            env = (o.env or { }) // {
              NIX_CFLAGS_COMPILE = (o.env.NIX_CFLAGS_COMPILE or "")
                + wfinal.mingwCrtDbgFlags + wfinal.mingwCrtHeaderInc;
            };
          });
          pthreads = (wprev.pthreads.override { stdenv = mingwPthreadsStdenv; }).overrideAttrs (o: {
            hardeningDisable = (o.hardeningDisable or [ ]) ++ [
              "zerocallusedregs" "strictoverflow" "stackprotector"
              "stackclashprotection" "fortify" "fortify3"
              "strictflexarrays1" "libcxxhardeningfast" "format"
            ];
            dontStrip = true;
            separateDebugInfo = false;
            configureFlags = (o.configureFlags or [ ]) ++ [ "ac_cv_prog_cc_c23=no" ];
            preConfigure = (o.preConfigure or "") + wfinal.mingwCrtSeedStrip;
            env = (o.env or { }) // {
              NIX_CFLAGS_COMPILE = (o.env.NIX_CFLAGS_COMPILE or "")
                + wfinal.mingwCrtDbgFlags + wfinal.mingwCrtHeaderInc;
            };
          });
        });
      })
    ];
  };

  # GUIX uses winpthreads (POSIX threads), not nixpkgs' default mcfgthreads.
  # We can't set the global `threads` overlay attr to winpthreads: that puts
  # winpthreads into the final gcc's depsTargetTarget, and its pthread.h then
  # shadows the BUILD glibc's when gcc builds its own native helper tools
  # (libcody's gthr-default.h pulls in <pthread.h> → <process.h> not found).
  # GUIX instead merges winpthreads' headers+libs INTO the cross libc (its
  # make-mingw-w64 #:with-winpthreads?), so pthread.h is reachable only on the
  # TARGET include path. Mirror that: a merged CRT+winpthreads libc, passed to
  # the final gcc as libcCross, with --enable-threads=posix (threadsCross.model)
  # but no separate threadsCross.package (so depsTargetTarget stays empty).
  # winpthreads MUST come first: the mingw-w64 CRT ships DUMMY pthread*.h /
  # pthread_time.h headers ("gets overridden if winpthread is installed") —
  # the dummy pthread_time.h declares no clock_gettime/CLOCK_REALTIME, so
  # Qt's FindWrapRt HAVE_GETTIME check (and std::chrono in libstdc++) fail.
  # symlinkJoin is first-wins, so listing pthreads first makes its REAL
  # pthread_time.h win, with the rest of the CRT headers/libs falling through.
  mingwLibc = pkgs.symlinkJoin {
    name = "mingw-w64-crt-with-winpthreads-13.0.0";
    paths = [
      pkgsCrossMingw.windows.pthreads
      pkgsCrossMingw.windows.mingw_w64
      pkgsCrossMingw.windows.mingw_w64.dev
    ];
  };

  # binutils 2.41 + GUIX's binutils-unaligned-default.patch (turns on
  # -muse-unaligned-vector-move by default — avoids unaligned-instruction
  # divergence). Same bundled-zlib + compressed-debug-sections override as
  # the linux crossBinutils241X86.
  # v32.x branch-off: GUIX's (binutils-mingw-patches (base-binutils target))
  # — a FRESH 2.46.0 origin (no guix patches) + only the unaligned patch,
  # keeping cross-binutils' mingw --enable-compressed-debug-sections=no.
  mingwBinutils241 = pkgsCrossMingw.stdenv.cc.bintools.bintools.overrideAttrs (old: {
    version = "2.46.0";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.46.0.tar.bz2";
      hash = "sha256-DzFSYyoqnOBm8glj6btAr3z4W5tsQJ7Ykv0GduhOzRI=";
    };
    patches = [ ../patches/binutils-unaligned-default.patch ];
    # plain tarball has no gold/ (see lib/cross-binutils-246.nix)
    preConfigure = builtins.replaceStrings [ " gold/Makefile.in" ] [ "" ] (old.preConfigure or "");
    passthru = (old.passthru or { }) // { hasGold = false; };
    # NO --enable-compressed-debug-sections: GUIX's mingw binutils does NOT
    # default-compress (its .obj carry plain .debug_*, verified in the local
    # guix-build). With compression ON gas emits PE .zdebug_frame$<mangled> for
    # C++ COMDAT FDEs while the COMDAT group symbol stays .debug_frame$<mangled>
    # — ld warns "COMDAT symbol does not match section name" and, during
    # cross-TU COMDAT dedup, drops the IMAGE_COMDAT_SELECT_ANY (comdat 2)
    # selection on the kept section symbol → our .dbg COFF symtab had comdat 0
    # where upstream has 2 (the last ~268 .dbg bytes). Uncompressed = names
    # match = selection preserved. (Linux targets DO compress — their .dbg are
    # SHF_COMPRESSED; PE .dbg are not, so this flag was wrong for mingw.)
    configureFlags =
      (builtins.filter (f: f != "--with-system-zlib" && f != "--enable-gold")
        (old.configureFlags or [ ]))
      ++ [ "--enable-compressed-debug-sections=no" ];
  });
  mingwBintools241 = pkgsCrossMingw.stdenv.cc.bintools.override {
    bintools = mingwBinutils241;
    libc = mingwLibc;
  };

  # Final cross gcc 14.3.0 with GUIX's mingw-w64-base-gcc flags. Posix
  # threads come from the overlay (threadsCross). gcc-ssa-generation.patch
  # for deterministic SSA numbering (same as every other target).
  mingwGuixGcc = pkgsCrossMingw.stdenv.cc.override {
    bintools = mingwBintools241;
    libc = mingwLibc;
    cc = (pkgsCrossMingw.buildPackages.gcc14.cc.override {
      libcCross = mingwLibc;
      # posix threads (winpthreads merged into libcCross above); no separate
      # threadsCross.package → nothing in depsTargetTarget to leak to the
      # build compiler.
      threadsCross = { model = "posix"; package = null; };
    }).overrideAttrs (old: {
      configureFlags = (old.configureFlags or [ ]) ++ [
        "--enable-default-ssp=yes"
        "--enable-gprofng=no"
        "--enable-host-bind-now=yes"
        "--disable-gcov"
        "--disable-libgomp"
        # new in manifest_build.scm's mingw-w64-base-gcc at the branch-off
        "--disable-libsanitizer"
        "--disable-lto"
        "--disable-nls"
        "--with-as=${mingwBinutils241}/bin/${mingwTriple}-as"
        "--with-ld=${mingwBinutils241}/bin/${mingwTriple}-ld"
      ];
      # gcc-debug-canon-prefix-map.patch: route the depends→/bitcoin rewrite
      # through NIX_DEBUG_CANON_PREFIX_MAP (malloc'd, GGC-neutral) instead of a
      # -ffile-prefix-map. GUIX's depends live at the real /bitcoin/depends/<host>
      # so NO map fires there; our -ffile-prefix-map's per-header ggc_alloc
      # rewrites shift the GGC arena → var-tracking picks a different equivalent
      # loclist representative in the biggest CUs (bitcoind/-qt/test_bitcoin),
      # giving a −44 B .debug_loclists divergence. Same fix + patch as armhf/ppc64
      # (see canonDepends in mkLinuxCrossTarget). v6 also hooks remap_macro_filename
      # so the depends __FILE__ macros still rewrite (no raw store path in .rodata).
      patches = (old.patches or [ ]) ++ [
        ../patches/gcc-ssa-generation.patch
        ../patches/gcc-debug-canon-prefix-map.patch
      ];
      dontStrip = true;
      # gcc's configure decides HAVE_GAS_CFI_DIRECTIVE by running the CROSS
      # objdump on a test .o ("working cfi advance" check). Without a working
      # objdump it errs to 0 → gcc emits .debug_frame DIRECTLY (CIE v3, RA col
      # 16) instead of via gas .cfi (CIE v1, RA col 32 — what GUIX's gcc, which
      # had objdump, produces). Point OBJDUMP_FOR_TARGET at the cross objdump so
      # the check passes and .debug_frame matches upstream. (Only affects
      # .debug_frame in the .dbg, not the SEH .xdata in the stripped binary.)
      preConfigure = (old.preConfigure or "") + ''
        export OBJDUMP_FOR_TARGET=${mingwBinutils241}/bin/${mingwTriple}-objdump
        export gcc_cv_objdump=${mingwBinutils241}/bin/${mingwTriple}-objdump
        export gcc_cv_as_cfi_directive=yes
        export gcc_cv_as_cfi_advance_working=yes
        export gcc_cv_as_cfi_personality_directive=yes
        export gcc_cv_as_cfi_sections_directive=yes
      '';
      # libgcc's debug info (which strip moves into each .dbg) must carry GUIX's
      # paths: comp_dir at the ephemeral gcc build dir, and the mingw headers it
      # includes mapped to /usr (GUIX's /gnu/store→/usr). Same preBuild pattern
      # as the linux crossGuixGcc.
      preBuild = (old.preBuild or "") + ''
        EXTRA_SANS_O2="''${EXTRA_FLAGS_FOR_TARGET/-O2 /}"
        GUIXMAPS="-fdebug-prefix-map=/build/build=/tmp/guix-build-gcc-cross-${mingwTriple}-14.3.0.drv-0/build -ffile-prefix-map=${mingwLibc}/include=/usr/include"
        makeFlagsArray+=(
          "CFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS -g"
          "CXXFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS"
          "FLAGS_FOR_TARGET=$EXTRA_SANS_O2 $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS"
        )
      '';
      # Strip debug from the C++ runtime archives AND libssp: upstream's .dbg
      # has none of their CUs (verified against the local GUIX win64 build —
      # 0 ssp.c CUs). bitcoind statically links libssp's __*_chk /
      # __stack_chk_fail (so the .text matches), but our -g leaves ssp.c /
      # *-chk.c CUs in the .dbg that GUIX's stripped libssp lacks.
      postFixup = (old.postFixup or "") + ''
        find $out \( -name 'libstdc++*.a' -o -name 'libsupc++*.a' -o -name 'libssp*.a' \) | while read -r f; do
          ${mingwBinutils241}/bin/${mingwTriple}-objcopy \
            --enable-deterministic-archives --strip-debug "$f"
        done
      '';
    });
  };
  mingwCrossInputs = [ mingwGuixGcc mingwGuixGcc.bintools ];

  # NoFp wrapper variant — strips BOTH of the cc-wrapper's frame-pointer
  # injections (-fno-omit-frame-pointer AND -mno-omit-leaf-frame-pointer) so
  # bitcoind compiles bare -O2. On x86_64 -O2 omits ALL frame pointers, which
  # is what upstream's flag-free DW_AT_producer records (build.sh's HOST_CFLAGS
  # is just -O2 -g -fno-ident + maps). Stripping only the -fno- flag (as the
  # linux targets do, where the wrapper injects only that) left
  # -mno-omit-leaf-frame-pointer behind — the single DW_AT_producer delta vs
  # upstream, and it kept frame pointers, growing .text/.xdata.
  mingwGuixGccNoFp = mingwGuixGcc.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      substituteInPlace $out/nix-support/cc-cflags-before \
        --replace-fail "-fno-omit-frame-pointer" "" \
        --replace-fail "-mno-omit-leaf-frame-pointer" ""
    '';
  });
  mingwCrossInputsNoFp = [ mingwGuixGccNoFp mingwGuixGccNoFp.bintools ];
  # The mingw-w64 CRT (msvcrt headers/libs) store path — leaks into
  # bitcoind's debug info via the system include path; mapped to /usr.
  mingwCrt = pkgsCrossMingw.windows.mingw_w64;

  # win64 depends trees (no X11 — Windows Qt). Package set (depends
  # packages.mk *_mingw32_packages): boost qrencode qt sqlite zeromq capnp
  # + native_{capnp,libmultiprocess,qt}. TWO trees, like upstream's two
  # build passes: build_win.sh builds depends with NO_QT=1 under BASE_CACHE
  # .../GUIX/BUILD, build_win_gui.sh the full tree under .../GUIX/GUI.
  dependsNoQtMingw = pkgs.callPackage ../lib/depends.nix {
    inherit version src;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = mingwTriple;
    buildQt = false;
    crossInputs = mingwCrossInputs;
  };
  dependsMingw = pkgs.callPackage ../lib/depends.nix {
    inherit version src;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = mingwTriple;
    buildQt = true;
    crossInputs = mingwCrossInputs;
  };

  # Per-binary reference hashes are not published (upstream's SHA256SUMS
  # covers only the assembled archives); package.sh's wrapper prints every
  # binary/.dbg hash for the log instead.
  mingwReleaseArgs = {
    inherit version src;
    inherit (pkgs) gcc14Stdenv;
    crossInputs = mingwCrossInputsNoFp;
    guixGcc = mingwGuixGcc.cc;
    mingwCrt = mingwCrt;
    mingwPthreads = pkgsCrossMingw.windows.pthreads;
    hostTriple = mingwTriple;
  };
  bitcoindMingwNoGui = pkgs.callPackage ./release.nix (mingwReleaseArgs // {
    pname = "bitcoind-win64-nogui";
    depends = dependsNoQtMingw;
  });
  bitcoindMingwGui = pkgs.callPackage ./release.nix (mingwReleaseArgs // {
    pname = "bitcoind-win64-gui";
    depends = dependsMingw;
    guiOnly = true;
  });
  # Upstream's libexec/package.sh over the merged install tree: split
  # debug info, the two zips, the NSIS installer (via the generated
  # build/GenerateWindowsInstaller.cmake, which is why nsis is an input)
  # and the codesigning tarball — all four published win64 artifacts come
  # out of this one derivation. NSIS is our GUIX-style 3.10 build.
  packagedMingw = pkgs.callPackage ../lib/package.nix {
    inherit version src sourceDateEpoch;
    hostTriple = mingwTriple;
    noGui = bitcoindMingwNoGui;
    gui = bitcoindMingwGui;
    crossInputs = mingwCrossInputsNoFp;
    nsis = nsis310;
    pname = "bitcoin-win64-packaged";
  };
  # The install tree package.sh split the debug info out of (8 .exe + 8
  # .dbg), kept for per-binary diffing against a reference build.
  bitcoindMingw = packagedMingw.installed;
  mkArtifactMingw = args:
    pkgs.callPackage ../lib/artifact.nix { } ({ packaged = packagedMingw; } // args);

  unsignedZipMingw = mkArtifactMingw {
    file = "bitcoin-${version}-win64-unsigned.zip";
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-unsigned.zip";
  };
  debugZipMingw = mkArtifactMingw {
    file = "bitcoin-${version}-win64-debug.zip";
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-debug.zip";
  };
  setupExeMingw = mkArtifactMingw {
    file = "bitcoin-${version}-win64-setup-unsigned.exe";
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-setup-unsigned.exe";
  };
  codesigningMingw = mkArtifactMingw {
    file = "bitcoin-${version}-win64-codesigning.tar.gz";
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-codesigning.tar.gz";
  };

  # ---- NSIS 3.11 installer (win64-setup-unsigned.exe) ----------------------
  # package.sh runs build/GenerateWindowsInstaller.cmake → makensis. The
  # setup.exe = an NSIS STUB (the installer runtime) + the LZMA-solid-packed
  # payload. GUIX's make-nsis (installers.scm at pin c5eee3336cc1, nsis 3.11)
  # cross-compiles the stubs with its DEFAULT mingw cross toolchain:
  #   xgcc      (cross-gcc triplet #:libc xlibc) — %xgcc = gcc-14 (14.3.0),
  #             plain: none of bitcoin's gcc flags/patches, gcc's default
  #             (win32) thread model;
  #   xbinutils (cross-binutils triplet) — 2.44 + guix's patches, i.e.
  #             exactly mingwCrtBinutils241 above;
  #   xlibc     (cross-libc triplet) — mingw-w64 13.0.0 msvcrt, no
  #             winpthreads, built by the nolibc gcc-14 — i.e. mingwCrt.
  # (The v31 pin used gcc-11 + mingw-w64 12.0.0 here, which needed a whole
  # nixos-24.05 side-chain; that is gone.)
  nsisBintools = pkgsCrossMingw.stdenv.cc.bintools.override {
    bintools = mingwCrtBinutils241;
    libc = mingwCrt;
  };
  nsisGcc14 = stripMingwFpFlags (pkgsCrossMingw.stdenv.cc.override {
    bintools = nsisBintools;
    libc = mingwCrt;
    cc = (pkgsCrossMingw.buildPackages.gcc14.cc.override {
      libcCross = mingwCrt;
      threadsCross = { model = "win32"; package = null; };
    }).overrideAttrs (old: {
      # nixpkgs configures its cross gcc with --enable-default-pie; guix's
      # plain gcc-14 cross has no such default. A default-PIE mingw driver
      # passes -pie to ld implicitly, which gives the NSIS stub an .edata
      # export table + .reloc section upstream's stub lacks (every other
      # section was identical) — and shifts the whole installer payload.
      configureFlags = (builtins.filter (f: f != "--enable-default-pie") (old.configureFlags or [ ])) ++ [
        "--with-as=${mingwCrtBinutils241}/bin/${mingwTriple}-as"
        "--with-ld=${mingwCrtBinutils241}/bin/${mingwTriple}-ld"
      ];
    });
  });

  # Attr name kept (default.nix / flake outputs); it is NSIS 3.11 now.
  nsis310 = pkgs.callPackage ./nsis-toolchain.nix {
    nsisCC = nsisGcc14;
    mingwInclude = "${mingwCrt.dev}/include";
    mingwLib = "${mingwCrt}/lib";
    hostTriple = mingwTriple;
  };

  # ---- signed win64-setup.exe + win64.zip -----------------------------------
  # GUIX's osslsigncode is 2.5 (manifest.scm); nixpkgs ships 2.13. attach-
  # signature's PE-patching changed between versions, so pin the version for
  # byte-identical output.
  osslsigncode25 = pkgs.osslsigncode.overrideAttrs (old: {
    version = "2.5";
    src = pkgs.fetchFromGitHub {
      owner = "mtrojnar";
      repo = "osslsigncode";
      rev = "2.5";
      sha256 = "sha256-33uT9PFD1YEIMzifZkpbl2EAoC98IsM72K4rRjDfh8g=";
    };
    doCheck = false;
  });

  # The signed artifacts appear only in upstream's all.SHA256SUMS (not
  # the noncodesigned set) — their expected hashes come from that
  # checked-in file.
  signedMingw = pkgs.callPackage ./signed.nix {
    inherit version sourceDateEpoch detachedSigs;
    osslsigncode = osslsigncode25;
    codesigningTarball = codesigningMingw;
    expectedSetupSha256 = upstreamSha256 "bitcoin-${version}-win64-setup.exe";
    expectedZipSha256 = upstreamSha256 "bitcoin-${version}-win64.zip";
  };
in {
  inherit mingwGuixGcc mingwGuixGccNoFp mingwBinutils241 pkgsCrossMingw
    dependsMingw dependsNoQtMingw bitcoindMingwNoGui bitcoindMingwGui
    mingwCrtStdenv mingwCrt
    bitcoindMingw packagedMingw unsignedZipMingw debugZipMingw
    nsisGcc14 nsis310 setupExeMingw codesigningMingw
    osslsigncode25;
} // pkgs.lib.optionalAttrs (detachedSigs != null) {
  # Only wired up when there are detached signatures to apply — see the
  # detachedSigs note in default.nix.
  inherit signedMingw;
}
