{ pkgs, pkgs2405, version, url, sha256, buildSystem, sourceDateEpoch, detachedSigs, upstreamSha256 }:

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
  mingwCrtBinutils241 = mingwBootSet.stdenv.cc.bintools.bintools.overrideAttrs (old: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    patches = [ ];
    configureFlags =
      (builtins.filter (f: f != "--with-system-zlib") (old.configureFlags or [ ]))
      ++ [ "--enable-compressed-debug-sections=all" ];
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
        # Pin mingw-w64 to GUIX's 12.0.0 (nixpkgs ships 13.0.0). The CRT
        # (mingw_w64) and winpthreads (pthreads) both `inherit (mingw_w64_headers)
        # version src`, so overriding the headers cascades to all three.
        windows = prev.windows.overrideScope (wfinal: wprev: {
          mingw_w64_headers = wprev.mingw_w64_headers.overrideAttrs (o: {
            version = "12.0.0";
            src = pkgs.fetchurl {
              url = "mirror://sourceforge/mingw-w64/mingw-w64/mingw-w64-release/mingw-w64-v12.0.0.tar.bz2";
              hash = "sha256-zEGJiqxLbo3Vz/1zMbnZUVuRLfRCCjphK16ilVu+7S8=";
            };
          });
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
          mingwCrtDbgFlags = " -fdebug-prefix-map=/build/mingw-w64-v12.0.0="
            + "/tmp/guix-build-mingw-w64-x86_64-winpthreads-12.0.0.drv-0/mingw-w64-v12.0.0"
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
            let base = "/build/mingw-w64-v12.0.0/mingw-w64-headers";
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
    name = "mingw-w64-crt-with-winpthreads-12.0.0";
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
  mingwBinutils241 = pkgsCrossMingw.stdenv.cc.bintools.bintools.overrideAttrs (old: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    patches = [ ../patches/binutils-unaligned-default.patch ];
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
      builtins.filter (f: f != "--with-system-zlib") (old.configureFlags or [ ]);
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
        "--enable-host-bind-now=yes"
        "--disable-gcov"
        "--disable-libgomp"
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

  # win64 depends tree (Qt included; no X11 — Windows Qt). Package set
  # (depends packages.mk *_mingw32_packages): boost libevent qrencode qt
  # sqlite zeromq capnp + native_{capnp,libmultiprocess,qt}.
  dependsMingw = pkgs.callPackage ../lib/depends.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = mingwTriple;
    buildQt = true;
    crossInputs = mingwCrossInputs;
  };

  # Per-binary reference hashes are not published for v31.1 (upstream's
  # noncodesigned.SHA256SUMS covers only the assembled archives, gated
  # below); the release build prints the per-file hashes for the log.
  mingwExpectedHashes = { };
  bitcoindMingw = pkgs.callPackage ./release.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsMingw;
    crossInputs = mingwCrossInputsNoFp;
    guixGcc = mingwGuixGcc.cc;
    mingwCrt = mingwCrt;
    mingwPthreads = pkgsCrossMingw.windows.pthreads;
    hostTriple = mingwTriple;
    pname = "bitcoind-win64";
    expectedHashes = mingwExpectedHashes;
  };
  # Dev variant: skip the byte-match gate (empty expectedHashes) so the
  # binaries can be extracted and diffed against upstream during iteration.
  bitcoindMingwNoGate = bitcoindMingw.override { expectedHashes = { }; };

  # The published win64 .zip archives (build.sh mingw case).
  unsignedZipMingw = pkgs.callPackage ./zip.nix {
    inherit version url sha256 sourceDateEpoch;
    bitcoind = bitcoindMingw;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-unsigned.zip";
  };
  debugZipMingw = pkgs.callPackage ./zip.nix {
    inherit version url sha256 sourceDateEpoch;
    bitcoind = bitcoindMingw;
    debug = true;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-debug.zip";
  };

  # ---- NSIS 3.10 installer (win64-setup-unsigned.exe) ----------------------
  # GUIX builds the installer with `cmake --build build -t deploy` → makensis
  # (nsis-x86_64 3.10). The setup.exe = an NSIS STUB (the installer runtime,
  # ~98 KB) + the LZMA-solid-packed payload (the 7 stripped .exe we already
  # reproduce + COPYING/readme/conf/rpcauth + pixmaps). The stub is compiled
  # by GUIX's DEFAULT cross-gcc — `(cross-gcc "x86_64-w64-mingw32")` = %xgcc =
  # gcc-11 = 11.4.0 (its .comment reads "GCC: (GNU) 11.4.0"), NOT the bitcoin
  # base-gcc 14.3.0 — with the default cross-binutils (2.41) and cross-libc
  # (mingw-w64 12.0.0). 26.05 removed gcc11, so import it from 24.05 (whose
  # mingw cross binutils is already 2.41); pin only mingw-w64 → 12.0.0.
  #
  # The mingw-w64 headers 12.0.0 overlay (shared by the boot set + the main
  # import).
  nsisHeaders12Overlay = (final: prev: {
    windows = prev.windows.overrideScope (wfinal: wprev: {
      mingw_w64_headers = wprev.mingw_w64_headers.overrideAttrs (o: {
        version = "12.0.0";
        src = pkgs.fetchurl {
          url = "mirror://sourceforge/mingw-w64/mingw-w64/mingw-w64-release/mingw-w64-v12.0.0.tar.bz2";
          hash = "sha256-zEGJiqxLbo3Vz/1zMbnZUVuRLfRCCjphK16ilVu+7S8=";
        };
      });
    });
  });
  # A SEPARATE clean 24.05 mingw import (only the headers overlay) — the CRT
  # compiler comes from here so it can't form the splice cycle "the CRT's
  # stdenv uses gcc11 whose libcCross is the CRT" (same trick as mingwBootSet).
  nsisCrtBootSet = import pkgs2405.path {
    localSystem = buildSystem;
    crossSystem = { config = mingwTriple; libc = "msvcrt"; };
    config.allowUnsupportedSystem = true;
    overlays = [ nsisHeaders12Overlay ];
  };
  # gcc 11.4.0 cross stdenv for the CRT: NoFp-wrapped (GUIX's bare xgcc injects
  # no -fno-omit-frame-pointer); 12.0.0 headers come from the boot set's libc.
  nsisCrtStdenv = nsisCrtBootSet.overrideCC nsisCrtBootSet.stdenv
    (stripMingwFpFlags nsisCrtBootSet.buildPackages.gcc11);

  pkgsCrossMingwNsis = import pkgs2405.path {
    localSystem = buildSystem;
    crossSystem = { config = mingwTriple; libc = "msvcrt"; };
    config.allowUnsupportedSystem = true;
    overlays = [
      nsisHeaders12Overlay
      (final: prev: {
        windows = prev.windows.overrideScope (wfinal: wprev: {
          # GUIX's NSIS cross-libc is the mingw-w64 CRT built by the SAME xgcc
          # (gcc 11.4.0), so crt2.o / libmingw32 / libmingwex (linked into the
          # installer stub) carry "GCC 11.4.0". 24.05's default cross-gcc is
          # 13.2.0, which would stamp the stub with 13.2.0 and diverge. Rebuild
          # the CRT with the gcc-11.4.0 nsisCrtStdenv (from the boot set, no cycle)
          # + GUIX's bare-gcc hardening set (same as the bitcoin CRT).
          mingw_w64 = (wprev.mingw_w64.override {
            stdenv = nsisCrtStdenv;
          }).overrideAttrs (o: {
            # 24.05's mingw_w64 recipe only adds --with-default-msvcrt=ucrt
            # for libc=="ucrt"; for libc=="msvcrt" it adds NOTHING, relying
            # on mingw-w64's OWN configure default — which 12.0.0 flipped to
            # UCRT. Add 26.05's equivalent flags by hand (crt=msvcrt,
            # x86_64 lib64-only) so the NSIS plugin DLLs (System.dll etc.)
            # link against msvcrt.dll like GUIX's gcc-11 CRT, not UCRT.
            configureFlags = (o.configureFlags or [ ]) ++ [
              "--with-default-msvcrt=msvcrt"
              "--disable-lib32"
              "--enable-lib64"
              "--disable-libarm64"
              "ac_cv_prog_cc_c23=no"
            ];
            # 24.05's hardening set (no stackclashprotection/strictflexarrays1).
            hardeningDisable = (o.hardeningDisable or [ ]) ++ [
              "zerocallusedregs" "strictoverflow" "stackprotector"
              "fortify" "fortify3" "format"
            ];
          });
        });
      })
    ];
  };
  # The gcc 11.4.0 mingw cross, NoFp-wrapped: GUIX's vanilla cross-gcc doesn't
  # inject nixpkgs' -fno-omit-frame-pointer, so strip it (x86_64 -O2 omits FP).
  nsisGcc11 = stripMingwFpFlags pkgsCrossMingwNsis.buildPackages.gcc11;

  nsis310 = pkgs.callPackage ./nsis-toolchain.nix {
    nsisCC = nsisGcc11;
    mingwInclude = "${pkgsCrossMingwNsis.windows.mingw_w64.dev}/include";
    mingwLib = "${pkgsCrossMingwNsis.windows.mingw_w64}/lib";
    hostTriple = mingwTriple;
    # nsisCC's wrapper scripts + bash are nixos-24.05 (glibc 2.39); LD_PRELOADing
    # 26.05's libfaketime (glibc 2.42) into them fails with a GLIBC_ABI_DT_X86_64_PLT
    # version mismatch. Use 24.05's libfaketime for ABI compatibility.
    libfaketime = pkgs2405.libfaketime;
  };

  setupExeMingw = pkgs.callPackage ./setup.nix {
    inherit version url sha256 sourceDateEpoch mingwBinutils241;
    inherit (pkgs) libfaketime;
    bitcoind = bitcoindMingw;
    nsis = nsis310;
    hostTriple = mingwTriple;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-setup-unsigned.exe";
  };

  # ---- win64-codesigning.tar.gz ---------------------------------------------
  codesigningMingw = pkgs.callPackage ./codesigning.nix {
    inherit version url sha256 sourceDateEpoch;
    bitcoind = bitcoindMingw;
    setupExe = setupExeMingw;
    expectedSha256 = upstreamSha256 "bitcoin-${version}-win64-codesigning.tar.gz";
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
  # published yet) — their expected hashes resolve to null and the gate
  # is skipped until that file is checked in.
  signedMingw = pkgs.callPackage ./signed.nix {
    inherit version sourceDateEpoch detachedSigs;
    osslsigncode = osslsigncode25;
    codesigningTarball = codesigningMingw;
    expectedSetupSha256 = upstreamSha256 "bitcoin-${version}-win64-setup.exe";
    expectedZipSha256 = upstreamSha256 "bitcoin-${version}-win64.zip";
  };
in {
  inherit mingwGuixGcc mingwGuixGccNoFp mingwBinutils241 pkgsCrossMingw dependsMingw
    mingwCrtStdenv mingwCrt
    bitcoindMingw bitcoindMingwNoGate unsignedZipMingw debugZipMingw
    nsisGcc11 nsis310 setupExeMingw codesigningMingw
    osslsigncode25 signedMingw
    pkgsCrossMingwNsis nsisCrtBootSet nsisCrtStdenv;
}
