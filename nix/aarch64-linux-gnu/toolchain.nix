{ pkgs, version, url, sha256, buildSystem }:

let
  # --- aarch64 cross-compile ---
  # nixpkgs instantiated to cross-compile buildSystem -> aarch64-linux-gnu.
  # We use the GUIX target triple `aarch64-linux-gnu` (not nixpkgs' default
  # `aarch64-unknown-linux-gnu`) so the cross compiler is named
  # `aarch64-linux-gnu-gcc`, which is what Bitcoin's depends Makefile
  # invokes for HOST packages. (On an aarch64-linux build host this is a
  # cross-to-self, the exact mirror of pkgsCrossX86 on x86_64.)
  #
  # On an aarch64-linux build host (the trivial cross), gcc's own build
  # system sees build == target after config.sub canonicalization (both
  # `aarch64-linux-gnu` and the build-host's `aarch64-unknown-linux-gnu`
  # collapse to the same internal triple) and tries to run fixincludes
  # against /usr/include — absent in the Nix sandbox → `stmp-fixinc` fails
  # in the BOOTSTRAP `aarch64-linux-gnu-nolibc-gcc`. The overlay below
  # appends `--disable-fixincludes` to *only* `gccWithoutTargetLibc` —
  # the cross-stage-static nolibc gcc 15.2, which is configured with
  # `--without-headers` and therefore has no `--with-native-system-header-dir`
  # to redirect fixinc.sh away from /usr/include. The libc-aware cross
  # gccs (the gcc 15.2 nixpkgs builds after the nolibc one, and our
  # gcc 14.3.0 `crossGuixGcc` built with `libcCross = crossGlibc231`)
  # both DO set `--with-native-system-header-dir` to a valid store path,
  # so fixinc.sh finds real headers and succeeds — they don't need the
  # flag. Scoping the override to just the nolibc one keeps the hash of
  # build-host stdenv components (gcc15, gcc14, the cc-wrappers, the
  # stdenv chain itself) unchanged, so `nix build` can substitute them
  # from cache.nixos.org instead of rebuilding native helpers like patch
  # — one of whose 49 tests deterministically fails when rebuilt on
  # aarch64 runners. Gated to aarch64-linux build hosts: on x86_64-linux
  # the overlay is empty, so every drv hash on the routinely-exercised
  # x86 path stays identical.
  fixincludesOverlay = final: prev: {
    gccWithoutTargetLibc = prev.gccWithoutTargetLibc.override (old: {
      cc = old.cc.overrideAttrs (oldCC: {
        configureFlags = (oldCC.configureFlags or [ ]) ++ [ "--disable-fixincludes" ];
        # Second trivial-cross collision: gcc/configure.ac (gcc-15.2 lines
        # 2577-2582) only flips `inhibit_libc=true` when host != target OR
        # newlib. After config.sub canonicalizes both build-host and target
        # to `aarch64-unknown-linux-gnu`, host == target → inhibit_libc
        # stays false even with `--without-headers`. Result:
        # INHIBIT_LIBC_CFLAGS comes out empty, libgcc2.c compiles tsystem.h
        # without `-Dinhibit_libc`, and the `#include <stdio.h>` at
        # tsystem.h:95 fails (no /usr/include in sandbox). Force the flag
        # whenever `--without-headers` was passed. Patches configure.ac
        # because nixpkgs' preConfigure runs `autoconf -f` over every
        # `*/configure.ac` (regenerating gcc/configure from the .ac);
        # sedding gcc/configure directly would be overwritten.
        postPatch = (oldCC.postPatch or "") + ''
          sed -i '/^: \''${inhibit_libc=false}$/a if test "x$with_headers" = xno; then inhibit_libc=true; fi' gcc/configure.ac
        '';
        # Third trivial-cross collision: gcc thinks build == target after
        # canonicalization → installs libgcc_s.so* via the native libdir
        # (which lands in `$out/lib/` after `preInstall`'s `lib64 -> lib`
        # compatibility symlink resolves) instead of the cross-style
        # `$out/aarch64-linux-gnu/lib/`. nixpkgs' postInstall
        # (`moveToOutput "$targetLibDir/lib*.so*" ...`) +
        # preFixupLibGccPhase (`mv $lib/aarch64-linux-gnu/lib/libgcc_s.so
        # ...`) both assume the cross layout because `targetConfig` is
        # set, so they don't find the files and fail. Reshuffle BEFORE
        # nixpkgs' postInstall runs: move the two target shared libs
        # `libgcc_s.so` / `libgcc_s.so.1` (which postInstall's
        # `moveToOutput "$targetLibDir/lib*.so*"` and the libgcc
        # preFixupLibGccPhase glob for) from the native `$out/lib/` to
        # the cross `$out/aarch64-linux-gnu/lib/`. libgcc.a is already at
        # the cross-style `lib/gcc/<target>/<ver>/` location via gcc's
        # normal install — only the .so* needs moving. Do NOT touch the
        # `$out/lib64 -> lib` compatibility symlinks; nixpkgs' own
        # postInstall removes those.
        postInstall = ''
          if [ -f "$out/lib/libgcc_s.so.1" ] && [ ! -e "$out/aarch64-linux-gnu/lib/libgcc_s.so.1" ]; then
            mkdir -p "$out/aarch64-linux-gnu/lib"
            mv "$out/lib/libgcc_s.so" "$out/lib/libgcc_s.so.1" "$out/aarch64-linux-gnu/lib/"
          fi
        '' + (oldCC.postInstall or "");
      });
    });
    # Fourth trivial-cross collision: TOP-level `configure.ac:2743-2747`
    # bails with `*** --with-headers is only supported when cross
    # compiling` + `exit 1` when `is_cross_compiler = no` (build == host
    # == target post config.sub canonicalization). Tripped by nixpkgs'
    # cc-wrapper for ANY cross gcc whose libc is set to a separate
    # store path (i.e., every cross gcc) — both the base nixpkgs cross
    # gcc14 (used by `crossGlibc231`'s `gcc14Stdenv`) and our
    # `crossGuixGcc` (= `gcc14Aarch64NoFpCC.override { libcCross =
    # crossGlibc231 }`). Delete the `exit 1` only; the warning stays.
    # The copy-headers logic below runs and target headers land in
    # `$tooldir/sys-include` like cross compiles expect. Apply via
    # overlay only to gcc14 (NOT gcc15 — overriding gcc15 polluted the
    # build-host gcc-15.2 stdenv, triggering a multi-hour rebuild of
    # the whole world from source under qemu). The top-level
    # configure.ac is NOT auto-regen'd by nixpkgs' preConfigure (which
    # only autoreconfs `*/configure.ac`), so the sed on configure is
    # sufficient — we patch both for safety.
    gcc14 = prev.gcc14.override (old: {
      cc = old.cc.overrideAttrs (oldCC: {
        # Sixth trivial-cross collision: libstdc++.so* + libgcc_s.so*
        # install to `$out/lib/` (gcc's normal cross install assumes
        # `--enable-shared` puts target runtime in `$out/$target/lib`
        # via `$(target_alias)/lib/`, but on trivial-cross the make
        # logic shortcuts target == host and uses `$out/lib`). nixpkgs'
        # gcc postInstall does `moveToOutput "$targetConfig/lib/lib*.so*"
        # $lib` — since the .so files are NOT under that path,
        # nothing moves and `$lib/aarch64-linux-gnu/lib/` ends up
        # empty. cc-wrapper's link search dir = `$lib/lib/` (or
        # `$lib/$target/lib`); boost's `aarch64-linux-gnu-ld` then
        # fails: `cannot find -lstdc++ / -lgcc_s`. Reshuffle .so*
        # ONLY (the static archives are at `lib/gcc/<target>/<ver>/`
        # already) so nixpkgs' moveToOutput picks them up next.
        #
        # GATE on derivation name: the overlay also applies to the
        # build-host native gcc14 (`pkgsCrossAarch64.buildPackages.gcc14`,
        # name `gcc-14.3.0` without triple prefix); for native gcc the
        # move would displace libstdc++.so* to a nonexistent triple
        # subdir AND break nixpkgs' standard postInstall (which then
        # can't find libstdc++-gdb.py next to the .so to patch its
        # paths).
        #
        # Also pre-create empty `$out/lib/pkgconfig/` and a stub
        # `.pc` so nixpkgs' `_multioutDevs` sed loop in
        # `multiple-outputs.sh:176` (`for f in $dev/lib/pkgconfig/*.pc;
        # do sed -i ... $f; done` — no nullglob) doesn't iterate over
        # the literal glob and run sed against a nonexistent file.
        # Without fix #6 in place the same loop runs but the build
        # tolerates its failure (sed's nonzero exit is apparently
        # swallowed somewhere); with fix #6 it isn't tolerated.
        # Simpler than reasoning about the exact tolerance change:
        # ensure the glob always matches.
        postInstall = ''
          case "$(basename $out)" in *aarch64-linux-gnu-gcc-*)
            if [ -d "$out/lib" ] && [ ! -e "$out/aarch64-linux-gnu/lib/libstdc++.so" ]; then
              mkdir -p "$out/aarch64-linux-gnu/lib"
              shopt -s nullglob
              # Shared runtime (cc-wrapper / boost-style dynamic links)
              for f in "$out/lib/"libstdc++.so* "$out/lib/"libgcc_s.so*; do
                mv "$f" "$out/aarch64-linux-gnu/lib/"
              done
              # Static archives (bitcoind's CMake uses
              # `-static-libstdc++ -static-libgcc`; cross ld then
              # needs libstdc++.a / libsupc++.a / libstdc++fs.a /
              # libstdc++exp.a at the cross subdir too)
              for f in "$out/lib/"libstdc++*.a "$out/lib/"libsupc++.a; do
                mv "$f" "$out/aarch64-linux-gnu/lib/"
              done
              shopt -u nullglob
            fi
            # Stub a `.pc` in BOTH lib/pkgconfig and share/pkgconfig
            # — the `_multioutDevs` sed loop iterates both subdirs
            # (`$dev/{lib,share}/pkgconfig/*.pc`). Stub names MUST NOT
            # begin with `.` (bash glob `*.pc` skips dotfiles).
            for d in "$out/lib/pkgconfig" "$out/share/pkgconfig"; do
              mkdir -p "$d"
              : > "$d/gcc-trivial-cross-stub.pc"
            done
          ;; esac
        '' + (oldCC.postInstall or "");
        postPatch = (oldCC.postPatch or "") + ''
          sed -i '/echo 1>&2.*--with-headers is only supported when cross compiling/{n;/^[[:space:]]*exit 1$/d}' configure configure.ac
          # Fifth trivial-cross collision: gcc/configure.ac:2526-2533
          # only sets `CROSS=-DCROSS_DIRECTORY_STRUCTURE` when host !=
          # target (canonical). With CROSS unset, gcc/cppdefault.cc:31-36
          # `#undef CROSS_INCLUDE_DIR`s → gcc's preprocessor search list
          # NEVER includes `$(prefix)/$(target_alias)/sys-include/`
          # (where --with-headers' copy-dirs landed glibc headers).
          # cc-wrapper's `-idirafter $libcCross/include` then provides
          # them instead → DWARF .debug_line_str records the un-mapped
          # `$libcCross/include/{sys,bits,bits/types}` paths instead of
          # the prefix-mapped `$guixGcc/aarch64-linux-gnu/sys-include`
          # → `/usr/include`. Inject a fallback that sets CROSS when
          # --with-headers is given, without touching ALL or
          # SYSTEM_HEADER_DIR — broadening the original `if` would
          # also force `ALL=all.cross`, which skips lang.all.cross's
          # target libstdc++ build path that the wrapper later expects
          # to find when linking C++ depends like boost. Append after
          # the closing `fi` of the existing host!=target gate.
          sed -i '/^    SYSTEM_HEADER_DIR='"'"'\$(CROSS_SYSTEM_HEADER_DIR)'"'"'$/,/^  fi$/{
          /^  fi$/a\
            if test x"''${with_headers}" != x && test x"''${with_headers}" != xno && test -z "$CROSS"; then CROSS="-DCROSS_DIRECTORY_STRUCTURE"; fi
          }' gcc/configure.ac
        '';
      });
    });
  };
  pkgsCrossAarch64 = import pkgs.path {
    localSystem = buildSystem;
    crossSystem = { config = "aarch64-linux-gnu"; };
    overlays = pkgs.lib.optionals (buildSystem == "aarch64-linux") [ fixincludesOverlay ];
  };

  # Kernel headers pinned to GUIX's 6.1.119 for the aarch64 target — same
  # reasoning as linuxHeaders61 below (the headers VERSION leaks into the
  # .dbg via <linux/rtnetlink.h> enum DIEs).
  linuxHeaders61Aarch64 = import ../lib/linux-headers-61.nix { inherit pkgs; pkgsCross = pkgsCrossAarch64; };

  # Stock cross gcc14 wrapper used as crossGlibc231's forced CC — the
  # aarch64 analog of gcc14X86NoFp below (see its comment for the full
  # reasoning: glibc's statically-linked members carry debug info whose
  # DW_AT_producer must record NO explicit flags, like upstream's).
  # aarch64 delta: --enable-standard-branch-protection=yes is baked in
  # (GUIX's linux-base-gcc — the base-gcc-for-libc that builds their
  # glibc — has it; it makes the PAC/BTI codegen a compiler DEFAULT, so
  # the previously explicit -mbranch-protection=standard, which would be
  # recorded in DW_AT_producer, is dropped). --with-as/--with-ld point at
  # cross binutils 2.41: gas GENERATES the .debug_line programs (and
  # assembles glibc's .S CUs entirely); 2.46's encoding diverges.
  # --with-arch=armv8-a (nixpkgs' platform default) is FILTERED OUT: a
  # configured --with-arch makes the gcc DRIVER self-inject
  # `-march=armv8-a` into every cc1 command line (OPTION_DEFAULT_SPECS),
  # and cc1 records it in DW_AT_producer — upstream's GUIX gcc has no
  # --with-arch and records no -march. armv8-a is the aarch64 compiler
  # baseline either way, so codegen is identical (gates verify).
  gcc14Aarch64NoFpCC = pkgsCrossAarch64.buildPackages.gcc14.cc.overrideAttrs (o: {
    configureFlags = (builtins.filter (f: f != "--with-arch=armv8-a") (o.configureFlags or [ ])) ++ [
      "--enable-default-pie=yes"
      "--enable-standard-branch-protection=yes"
      "--with-as=${crossBinutils241}/bin/aarch64-linux-gnu-as"
      "--with-ld=${crossBinutils241}/bin/aarch64-linux-gnu-ld"
    ];
    # Fourth trivial-cross collision (aarch64-linux build host only):
    # TOP-level `configure.ac:2743-2747` bails with
    # `*** --with-headers is only supported when cross compiling` +
    # `exit 1` when `is_cross_compiler = no` (build == host == target
    # post config.sub canonicalization). Tripped by our cc-wrapper
    # passing `--with-headers=<crossGlibc231>/include`. Delete the
    # `exit 1`; the copy-headers logic below runs and target headers
    # land in $tooldir/sys-include like cross expects. Duplicated by the
    # gcc14-overlay above (which covers the base nixpkgs cross gcc14
    # used by crossGlibc231's gcc14Stdenv); sed is idempotent (second
    # invocation finds nothing to delete). Gated to aarch64-linux build
    # host so x86 drv hashes are byte-identical.
    postPatch = (o.postPatch or "") + pkgs.lib.optionalString (buildSystem == "aarch64-linux") ''
      sed -i '/echo 1>&2.*--with-headers is only supported when cross compiling/{n;/^[[:space:]]*exit 1$/d}' configure configure.ac
    '';
  });
  gcc14Aarch64NoFp = (pkgsCrossAarch64.buildPackages.gcc14.override {
    cc = gcc14Aarch64NoFpCC;
  }).overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      substituteInPlace $out/nix-support/cc-cflags-before \
        --replace-fail "-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer" "" \
        --replace-fail "-march=armv8-a" ""
    '';
  });

  # aarch64 cross glibc 2.31 — GUIX git source, no patches, GUIX configure
  # flags, frame-pointer handling, postPatch/postInstall fixes for 2.31
  # (the same override set as crossGlibc231X86 below, with the aarch64
  # deltas noted inline). Pointing the cross cc-wrapper's libc at this
  # makes all cross compiles use glibc 2.31 headers/CRTs (vs nixpkgs 2.40)
  # — the .text (inline functions) + dynsym/version gap driver.
  # NOTE: --enable-cet is x86-only and omitted.
  # Built with the gcc-14 cross stdenv (nixos-26.05's default is gcc 15.2.0;
  # the glibc CRT/nonshared members linked into the binaries must be
  # gcc-14-compiled to match upstream's codegen).
  crossGlibc231 = (pkgsCrossAarch64.glibc.override {
    stdenv = pkgsCrossAarch64.gcc14Stdenv;
    linuxHeaders = linuxHeaders61Aarch64;
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
        # No -fpie in upstream's csu/crt DW_AT_producer — see
        # crossGlibc231X86. The codegen stays PIE because the forced CC is
        # default-PIE (gcc14Aarch64NoFpCC).
        "--disable-static-pie"
      ];
    # NO explicit codegen flags (upstream's glibc DW_AT_producer records
    # bare `-g -O2`): the aarch64 -O2 default keeps the non-leaf frame
    # pointer and omits the leaf one — exactly what the previously explicit
    # -momit-leaf-frame-pointer reproduced against the wrapper's
    # -fno-omit-frame-pointer injection; the forced CC below is the NoFp
    # wrapper so nothing injects FP flags. Branch protection (PAC/BTI in
    # the csu/nonshared members) comes from the forced CC's baked
    # --enable-standard-branch-protection (replacing the previously
    # explicit -mbranch-protection=standard). Same codegen, clean producer.
    # The prefix maps mirror crossGlibc231X86's (GUIX's ephemeral
    # glibc-cross-aarch64 build dir for DW_AT_comp_dir; /usr spellings for
    # the forced CC's internal headers + the kernel headers).
    env = (old.env or { }) // {
      NIX_CFLAGS_COMPILE = "-fdebug-prefix-map=/build/glibc-2.31=/tmp/guix-build-glibc-cross-aarch64-linux-gnu-2.31.drv-0/source"
        + " -ffile-prefix-map=${gcc14Aarch64NoFpCC}/lib/gcc=/usr/lib/gcc"
        + " -ffile-prefix-map=${linuxHeaders61Aarch64}/include=/usr/include";
      # Skip glibc's C++ link test — the cross build stdenv's libstdc++ is
      # gcc 15's, built against a modern glibc, and won't link against the
      # 2.31 being built. C++ is test-only; the installed glibc is pure C.
      libc_cv_cxx_link_ok = "no";
    };
    # Keep the debug info — glibc's statically-linked members' DWARF flows
    # into the .dbg files; see crossGlibc231X86's note (nixpkgs'
    # separateDebugInfo hook would add a recorded -ggdb and strip the
    # members).
    separateDebugInfo = false;
    dontStrip = true;
    # Force the cross C compiler to gcc 14.3.0 (GUIX's version). glibc is a
    # stdenv bootstrap component, so `.override { stdenv = … }` is ignored
    # — on nixos-26.05 the cross glibc would otherwise build with the
    # bootstrap cross gcc 15.2.0, giving __libc_csu_init the gcc-15
    # register allocation (diverges from upstream's gcc-14 codegen). Force
    # CC only (not CXX — forcing CXX breaks glibc's cstdlib/cmath
    # generation; the shipped glibc is all C). Through the NoFp wrapper
    # variant (gcc14Aarch64NoFp above). Also drop the
    # -frandom-seed=<out-hash> appended by nixpkgs' reproducible-builds
    # hook — it would be recorded in DW_AT_producer.
    preConfigure = (old.preConfigure or "") + ''
      export CC=${gcc14Aarch64NoFp}/bin/aarch64-linux-gnu-gcc
      export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')
    '';
    makeFlags = (old.makeFlags or [ ]) ++ [
      "CC=${gcc14Aarch64NoFp}/bin/aarch64-linux-gnu-gcc"
    ];
    # Disable the same nixpkgs hardenings crossGlibc231X86 drops.
    # The decisive one is zerocallusedregs (-fzero-call-used-regs): it
    # appends register-zeroing before `ret` in glibc's nonshared members
    # (__libc_csu_init/fini), which upstream lacks — our csu objects were
    # coming out ~28/8 bytes larger without this.
    hardeningDisable = [
      "zerocallusedregs" "strictoverflow" "stackprotector"
      "stackclashprotection" "fortify" "fortify3"
      # New nixos-26.05 cross cc-wrapper defaults GUIX doesn't apply (see
      # nix/x86_64-linux-gnu/release.nix). strictflexarrays1 is codegen-affecting;
      # libcxxhardeningfast is libc++-only (no-op for us).
      "strictflexarrays1" "libcxxhardeningfast"
      # "pic": see crossGlibc231X86 — the wrapper's default -fPIC injection
      # breaks glibc's pie-default detection and would be recorded in
      # DW_AT_producer where glibc passes no own pic/pie flag.
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
      # Keep the static libs in $out/lib next to the shared ones, like
      # GUIX's glibc — see crossGlibc231X86's note (`-static` links, e.g.
      # Qt's configure-time feature probes, must find -lc/-lm). The
      # $static output remains declared but empty.
      mkdir -p $static/lib
      cp $bin/bin/getconf $bin/bin/getconf_
      mv $bin/bin/getconf_ $bin/bin/getconf
    '';
  });

  # Downgrade the aarch64 cross binutils to GUIX's 2.41 (nixpkgs cross
  # ships 2.44; 2.44 relaxes aarch64 more aggressively → smaller
  # .text/.eh_frame than upstream). Override the *build-host* cross
  # binutils (the one that runs on x86_64 and targets aarch64) —
  # `stdenv.cc.bintools.bintools`, NOT `binutils-unwrapped` (which is the
  # aarch64-native binutils and can't run on the build machine). Same
  # override as crossBinutils241X86.
  crossBinutils241 = import ../lib/cross-binutils-241.nix { inherit pkgs; pkgsCross = pkgsCrossAarch64; };
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
  # *targeting* glibc 2.31. Setting the cc-wrapper/bintools `libc` to 2.31
  # alone broke linking (gcc/libgcc still built against 2.40 startfiles);
  # rebuilding gcc against 2.31 fixes that coherently, without the overlay
  # approach's breakage (overlaying glibc hit the x86_64 *build* glibc too).
  # This closes the remaining gap: 2.31 headers (inline functions → .text /
  # .eh_frame) + 2.31 dynsym/symbol versions.
  # NB: base the compiler on `buildPackages.gcc14`, not `gcc14` or
  # `stdenv.cc.cc`. nixos-26.05's default cross gcc is 15.2.0; we need GUIX's
  # 14.3.0. Critically, `pkgsCrossAarch64.gcc14.cc` resolves to the
  # aarch64-NATIVE gcc (an ARM binary that can't run on the x86 build host) on
  # 26.05 — wrapping it makes the cc-wrapper setup-hook put that native gcc's
  # bin (with its UNPREFIXED `gcc`/`g++`) on the build PATH, where it shadows
  # the depends build's native compiler and breaks native_qt's CMake compiler
  # check ("ELF: not found"). `buildPackages.gcc14.cc` is the build→target
  # cross gcc (runs on x86, prefix-only binaries), which is what we want. The
  # cc-wrapper (stdenv.cc) only contributes version-independent flags
  # (-march=armv8-a, the frame-pointer defaults), so overriding its `cc` is
  # enough. (On nixos-25.11 the splice happened to give the cross gcc, so
  # plain `gcc14.cc` worked there.)
  crossGuixGcc = pkgsCrossAarch64.stdenv.cc.override {
    bintools = crossBintools241;
    libc = crossGlibc231;
    cc = (pkgsCrossAarch64.buildPackages.gcc14.cc.override {
      libcCross = crossGlibc231;
    }).overrideAttrs (old: {
      # --with-arch filtered out — see gcc14Aarch64NoFpCC: the configured
      # default makes the driver inject a recorded -march=armv8-a into
      # every compile (bitcoind's CUs included); GUIX's gcc has none.
      configureFlags = (builtins.filter (f: f != "--with-arch=armv8-a") (old.configureFlags or [ ])) ++ [
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
        # Re-point the baked --with-as/--with-ld at cross binutils 2.41
        # (nixpkgs bakes the 2.46 wrapper; a second --with-as appended
        # later wins). On aarch64 this is debug-only — gas generates the
        # .debug_line programs and 2.46's encoding diverges; the code
        # bytes never depended on gas here (fixed-width instructions, no
        # NOP-fill choice — see crossGuixGccX86 for the x86 story).
        "--with-as=${crossBinutils241}/bin/aarch64-linux-gnu-as"
        "--with-ld=${crossBinutils241}/bin/aarch64-linux-gnu-ld"
      ];
      patches = (old.patches or [ ]) ++ [ ../patches/gcc-ssa-generation.patch ];
      # Debug info for libgcc with upstream's exact DW_AT_producer
      # `-g -g -g -O2 -O2 -O2` + GUIX's ephemeral gcc build dir for
      # DW_AT_comp_dir — the aarch64 analog of crossGuixGccX86's preBuild
      # (see its comment for the compile-line model that puts -g in
      # CFLAGS_FOR_TARGET only and strips -O2 from FLAGS_FOR_TARGET).
      # No -Wa,-mrelax-relocations here: GOTPCRELX is x86-only.
      # -march=armv8-a is stripped from EXTRA_FLAGS_FOR_TARGET: nixpkgs
      # puts the platform arch there, so it lands in every libgcc CU's
      # DW_AT_producer — upstream's gcc build passes no -march (armv8-a IS
      # the aarch64 baseline default; codegen-identical, the 10-hash gate
      # verifies). The kernel-headers map covers libgcc's unwind-dw2.c:
      # its <asm/…>/<asm-generic/…> includes resolve through the glibc-dev
      # include SYMLINKS, which gcc canonicalizes to the linux-headers
      # store path — so the glibc-dev map alone misses them (x86's
      # unwind-dw2-fde-dip only needed <elf.h>, a real glibc-dev file).
      preBuild = (old.preBuild or "") + ''
        EXTRA_FLAGS_FOR_TARGET="''${EXTRA_FLAGS_FOR_TARGET/-march=armv8-a /}"
        EXTRA_SANS_O2="''${EXTRA_FLAGS_FOR_TARGET/-O2 /}"
        GUIXMAPS="-fdebug-prefix-map=/build/build=/tmp/guix-build-gcc-cross-aarch64-linux-gnu-14.3.0.drv-0/build -ffile-prefix-map=${pkgs.lib.getDev crossGlibc231}/include=/usr/include -ffile-prefix-map=${linuxHeaders61Aarch64}/include=/usr/include"
        makeFlagsArray+=(
          "CFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS -g"
          "CXXFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS"
          "FLAGS_FOR_TARGET=$EXTRA_SANS_O2 $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS"
        )
      '';
      # Keep libgcc's objects unstripped (their CUs ship in upstream's
      # .dbg) but strip libstdc++/libsupc++ — upstream has no CUs from
      # them (libsupc++'s C members would otherwise leak cp-demangle.c).
      dontStrip = true;
      postFixup = (old.postFixup or "") + ''
        find $out -name 'libstdc++*.a' -o -name 'libsupc++*.a' | while read -r f; do
          ${crossBinutils241}/bin/aarch64-linux-gnu-objcopy \
            --enable-deterministic-archives --strip-debug "$f"
        done
      '';
    });
  };

  # aarch64 cross toolchain inputs: the GUIX-flags cross gcc wrapper
  # (provides aarch64-linux-gnu-gcc/g++ + gcc-ar/-nm/-ranlib) and its
  # bintools (aarch64-linux-gnu-ar/-strip/-objcopy/…).
  aarch64CrossInputs = [
    crossGuixGcc
    crossGuixGcc.bintools
  ];

  # Wrapper variant for the bitcoind compile that does NOT inject
  # `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` — the aarch64
  # analog of crossGuixGccX86NoFp (see its comment). With the injection
  # gone, the aarch64 -O2 default applies: keep the non-leaf frame
  # pointer, omit the leaf one — exactly what the previously explicit
  # -momit-leaf-frame-pointer achieved, but with upstream's clean
  # DW_AT_producer (bare `-O2 -g`). depends keeps the regular wrapper.
  # (also strips the wrapper's -march=armv8-a injection — recorded in
  # every CU's DW_AT_producer; upstream compiles with no -march, and
  # armv8-a is the compiler default anyway).
  crossGuixGccNoFp = crossGuixGcc.overrideAttrs (old: {
    postFixup = (old.postFixup or "") + ''
      substituteInPlace $out/nix-support/cc-cflags-before \
        --replace-fail "-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer" "" \
        --replace-fail "-march=armv8-a" ""
    '';
  });
  aarch64CrossInputsNoFp = [
    crossGuixGccNoFp
    crossGuixGccNoFp.bintools
  ];

  # Cross-build the full depends tree (incl. the Qt6 GUI tree) with a *native*
  # build stdenv (so the native helper tools — native_capnp, mpgen, native_qt
  # — use the build machine's gcc) plus the aarch64 cross toolchain on PATH
  # (so HOST packages use aarch64-linux-gnu-gcc). Uses the GUIX-flags cross
  # gcc + binutils 2.41, rebuilt against glibc 2.31 (crossGlibc231 via
  # libcCross above) — which makes all 10 cross-built binaries byte-match the
  # upstream aarch64 release (the dynsym GLIBC symbol versions, .text/.eh_frame
  # all line up; see CLAUDE.md's aarch64 section).
  dependsAarch64 = pkgs.callPackage ../lib/depends.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "aarch64-linux-gnu";
    buildQt = true;
    crossInputs = aarch64CrossInputs;
  };
  bitcoindAarch64 = pkgs.callPackage ./release.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsAarch64;
    crossInputs = aarch64CrossInputsNoFp;
    guixGcc = crossGuixGcc.cc;
    linuxHeaders = linuxHeaders61Aarch64;
  };
  tarballAarch64 = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindAarch64;
    arch = "aarch64-linux-gnu";
    expectedSha256 = "4de1d568dedd48604f75132421bc0abeca432639589b49a3909c81db3a813112";
  };
  # The separate aarch64 -debug.tar.gz with the ten .dbg files —
  # reproducible since 2026-06-11 (byte-identical .dbg, same recipe as
  # x86_64's; see nix/aarch64-linux-gnu/release.nix).
  debugTarballAarch64 = pkgs.callPackage ../lib/tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindAarch64;
    arch = "aarch64-linux-gnu";
    debug = true;
    expectedSha256 = "91917647aaf50965fc834e048256fce17e8f5590658c7e8de2879fb66cdc9a73";
  };

in {
  inherit dependsAarch64 bitcoindAarch64 tarballAarch64 debugTarballAarch64
    crossGlibc231 crossGuixGcc crossGuixGccNoFp;
}
