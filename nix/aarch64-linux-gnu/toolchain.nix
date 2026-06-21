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
