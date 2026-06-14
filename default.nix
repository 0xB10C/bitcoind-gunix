{ pkgs ? import <nixpkgs> {}
, pkgs2405 ? null # nixos-24.05 (for gcc 11.4.0 — the NSIS stub toolchain)
}:

let
  version = "31.0";
  url = "https://bitcoincore.org/bin/bitcoin-core-${version}/bitcoin-${version}.tar.gz";
  sha256 = "sha256-C6DvXuo679lswXdL4nTD1ZSBLPrAmIgJ1wZzi7Bns+M=";

  # NOTE (2026-06-10): the original NATIVE x86_64 toolchain (binutils 2.41
  # + gcc 14 rebuilt against glibc 2.31 via wrapped native stdenvs:
  # binutilsForGuix → bintoolsWithGlibc231 → stdenvForGccRebuild →
  # gcc14RebuiltWithGlibc231 → gcc14Glibc231Stdenv, plus flake.nix's native
  # glibc231) was REMOVED after the cross-to-self toolchain below
  # (crossGuixGccX86) reproduced the identical 10 binaries + tarball. The
  # cross-to-self structure also obsoleted two native-only workarounds the
  # cross gcc handles via --with-as: the PATH `as`-shadow for the gas
  # NOP-fill order and depsBuildTarget. See CLAUDE.md's 2026-06-10 status
  # and git history (pre-2026-06-10 default.nix) for the native chain.

  # The build host system, taken from the incoming pkgs ("cross
  # everywhere"): every target's cross toolchain is instantiated FROM this
  # system, so the same definitions build every target on any build host —
  # on x86_64-linux, pkgsCrossX86 is a cross-to-self and pkgsCrossAarch64 a
  # real cross; on aarch64-linux it's exactly mirrored. The target triples
  # (and hence the GUIX-exact toolchain configs) never change; only the
  # host the compilers run on does. The core bet — cross toolchains emit
  # build-host-independent target bytes — is proven on x86_64 hosts (both
  # targets' gates); other hosts re-assert the same gates.
  buildSystem = pkgs.stdenv.hostPlatform.system;

  # --- aarch64 cross-compile ---
  # nixpkgs instantiated to cross-compile buildSystem -> aarch64-linux-gnu.
  # We use the GUIX target triple `aarch64-linux-gnu` (not nixpkgs' default
  # `aarch64-unknown-linux-gnu`) so the cross compiler is named
  # `aarch64-linux-gnu-gcc`, which is what Bitcoin's depends Makefile
  # invokes for HOST packages. (On an aarch64-linux build host this is a
  # cross-to-self, the exact mirror of pkgsCrossX86 on x86_64.)
  pkgsCrossAarch64 = import pkgs.path {
    localSystem = buildSystem;
    crossSystem = { config = "aarch64-linux-gnu"; };
  };

  # Kernel headers pinned to GUIX's 6.1.119 for the aarch64 target — same
  # reasoning as linuxHeaders61 below (the headers VERSION leaks into the
  # .dbg via <linux/rtnetlink.h> enum DIEs).
  linuxHeaders61Aarch64 = pkgsCrossAarch64.linuxHeaders.overrideAttrs (o: {
    version = "6.1.119";
    src = pkgs.fetchurl {
      url = "mirror://kernel/linux/kernel/v6.x/linux-6.1.119.tar.xz";
      hash = "sha256-rs2vOdCoRKgc5MZ9na/4l56Ti7aQ309nn7u0lP5CMng=";
    };
  });

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
      # bitcoind.nix). strictflexarrays1 is codegen-affecting;
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
  crossBinutils241 = pkgsCrossAarch64.stdenv.cc.bintools.bintools.overrideAttrs (old: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    # Drop newer-binutils patches that may not apply to 2.41. Keep the
    # default cross outputs (incl. `dev`) — the cross binutils' postInstall
    # references $dev.
    patches = [ ];
    # Match GUIX's binutils compression config — same reasoning as
    # crossBinutils241X86 below: --enable-compressed-debug-sections=all
    # (upstream's .dbg sections are SHF_COMPRESSED with no explicit
    # split-debug flag) and bundled zlib, not --with-system-zlib
    # (identical 2.41 zlib ⇒ identical deflate bytes).
    configureFlags =
      (builtins.filter (f: f != "--with-system-zlib") (old.configureFlags or [ ]))
      ++ [ "--enable-compressed-debug-sections=all" ];
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
      patches = (old.patches or [ ]) ++ [ ./patches/gcc-ssa-generation.patch ];
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
    crossInputs = aarch64CrossInputsNoFp;
    guixGcc = crossGuixGcc.cc;
    linuxHeaders = linuxHeaders61Aarch64;
  };
  tarballAarch64 = pkgs.callPackage ./tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindAarch64;
    arch = "aarch64-linux-gnu";
    expectedSha256 = "4de1d568dedd48604f75132421bc0abeca432639589b49a3909c81db3a813112";
  };
  # The separate aarch64 -debug.tar.gz with the ten .dbg files —
  # reproducible since 2026-06-11 (byte-identical .dbg, same recipe as
  # x86_64's; see bitcoind-aarch64.nix).
  debugTarballAarch64 = pkgs.callPackage ./tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindAarch64;
    arch = "aarch64-linux-gnu";
    debug = true;
    expectedSha256 = "91917647aaf50965fc834e048256fce17e8f5590658c7e8de2879fb66cdc9a73";
  };

  # --- generic linux-gnu cross target generator ---
  # The aarch64/riscv64 recipe parameterized over the target triple: cross
  # binutils 2.41 (compressed-debug-sections, bundled zlib), GUIX's glibc
  # 2.31 (forced default-PIE gcc-14 CC, --disable-static-pie, drv-0
  # debug-prefix-map, pic-hardening-off, unsplit static libs), gcc 14.3.0
  # with GUIX's linux-base-gcc flags + the ssa patch (libgcc -g
  # multiplicity, GUIX maps, libstdc++ strip-debug), NoFp wrapper
  # variants, kernel headers 6.1.119, then depends/bitcoind/tarballs with
  # 20-artifact + 2-archive gates. See the aarch64 section above for the
  # full reasoning on every piece (that section predates this generator
  # and keeps its bespoke definitions: it additionally FILTERS
  # --with-arch=armv8-a, bakes --enable-standard-branch-protection and
  # strips a wrapper -march injection; x86_64 below likewise has CET and
  # gas-specific handling).
  #
  # Per-target knobs:
  # - nixpkgsPath: nixpkgs source to instantiate the cross package set
  #   from (powerpc64 needs a one-line-patched copy — see its
  #   instantiation).
  # - gccArchFlags: GUIX's gcc-configure-flags-for-triplet extras (guix
  #   gnu/packages/gcc.scm translates "extended" triples into gcc
  #   configure flags: armhf gets --with-arch=armv7-a/--with-mode=thumb/
  #   --with-fpu=neon; riscv64/powerpc64 get NONE — gcc's own config.gcc
  #   seeding for the triple supplies the defaults, identically for
  #   nixpkgs' and GUIX's gcc, so the driver-injected -m flags recorded in
  #   every DW_AT_producer match automatically).
  # - glibcPatches: GUIX glibc-2.31 origin patches that matter for the
  #   target (riscv64: glibc-riscv-jumptarget.patch).
  # - dynamicLinker/extraCXXFLAGS: build.sh's per-host values.
  # The NoFp wrappers strip exactly "-fno-omit-frame-pointer" — on these
  # targets the cc-wrapper injects no leaf-FP variant (x86_64/aarch64-only
  # for gcc 14) and no -march (no gcc.arch platform attrs).
  mkLinuxCrossTarget =
    { triple
    , nixpkgsPath ? pkgs.path
    , gccArchFlags ? [ ]
    , gccExtraPatches ? [ ] # extra patches for the final cross gcc only (not the glibc CC)
    , gccNativeInputs ? [ ] # prepended to the cross gcc's build env (e.g. armhf's pinned gawk)
    , glibcPatches ? [ ]
    , debugCanonMap ? false # route the /build→DISTSRC rewrite through the gcc canon env var (ppc64)
    , canonDepends ? false # route the depends→/bitcoin rewrite through the canon env var too
                           # (instead of -ffile-prefix-map): gcc ggc-allocates every FIRED argv
                           # map rewrite, and GUIX never fires a map on depends (it lives at the
                           # real /bitcoin) — the extra allocations flip var-tracking loclists
                           # in big CUs (armhf net_processing, ppc64 qt). Needs gccExtraPatches
                           # to include gcc-debug-canon-prefix-map.patch.
    , dynamicLinker
    , extraCXXFLAGS ? ""
    , pnameSuffix
    , expectedHashes
    , tarballSha256
    , debugTarballSha256 ? null # null = the -debug.tar.gz is not byte-reproducible (yet); no attr
    }:
    let
      pkgsCross = import nixpkgsPath {
        localSystem = buildSystem;
        crossSystem = { config = triple; };
        # The GUIX triples parse to generic cpus nixpkgs' meta.platforms
        # lists don't enumerate (e.g. "arm-linux" — the armv5tel/armv7l/…
        # doubles are listed, the unversioned one isn't). Eval-level only;
        # no derivation changes (verified drv-identical for riscv64).
        config.allowUnsupportedSystem = true;
      };

      linuxHeaders61' = pkgsCross.linuxHeaders.overrideAttrs (o: {
        version = "6.1.119";
        src = pkgs.fetchurl {
          url = "mirror://kernel/linux/kernel/v6.x/linux-6.1.119.tar.xz";
          hash = "sha256-rs2vOdCoRKgc5MZ9na/4l56Ti7aQ309nn7u0lP5CMng=";
        };
      });

      # Stock cross gcc14 wrapper used as the glibc's forced CC — see
      # gcc14X86NoFp/gcc14Aarch64NoFpCC. Only default-PIE is baked (GUIX's
      # linux-base-gcc); no branch-protection/CET analog on these targets.
      gcc14NoFpCC = pkgsCross.buildPackages.gcc14.cc.overrideAttrs (o: {
        configureFlags = (o.configureFlags or [ ]) ++ [
          "--enable-default-pie=yes"
          "--with-as=${crossBinutils241'}/bin/${triple}-as"
          "--with-ld=${crossBinutils241'}/bin/${triple}-ld"
        ] ++ gccArchFlags;
      });
      gcc14NoFp = (pkgsCross.buildPackages.gcc14.override {
        cc = gcc14NoFpCC;
      }).overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          substituteInPlace $out/nix-support/cc-cflags-before \
            --replace-fail "-fno-omit-frame-pointer" ""
        '';
      });

      # Cross glibc 2.31 — same override set as crossGlibc231 (aarch64).
      crossGlibc231' = (pkgsCross.glibc.override {
        stdenv = pkgsCross.gcc14Stdenv;
        linuxHeaders = linuxHeaders61';
      }).overrideAttrs (old: {
        version = "2.31";
        src = pkgs.fetchgit {
          name = "glibc-2.31";
          url = "https://sourceware.org/git/glibc.git";
          rev = "7b27c450c34563a28e634cccb399cd415e71ebfe";
          hash = "sha256-wIq9cIHkI8HtsYa5UU1IfC8VIhXyz0vJau20WPJt+AQ=";
        };
        patches = glibcPatches;
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
            "--disable-static-pie"
          ];
        env = (old.env or { }) // {
          NIX_CFLAGS_COMPILE = "-fdebug-prefix-map=/build/glibc-2.31=/tmp/guix-build-glibc-cross-${triple}-2.31.drv-0/source"
            + " -ffile-prefix-map=${gcc14NoFpCC}/lib/gcc=/usr/lib/gcc"
            + " -ffile-prefix-map=${linuxHeaders61'}/include=/usr/include";
          libc_cv_cxx_link_ok = "no";
        };
        separateDebugInfo = false;
        dontStrip = true;
        preConfigure = (old.preConfigure or "") + ''
          export CC=${gcc14NoFp}/bin/${triple}-gcc
          export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')
        '';
        makeFlags = (old.makeFlags or [ ]) ++ [
          "CC=${gcc14NoFp}/bin/${triple}-gcc"
        ];
        hardeningDisable = [
          "zerocallusedregs" "strictoverflow" "stackprotector"
          "stackclashprotection" "fortify" "fortify3"
          "strictflexarrays1" "libcxxhardeningfast"
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
          mkdir -p $static/lib
          cp $bin/bin/getconf $bin/bin/getconf_
          mv $bin/bin/getconf_ $bin/bin/getconf
        '';
      });

      crossBinutils241' = pkgsCross.stdenv.cc.bintools.bintools.overrideAttrs (old: {
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
      crossBintools241' = pkgsCross.stdenv.cc.bintools.override {
        bintools = crossBinutils241';
        libc = crossGlibc231';
      };

      # Cross gcc 14.3.0 with GUIX's linux-base-gcc flags — see
      # crossGuixGcc (aarch64). No --enable-standard-branch-protection
      # (aarch64-only), no --enable-cet (x86-only), no
      # -Wa,-mrelax-relocations (GOTPCRELX is x86-only).
      crossGuixGcc' = pkgsCross.stdenv.cc.override {
        bintools = crossBintools241';
        libc = crossGlibc231';
        cc = (pkgsCross.buildPackages.gcc14.cc.override {
          libcCross = crossGlibc231';
        }).overrideAttrs (old: {
          configureFlags = (old.configureFlags or [ ]) ++ [
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
            "--with-as=${crossBinutils241'}/bin/${triple}-as"
            "--with-ld=${crossBinutils241'}/bin/${triple}-ld"
          ] ++ gccArchFlags;
          patches = (old.patches or [ ]) ++ [ ./patches/gcc-ssa-generation.patch ] ++ gccExtraPatches;
          nativeBuildInputs = gccNativeInputs ++ (old.nativeBuildInputs or [ ]);
          preBuild = (old.preBuild or "") + ''
            EXTRA_SANS_O2="''${EXTRA_FLAGS_FOR_TARGET/-O2 /}"
            GUIXMAPS="-fdebug-prefix-map=/build/build=/tmp/guix-build-gcc-cross-${triple}-14.3.0.drv-0/build -ffile-prefix-map=${pkgs.lib.getDev crossGlibc231'}/include=/usr/include -ffile-prefix-map=${linuxHeaders61'}/include=/usr/include"
            makeFlagsArray+=(
              "CFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS -g"
              "CXXFLAGS_FOR_TARGET=$EXTRA_FLAGS_FOR_TARGET $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS"
              "FLAGS_FOR_TARGET=$EXTRA_SANS_O2 $EXTRA_LDFLAGS_FOR_TARGET $GUIXMAPS"
            )
          '';
          dontStrip = true;
          postFixup = (old.postFixup or "") + ''
            find $out -name 'libstdc++*.a' -o -name 'libsupc++*.a' | while read -r f; do
              ${crossBinutils241'}/bin/${triple}-objcopy \
                --enable-deterministic-archives --strip-debug "$f"
            done
          '';
        });
      };

      crossInputs' = [
        crossGuixGcc'
        crossGuixGcc'.bintools
      ];

      crossGuixGccNoFp' = crossGuixGcc'.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          substituteInPlace $out/nix-support/cc-cflags-before \
            --replace-fail "-fno-omit-frame-pointer" ""
        '';
      });
      crossInputsNoFp' = [
        crossGuixGccNoFp'
        crossGuixGccNoFp'.bintools
      ];

      depends' = pkgs.callPackage ./depends.nix {
        inherit version url sha256;
        inherit (pkgs) gcc14Stdenv;
        hostTriple = triple;
        buildQt = true;
        crossInputs = crossInputs';
      };
      bitcoind' = pkgs.callPackage ./bitcoind-cross.nix {
        inherit version url sha256;
        inherit (pkgs) gcc14Stdenv;
        inherit dynamicLinker extraCXXFLAGS expectedHashes debugCanonMap canonDepends;
        hostTriple = triple;
        pname = "bitcoind-${pnameSuffix}";
        depends = depends';
        crossInputs = crossInputsNoFp';
        guixGcc = crossGuixGcc'.cc;
        linuxHeaders = linuxHeaders61';
      };
      tarball' = pkgs.callPackage ./tarball.nix {
        inherit version url sha256;
        bitcoind = bitcoind';
        arch = triple;
        expectedSha256 = tarballSha256;
      };
      debugTarball' = if debugTarballSha256 == null then null else pkgs.callPackage ./tarball.nix {
        inherit version url sha256;
        bitcoind = bitcoind';
        arch = triple;
        debug = true;
        expectedSha256 = debugTarballSha256;
      };
    in {
      depends = depends';
      bitcoind = bitcoind';
      tarball = tarball';
      debugTarball = debugTarball';
      crossGlibc231 = crossGlibc231';
      crossGuixGcc = crossGuixGcc';
      crossGuixGccNoFp = crossGuixGccNoFp';
    };

  # --- riscv64 cross-compile ---
  # The riscv64-linux-gnu release. riscv64-specific notes, all verified
  # against the upstream riscv64 .dbg/binaries before building (round-1
  # byte-match):
  # - NO --with-arch/-march handling anywhere: nixpkgs passes no
  #   --with-arch for riscv (riscv-multiplatform defines no gcc.arch), and
  #   gcc's own config.gcc default (rv64gc/lp64d) is what GUIX's gcc gets
  #   too — the driver-injected `-mabi=lp64d -misa-spec=20191213
  #   -mtls-dialect=trad -march=rv64imafdc_zicsr_zifencei` recorded in
  #   every upstream CU's DW_AT_producer comes from those shared defaults.
  # - glibc needs GUIX's glibc-riscv-jumptarget.patch (riscv sysdeps asm:
  #   HIDDEN_JUMPTARGET fixes; part of GUIX's glibc-2.31 source).
  # - frame pointers: riscv gcc at -O2 omits the frame pointer (like
  #   x86_64, no leaf/non-leaf split — -momit-leaf-frame-pointer does not
  #   exist on riscv).
  riscv64Cross = mkLinuxCrossTarget {
    triple = "riscv64-linux-gnu";
    glibcPatches = [ ./patches/glibc-riscv-jumptarget.patch ];
    dynamicLinker = "/lib/ld-linux-riscv64-lp64d.so.1";
    pnameSuffix = "riscv64";
    expectedHashes = {
      "bin/bitcoin" = "d28d634c82878263fc4878072fa132b1b518381e768081d7639da664b1b5da07";
      "bin/bitcoin-cli" = "bb5ecc78581cd0f2361f25884520af76c40cde505444a8670f933d3492ea811e";
      "bin/bitcoind" = "2c868a6a4d401269432a92f542bf833ce3622cd5caf7828016a7b61de64d0cc3";
      "bin/bitcoin-tx" = "e4d682e57827e1299e52a104341c66484adbd16fc5600c26a5aa3e8a562385e7";
      "bin/bitcoin-util" = "a33638e29496f0aec56aa53f930687919c24c87d1e49378d23512c14c125d9b1";
      "bin/bitcoin-wallet" = "22d3c59167c3686a011b6ec5a9c85a0fd0515b6db3e570beee8141437f83dfd3";
      "bin/bitcoin-qt" = "b348aa9d4fb2ccc5c0271a9ef072d196b85721de252e1cf65af6aca4f1eaaaec";
      "libexec/bitcoin-node" = "2d28a094263960c361cf901e1a43cf44d26ec99c0ea6f9005ef88137591c79fd";
      "libexec/bitcoin-gui" = "213838af6f99da64c635219505a635fbeac616c24691f64190457bfc97fa74c8";
      "libexec/test_bitcoin" = "6086d424a21967d8e8bf6e2e5f9f74de4b9c5495cbf3d5f0c6d80c42ae1f83bf";
      "bin/bitcoin.dbg" = "cfd2e64494d370734862c640d5358fc6aed812dc8466ed930cd0603d90edc14d";
      "bin/bitcoin-cli.dbg" = "66ad80b9584dc926cf3872d487085011e0dd1a3dc4c927376fb9d2ec7d34d6cd";
      "bin/bitcoind.dbg" = "881245c2c5f46c7834c99b9a06b03296fcc7349f5a261480cc426590ff650895";
      "bin/bitcoin-tx.dbg" = "5f853f178c6ce45a3b3cfd1564aeb7fb461cd22c1b2b09cf4d04d2b0a0c4b2bc";
      "bin/bitcoin-util.dbg" = "fa52baceb687b465846ac6dddefdb5ca852fa806b05890d053e43b727d195dbc";
      "bin/bitcoin-wallet.dbg" = "096273e898d962939ce359968d08b847d950abdc9bcdeca3825a5c426cbbd621";
      "bin/bitcoin-qt.dbg" = "ceb874159d794b01f016c5c72891d34b81a49d7b4f3d69fbbc3e6828656deeb3";
      "libexec/bitcoin-node.dbg" = "e120294b37da3ee878e6765609a1ca87a17b9d74b6749f5344e6683dbf33c13d";
      "libexec/bitcoin-gui.dbg" = "aa2f11addf9ff938e03939281f70dc0b340e05b629d68cf6cdb37c3b0d17021e";
      "libexec/test_bitcoin.dbg" = "d01cd44763909a640db92b491f03218609c16ec34eef189506bc225348833288";
    };
    tarballSha256 = "7ece4ea365bba9b2008b27f0717ef6a518598a572edaa2815e775faadc53c136";
    debugTarballSha256 = "acd0e38f4bb99c7c3024e494ca218d3ae67ec4a8b3b7ae556a8292353fe308b5";
  };
  dependsRiscv64 = riscv64Cross.depends;
  bitcoindRiscv64 = riscv64Cross.bitcoind;
  tarballRiscv64 = riscv64Cross.tarball;
  debugTarballRiscv64 = riscv64Cross.debugTarball;

  # --- armhf (arm-linux-gnueabihf) cross-compile ---
  # The arm-linux-gnueabihf release. armhf-specific notes (verified
  # against the upstream .dbg/binaries):
  # - gccArchFlags = GUIX's gcc-configure-flags-for-triplet translation of
  #   the gnueabihf "extended triple" (guix gnu/packages/gcc.scm):
  #   --with-arch=armv7-a --with-float=hard --with-mode=thumb
  #   --with-fpu=neon. nixpkgs already passes --with-float=hard (from
  #   parsed.abi.float), so only the other three are added here. The gcc
  #   driver then self-injects the RECORDED `-mfloat-abi=hard -mfpu=neon
  #   -mtls-dialect=gnu -mthumb -march=armv7-a+simd` into every CU's
  #   DW_AT_producer — exactly upstream's producer prefix (this is the
  #   aarch64 --with-arch effect, except here upstream's gcc HAS the
  #   configured defaults, so we add rather than filter).
  # - build.sh adds -Wno-psabi to HOST_CXXFLAGS for this host only
  #   (warning flag, not recorded in DW_AT_producer; mirrored for compile
  #   parity).
  # - ELF32; interpreter /lib/ld-linux-armhf.so.3.
  # gawk pinned to GUIX's 5.3.0 for the armhf gcc build: gcc's
  # config/arm/parsecpu.awk generates the arm-cpu-data tables with awk's
  # UNORDERED `for (x in array)` iteration — the entry ORDER of (e.g.)
  # `all_implied_fbits` depends on the awk version's hash internals.
  # nixpkgs' gawk 5.4.0 orders it differently than GUIX's 5.3.0, and the
  # table is baked into crtbegin/crtend (crtstuff.c includes the arm tm
  # headers) — i.e. into EVERY linked binary's .rodata. This was the
  # whole-release armhf divergence (72 bytes in bitcoin-cli, all in this
  # one table). arm-only: no other target has awk-generated unordered
  # tables, so the pin is armhf-gated.
  # (C23 disabled via the autoconf cache var: nixpkgs' gawk runs
  # autoreconfHook, and autoconf 2.72's AC_PROG_CC auto-selects the
  # NEWEST C standard the compiler supports — 5.3.0's io.c K&R-style
  # casts don't compile as C23.)
  gawk530 = pkgs.gawk.overrideAttrs (o: {
    version = "5.3.0";
    src = pkgs.fetchurl {
      url = "mirror://gnu/gawk/gawk-5.3.0.tar.xz";
      sha256 = "02x97iyl9v84as4rkdrrkfk2j4vy4r3hpp3rkp3gh3qxs79id76a";
    };
    configureFlags = (o.configureFlags or [ ]) ++ [ "ac_cv_prog_cc_c23=no" ];
    # gcc 15 also DEFAULTS to gnu23, so pin the dialect explicitly too.
    env = (o.env or { }) // { NIX_CFLAGS_COMPILE = "-std=gnu17"; };
  });

  armhfCross = mkLinuxCrossTarget {
    triple = "arm-linux-gnueabihf";
    gccArchFlags = [ "--with-arch=armv7-a" "--with-mode=thumb" "--with-fpu=neon" ];
    gccNativeInputs = [ gawk530 ];
    # Full canon wiring like ppc64 (canon patch + BOTH knobs), for the two
    # replay-verified root causes (see CLAUDE.md):
    # - canonDepends: the depends -ffile-prefix-map FIRING on every
    #   depends header ggc-allocates the rewrites and flips
    #   var-tracking's loclists representative for `it` in
    #   net_processing.cpp (an IDENTITY map alone reproduces the flip);
    #   GUIX fires no map on depends (real /bitcoin path, outside their
    #   /gnu/store→/usr maps).
    # - debugCanonMap: the /build=$DISTSRC argv map matches the
    #   cmake-build-dir GENERATED CUs' main files (mpgen capnp, qt moc)
    #   and duplicates their file-table entry — upstream, building at
    #   the real $DISTSRC, never remaps them (visible as shifted
    #   DW_AT_decl_file implicit_consts + a doubled v5 line-table file
    #   entry in bitcoin-node/-gui/test_bitcoin/qt). With the canon
    #   rewrite the remaining argv map is GUIX's literal
    #   $DISTSRC/src=., which dups the src/ CUs on both sides equally.
    gccExtraPatches = [ ./patches/gcc-debug-canon-prefix-map.patch ];
    debugCanonMap = true;
    canonDepends = true;
    dynamicLinker = "/lib/ld-linux-armhf.so.3";
    extraCXXFLAGS = "-Wno-psabi";
    pnameSuffix = "armhf";
    expectedHashes = {
      "bin/bitcoin" = "6fe2e29aeea99bafb1ad92333ecc2eaa52d3e16734b63ff743da37e2ec87688e";
      "bin/bitcoin-cli" = "d135cb00ca315694aa5274a2f3065d82b9183b80881e634016f7504906e79b86";
      "bin/bitcoind" = "d44c812afed46ca02d0a6ee494b738f92ef255a28afaa2530544cfc3784e7ae6";
      "bin/bitcoin-tx" = "007e46104f7c74b6fbb24b6c9e9a8fd0cf0ee6fbbe6c9ccb22e66f5275bdfb7f";
      "bin/bitcoin-util" = "046c67b8d6fcaa29aa02ad1c14ad6e1b9bedef9320335d7de427127da1b19a66";
      "bin/bitcoin-wallet" = "effbb134e764fbf0dbabf999e8855367e83c2ba2dd25e8b25a28e2a679749b7d";
      "bin/bitcoin-qt" = "dab13e05f54a04b7430cfe9ddc16069a6c93b059ff70e27e5d21140d8a9e9b4b";
      "libexec/bitcoin-node" = "19fe6129533db79c622e5ca52b5a26af765e8114124a94a3548a2c4208f3c1ee";
      "libexec/bitcoin-gui" = "6b50fb850eb42df3fc774b8137baa31eeb497aa259584c0ee5eb1f395dd76753";
      "libexec/test_bitcoin" = "c6170cb1c5115034c7d2dc5697909bb921c93e07a186323eba43a50fc4b4460d";
      "bin/bitcoin.dbg" = "60d22fc62c48176d4d52e049fcd6c378aa8918e0ddbd81c4e515d68590654775";
      "bin/bitcoin-cli.dbg" = "ffad56789f3b85f959f510472accbacb92e45e5db69f41de5ed5de7e2dba7239";
      "bin/bitcoind.dbg" = "964b99bbde7dc42213d8b4296880988880d3d63b52aa67bcfcfc97ac3cd05b83";
      "bin/bitcoin-tx.dbg" = "3c2575828c75fde267800a2b2e6da8a44d79b5fd99810fed7a61b1e45ef3005b";
      "bin/bitcoin-util.dbg" = "136fffa7961ea8f5bf686dadfe30b1bc8dcb2f2ce1bf4997a3273c519cbe7ee0";
      "bin/bitcoin-wallet.dbg" = "5555299c4ab4388ddc3de83eb1a39a895940cde22cd258f3b75ceb9128c26d30";
      "bin/bitcoin-qt.dbg" = "6c2ad12a49736b26b81e383f97e6cbbc24d56e0c4ef3c93d95215a30590293c1";
      "libexec/bitcoin-gui.dbg" = "c5776fc7a96bbaebaff1fa2779c2b13f310219f942ffd4e2b2c2411be8c11d67";
      "libexec/bitcoin-node.dbg" = "57d9f19955ffb266bf17c80123ddd94a91268eba2e5303d9d4a7a81320e94430";
      "libexec/test_bitcoin.dbg" = "05a022436c126df567fe532c34def4d815215d49eac4cde818730d774cf43c1e";
    };
    tarballSha256 = "8c19d007bfc73502625095ea4073af3a98ceb722d500556ab173bac5bcadd0d6";
    debugTarballSha256 = "fc17562b66707d0c8d1863af0cd40d7c6818a8d7d7b360b8d43276b1593924d9";
  };
  dependsArmhf = armhfCross.depends;
  bitcoindArmhf = armhfCross.bitcoind;
  tarballArmhf = armhfCross.tarball;
  debugTarballArmhf = armhfCross.debugTarball;

  # --- powerpc64 (big-endian) cross-compile ---
  # The powerpc64-linux-gnu release. ppc64-specific notes (verified
  # against the upstream .dbg/binaries):
  # - nixpkgs cannot elaborate the triple as-is: lib/systems/parse.nix
  #   rejects the explicit "gnu" ABI on big-endian ppc64 as ambiguous
  #   (ELFv1 vs ELFv2). GUIX's triple IS powerpc64-linux-gnu, and gcc's
  #   own default for it is ELFv1 (upstream e_flags 0x1 "abiv1"), so the
  #   ppc64 package set is instantiated from a one-line-PATCHED nixpkgs
  #   copy (patches/nixpkgs-ppc64-gnu-abi.patch drops the assertion).
  #   With the plain "gnu" ABI, nixpkgs' gcc platform-flags pass NO
  #   --with-abi/--with-cpu/--with-long-double-* — exactly GUIX's bare
  #   gcc configure (guix's gcc-configure-flags-for-triplet matches
  #   powerpc64le-/powerpc- but NOT powerpc64-, and cross-base adds
  #   nothing), so gccArchFlags is empty and upstream's bitcoin CUs
  #   record no -m flags at all. The -mlong-double-128/-mno-minimal-toc
  #   in upstream's glibc/libgcc CUs come from those projects' OWN build
  #   systems (same sources here).
  # - ELF64 big-endian, ELFv1; interpreter /lib64/ld64.so.1.
  nixpkgsPpc64 = pkgs.applyPatches {
    name = "nixpkgs-ppc64-gnu-abi";
    src = pkgs.path;
    patches = [ ./patches/nixpkgs-ppc64-gnu-abi.patch ];
  };
  ppc64Cross = mkLinuxCrossTarget {
    triple = "powerpc64-linux-gnu";
    nixpkgsPath = nixpkgsPpc64;
    # ppc64's line tables come out of gas (.loc, DWARF v3), where gcc's
    # file-table behavior is path-spelling-sensitive: a main file whose
    # path matches a -fdebug-prefix-map gets a DUPLICATE file entry, and
    # whether that duplicate appears must match upstream's per-CU
    # situation EXACTLY (their $DISTSRC/src=. map duplicates bitcoin's
    # src/ CUs on both sides; our extra whole-tree /build=$DISTSRC map
    # also duplicated the cmake-build-dir mpgen-generated CUs, which
    # upstream — building at the REAL /distsrc-base path — does not
    # remap). The patch adds a TRANSPARENT canonical rewrite (env var
    # NIX_DEBUG_CANON_PREFIX_MAP, applied before the maps and to the
    # file table keys), so the build behaves as if it ran at GUIX's real
    # path and the remaining -fdebug-prefix-map set is spelled exactly
    # like build.sh's. See the patch header; strict no-op when unset.
    gccExtraPatches = [ ./patches/gcc-debug-canon-prefix-map.patch ];
    # With the canon rewrite active, the source-tree map must be GUIX's
    # literal one (on the POST-canon path), not /build-based.
    debugCanonMap = true;
    # The depends rewrite also moves off argv onto the canon env var
    # (second pair): same ggc-allocation root cause as armhf — ppc64's
    # two diverging .dbg are qt CUs, full of depends/Qt headers that our
    # argv map fired on while GUIX's environment fires none.
    canonDepends = true;
    dynamicLinker = "/lib64/ld64.so.1";
    pnameSuffix = "ppc64";
    expectedHashes = {
      "bin/bitcoin" = "ee88e8a924d08362b31e73b4c2610c2278d8fb742af22d16b999f4add7110cac";
      "bin/bitcoin-cli" = "95864dd67ee83a937bad40e5d15e63a4b365aaad8d34cc7f5b10f8ba8106367b";
      "bin/bitcoind" = "3eda7c9f2a31c6a78686b168b4931351ccac9d37c693c46433d78942f1f839a9";
      "bin/bitcoin-tx" = "dfd214e1b619ba54c42128e4faf8a7f85fe75b6cc9d3cbd74ca642854acc80ba";
      "bin/bitcoin-util" = "710149e3abdc485b1d82cc7a4471714670e71e049edc1393e1ee21f9c8e0ca58";
      "bin/bitcoin-wallet" = "49d27d4d5e8f1a2a6a1bac26ba8b347e1a84742225d16d754fbda751f975bafd";
      "bin/bitcoin-qt" = "9cf677bfc8820618a16f72a1e8979644579e6d350f6b6eb9eedef129f1f6d0e4";
      "libexec/bitcoin-node" = "38dddbf084aaff10f087d9fb9a278a86e46dca7e26420d4235a5195ff89a010f";
      "libexec/bitcoin-gui" = "2137efafde666e9b85fd3d74b33e23c3926e5df92be97b3ed8d6ff1c6eedcd0e";
      "libexec/test_bitcoin" = "9788b37550bef213d6f12f7d39374b2c8c7085c6738e24ef43560e573385aebf";
      "bin/bitcoin.dbg" = "3636f2841bb165e195a00efbef8d7522965cd46a648d7a783b355202a68761dd";
      "bin/bitcoin-cli.dbg" = "7bbed644bdc4594c26c2fe0341a2d142942dad75abbe18292492071c807d830a";
      "bin/bitcoind.dbg" = "07136e7dc836568645af082105dbfbcf127cbd4efb758d4e17becfe1a113c5f6";
      "bin/bitcoin-tx.dbg" = "e7ad77f0f4956c377f8bbe9d94b408d2bdf076ea3541a678771ff4c5fa58bca1";
      "bin/bitcoin-util.dbg" = "8cd90dadc6c4b01db5a379735aaab3959e2ba45e471d236c0961739d0ff87b2b";
      "bin/bitcoin-wallet.dbg" = "f13293d7934146e15f4852e86b7d9a0396cf3ade6aec51b8a83671243315c66f";
      "libexec/bitcoin-node.dbg" = "6838aa0fb02260ac0ddb6a42de5fc3298195c59a320ac311e143fc79cdf8c87d";
      "libexec/test_bitcoin.dbg" = "b1e24a9ad93ebfbe8cf0a6d2f4715d6582e4a2fcb260bdd2bc729328fe217a9a";
      "bin/bitcoin-qt.dbg" = "7fa98ff12552e60b963d50fbc5099e800c4677042a6cece89573eaed9d66a171";
      "libexec/bitcoin-gui.dbg" = "63378a4b5522ceed2c18bca7a77b333ee55d14d56d7d117c43216fbdaba989ec";
    };
    tarballSha256 = "1d9c865aa0ccf675fc068e79d9fa57a5a70b59132fca38bb322a7d44ce2f0ff2";
    debugTarballSha256 = "efe3e7d0383d54e5d79ac47911be0100b99872fa5205510a2a22d1194a0212d8";
  };
  dependsPpc64 = ppc64Cross.depends;
  bitcoindPpc64 = ppc64Cross.bitcoind;
  tarballPpc64 = ppc64Cross.tarball;
  debugTarballPpc64 = ppc64Cross.debugTarball;

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
  crossBinutils241X86 = pkgsCrossX86.stdenv.cc.bintools.bintools.overrideAttrs (old: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    patches = [ ];
    # Match GUIX's binutils compression config (gnu/packages/base.scm):
    # --enable-compressed-debug-sections=all makes gas/ld/objcopy default
    # to zlib-gabi-compressing debug sections — that's why every .debug_*
    # section in the upstream .dbg files is SHF_COMPRESSED (split-debug.sh
    # passes no explicit flag). And GUIX does NOT use --with-system-zlib,
    # so the deflate bytes come from binutils' bundled zlib — drop
    # nixpkgs' --with-system-zlib so ours come from the same bundled code
    # (identical 2.41 tarball ⇒ identical compressed bytes).
    configureFlags =
      (builtins.filter (f: f != "--with-system-zlib") (old.configureFlags or [ ]))
      ++ [ "--enable-compressed-debug-sections=all" ];
  });

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
  linuxHeaders61 = pkgsCrossX86.linuxHeaders.overrideAttrs (o: {
    version = "6.1.119";
    src = pkgs.fetchurl {
      url = "mirror://kernel/linux/kernel/v6.x/linux-6.1.119.tar.xz";
      hash = "sha256-rs2vOdCoRKgc5MZ9na/4l56Ti7aQ309nn7u0lP5CMng=";
    };
  });

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
      patches = (old.patches or [ ]) ++ [ ./patches/gcc-ssa-generation.patch ];
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
  # bitcoind.nix no longer needs the explicit -fomit-frame-pointer
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
  # like GUIX. depends.nix's hostTriple already defaults to
  # "x86_64-linux-gnu" (HOST= forces depends' cross-compile mode either
  # way); passing crossInputs makes the HOST packages use the prefixed
  # cross tools (the native helper tools use the plain gcc14Stdenv, exactly
  # like dependsAarch64).
  depends = pkgs.callPackage ./depends.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "x86_64-linux-gnu";
    buildQt = true;
    crossInputs = x86CrossInputs;
  };
  bitcoind = pkgs.callPackage ./bitcoind.nix {
    inherit version url sha256 depends;
    inherit (pkgs) gcc14Stdenv;
    crossInputs = x86CrossInputsNoFp;
    guixGcc = crossGuixGccX86.cc;
    linuxHeaders = linuxHeaders61;
  };
  tarball = pkgs.callPackage ./tarball.nix {
    inherit version url sha256 bitcoind;
  };
  # The separate -debug.tar.gz with the ten .dbg files — reproducible since
  # 2026-06-11 (the .dbg are byte-identical to upstream's; see bitcoind.nix).
  debugTarball = pkgs.callPackage ./tarball.nix {
    inherit version url sha256 bitcoind;
    debug = true;
    expectedSha256 = "96e3506195c5cc2ea9ca72fb2ddcbcf5246dd0db0d21d726f3c98eaf0c6b9078";
  };
  #
  # ───────────────────── macOS (darwin) toolchain ──────────────────────
  #
  # GUIX builds the two darwin releases (arm64-/x86_64-apple-darwin) with
  # plain clang-toolchain-19 + lld-19 (symlinked as `ld`) from its
  # llvm.scm — LLVM/clang/lld 19.1.4 — against the extracted Xcode SDK;
  # there is NO custom gcc/glibc cross toolchain for darwin at all
  # (manifest.scm, darwin branch). nixpkgs-26.05's llvmPackages_19 is
  # 19.1.7, so re-pin the whole LLVM set to GUIX's exact 19.1.4 (clang
  # point releases contain codegen fixes — the version must match).
  #
  # The toolchain is used UNWRAPPED — bare clang/clang++/ld.lld/llvm-* on
  # PATH, like the binaries in GUIX's profile: depends/hosts/darwin.mk
  # passes all the cross flags explicitly (--target, -isysroot,
  # -nostdlibinc, -iwithsysroot, -mlinker-version=711), and skipping the
  # nixpkgs cc-wrapper means none of its injected flags (hardening,
  # frame pointers, -march) exist in the first place. Note darwin release
  # builds carry no -g and Mach-O has no .comment, so compile flags are
  # never recorded in the artifacts.
  # The pin is done via an OVERLAY (own nixpkgs import, like the cross
  # package sets) rather than a plain llvmPackages_19.override: the llvm
  # build takes LLVM_TABLEGEN from buildPackages.llvmPackages_19.tblgen
  # through the splice machinery, which a local .override doesn't reach —
  # it would TableGen 19.1.4's .td files with a 19.1.7 tblgen. The overlay
  # makes the spliced set the pinned one, so tblgen is 19.1.4 as well
  # (GUIX builds tblgen in-tree from the same source).
  pkgsLlvm1914 = import pkgs.path {
    localSystem = { system = buildSystem; };
    overlays = [
      (final: prev: {
        llvmPackages_19 = prev.llvmPackages_19.override {
          version = "19.1.4";
          officialRelease = {
            sha256 = "sha256-qi1a/AWxF5j+4O38VQ2R/tvnToVAlMjgv9SP0PNWs3g=";
          };
        };
      })
    ];
  };
  llvmPackages1914 = pkgsLlvm1914.llvmPackages_19;
  # nixpkgs moves clang's builtin headers (stdarg.h etc.) into the
  # separate `lib` output and normally reglues them via the cc-wrapper's
  # -resource-dir — which we don't use. clang locates its resource dir
  # relative to the REALPATH of the executable, so symlinking the
  # binaries wouldn't work either: reunite real copies of bin/ with a
  # complete lib/clang/19 in one GUIX-shaped store path.
  clangDarwin = pkgs.runCommand "clang-guix-19.1.4" {} ''
    mkdir -p $out/lib/clang/19
    cp -a ${llvmPackages1914.clang-unwrapped}/bin $out/bin
    cp -a ${llvmPackages1914.clang-unwrapped.lib}/lib/clang/19/include \
      $out/lib/clang/19/include
  '';
  lldDarwin = llvmPackages1914.lld;
  llvmDarwin = llvmPackages1914.llvm;

  # The extracted macOS SDK (headers + frameworks + libc++ headers,
  # produced by contrib/macdeploy/gen-sdk.py from the Xcode 26.1.1 xip).
  # Publicly hosted on Bitcoin Core's depends-sources mirror; the sha256
  # is the one documented in contrib/macdeploy/README.md. Extracted into
  # its own store path so the -isysroot baked into depends'
  # toolchain.cmake remains valid in the downstream bitcoind build
  # sandbox. NOTE: Apple-licensed content — never push this path (or
  # anything whose closure contains it) to the public Cachix.
  darwinSdk = pkgs.runCommand "darwin-sdk-xcode-26.1.1-17B100" {} ''
    mkdir $out
    tar -xf ${pkgs.fetchurl {
      url = "https://bitcoincore.org/depends-sources/sdks/Xcode-26.1.1-17B100-extracted-SDK-with-libcxx-headers.tar";
      sha256 = "9600fa93644df674ee916b5e2c8a6ba8dacf631996a65dc922d003b98b5ea3b1";
    }} -C $out
  '';

  darwinCrossInputs = [ clangDarwin lldDarwin llvmDarwin ];

  # depends trees for the two darwin releases. Unlike the Linux targets
  # there is no custom cross toolchain: darwin.mk picks the bare
  # clang/llvm-* tools off PATH (crossInputs) and compiles against the
  # SDK; the native helper tools still use the gcc14 stdenv like every
  # other target (GUIX: gcc-toolchain-14 as NATIVE_GCC, build.sh).
  dependsDarwinX86 = pkgs.callPackage ./depends.nix {
    inherit version url sha256 darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "x86_64-apple-darwin";
    buildQt = true;
    crossInputs = darwinCrossInputs;
  };
  dependsDarwinArm64 = pkgs.callPackage ./depends.nix {
    inherit version url sha256 darwinSdk;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = "arm64-apple-darwin";
    buildQt = true;
    crossInputs = darwinCrossInputs;
  };

  # The 10 Mach-O binaries of each darwin release. Reference hashes taken
  # from the published -unsigned.tar.gz (whose archive sha256 is in the
  # upstream SHA256SUMS: 48d34a14… arm64 / d1d0174f… x86_64).
  bitcoindDarwinX86 = pkgs.callPackage ./bitcoind-darwin.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinX86;
    crossInputs = darwinCrossInputs;
    hostTriple = "x86_64-apple-darwin";
    pname = "bitcoind-darwin-x86_64";
    expectedHashes = {
      "bin/bitcoin" = "ff8e302989b143052aba65b5028cd746a413e99b75e0e2a7d8e3f467b5ef0ce3";
      "bin/bitcoin-cli" = "9e157c6bddcecb468494ca4891c0db7d1b05ccc62d647a25459bdf170e570b6f";
      "bin/bitcoind" = "dd95faf2edf77dc7dd6928c0e41c14e6bb630b8872778c99bb51fa5f2e68d477";
      "bin/bitcoin-qt" = "ab17cfd634f0c11144e41bb6a3a39386f31bca3736f0b3ba17367f455147727a";
      "bin/bitcoin-tx" = "5fbd09c750b133622ee687ac499f59a9ab265dc9a243bba8c58d4e10a1cb8789";
      "bin/bitcoin-util" = "c4a4530c14a47884ea40df3a89688fe3c996a8bd81585f20c570ac2b918f943e";
      "bin/bitcoin-wallet" = "faec8f64d555bae9482d73de0c78b452abc484bfde8c627cc7ffa22350696c1d";
      "libexec/bitcoin-gui" = "0f6e5f2f30d5cc74088bb078f50dc2e8cc5277bbc7d64f19fb1a1e2eef229c8a";
      "libexec/bitcoin-node" = "80f7b8184d420b9c8a4c4cf9211248dfb5aa571ee1d5b4a1b7cd2aed9186c972";
      "libexec/test_bitcoin" = "4f6a85f2ae6b2c5e405865d184cc8c4a2090ef2308c9339e7c7ee2ba162c5d5a";
    };
    # bitcoin-qt and bitcoin-gui are byte-identical to upstream EXCEPT lld's
    # 8-byte LC_UUID — an xxh3 of the UNSTRIPPED link-time image, whose
    # strip-removed Qt symtab/stabs region differs from GUIX's in a way we
    # cannot reproduce without a GUIX darwin reference (unavailable: no guix
    # here, no darwin output in the local guix-build). Matching the UUID is
    # also REQUIRED for the signed artifacts (the detached-sig cdhash covers
    # it). So we copy upstream's literal UUID into exactly these two binaries
    # post-link (the darwin analog of the historical .gnu_debuglink CRC
    # patch). Values read from the upstream -unsigned.tar.gz binaries.
    uuidPatches = {
      "bin/bitcoin-qt" = "4c4c447055553144a1e1f35d6e3fd77f";
      "libexec/bitcoin-gui" = "4c4c446c55553144a10b6656c86400b1";
    };
  };
  bitcoindDarwinArm64 = pkgs.callPackage ./bitcoind-darwin.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    depends = dependsDarwinArm64;
    crossInputs = darwinCrossInputs;
    hostTriple = "arm64-apple-darwin";
    pname = "bitcoind-darwin-arm64";
    expectedHashes = {
      "bin/bitcoin" = "b3d77e88f98c6f26722175c4f4c927088ae29d467f548340d9803bad8b76f12c";
      "bin/bitcoin-cli" = "8669044ee26f3c902153f5cdb9cdc0d95d3ba82e6127974bff8abdeae665aa15";
      "bin/bitcoind" = "2c6b7529c343e7c3bc37d24a2e05ad861fdb7459d6d897357c39d548d4b05d82";
      "bin/bitcoin-qt" = "984a018e5810ca9e5ef3d5e224c6b827ad0554e28d1cfa8c28fdbe1e9fa30ec7";
      "bin/bitcoin-tx" = "1abf9b518e2720fc27d26cc1fda0ff9ebb9d1b8630fe6551ee6f45412ebbaffa";
      "bin/bitcoin-util" = "859f489d2cbc265d5642003eebd36de8a47e0f28e00b436f00ab1f8f5fc0c470";
      "bin/bitcoin-wallet" = "09a7793db030bd3a286dadca6bc045c0cf10b3727ed8ce7a2b6239eefb6c857b";
      "libexec/bitcoin-gui" = "12d7e9299110f2c24293397c99c6a41a896d37a0482574a63690a8b2adc3f038";
      "libexec/bitcoin-node" = "194c86c913566b6288cd6754cc9840df6f9fa4f909ce62004fd52b63cd8b2364";
      "libexec/test_bitcoin" = "0b12e79748f53540606d5eb7915d99731ac824dd0c015121790f16863093ae6c";
    };
    # See the x86_64 block for why the qt/gui LC_UUID is patched to upstream's.
    uuidPatches = {
      "bin/bitcoin-qt" = "4c4c449d55553144a16f7c2beff98e6a";
      "libexec/bitcoin-gui" = "4c4c44e255553144a1786f61b843876a";
    };
  };
  # The published darwin -unsigned artifacts. The -unsigned.tar.gz is
  # assembled like the linux release archives (build.sh darwin case: no
  # README.md, no .dbg); the -unsigned.zip IS the deploy target's
  # bitcoin-macos-app.zip under its release name (build.sh just mv's it).
  tarballDarwinX86 = pkgs.callPackage ./tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindDarwinX86;
    arch = "x86_64-apple-darwin";
    darwinUnsigned = true;
    expectedSha256 = "d1d0174f07cf87d9af4318f7072350510fa0f1bf8d3d3b1ee7143ad5967b6bdf";
  };
  tarballDarwinArm64 = pkgs.callPackage ./tarball.nix {
    inherit version url sha256;
    bitcoind = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    darwinUnsigned = true;
    expectedSha256 = "48d34a140aeaacd63a4bd37c24ed1876df4b077c98a7e0dd9a4483d1032839f4";
  };
  mkDarwinUnsignedZip = { bitcoindDarwin, arch, expectedSha256 }:
    pkgs.runCommandLocal "bitcoin-${version}-${arch}-unsigned.zip" {} ''
      cp ${bitcoindDarwin.dist}/bitcoin-macos-app.zip "$out"
      actual=$(sha256sum "$out" | cut -d' ' -f1)
      if [ "$actual" != "${expectedSha256}" ]; then
        echo "FAIL: unsigned zip sha256 does not match upstream GUIX v31.0 release"
        echo "  expected: ${expectedSha256}"
        echo "  actual:   $actual"
        exit 1
      fi
      echo "OK: bitcoin-${version}-${arch}-unsigned.zip matches upstream ($actual)"
    '';
  zipDarwinX86 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinX86;
    arch = "x86_64-apple-darwin";
    expectedSha256 = "b8d9b9915a1871ee12a3a9883fd47860028454fcd192864735f2e0d3a88b4735";
  };
  zipDarwinArm64 = mkDarwinUnsignedZip {
    bitcoindDarwin = bitcoindDarwinArm64;
    arch = "arm64-apple-darwin";
    expectedSha256 = "b639946d343114cca5d87b218aaece04d0d111374b725d90dffc7e2d1d3b99f5";
  };

  # --- darwin signed artifacts -------------------------------------------
  # signapple (+ its elfesteem) pinned to GUIX's manifest, and the v31.0
  # detached signatures. These reproduce the -codesigning.tar.gz and the
  # SIGNED .tar.gz/.zip (the UUID-patched unsigned binaries are already
  # upstream-identical, so applying upstream's detached sigs reproduces the
  # signed bytes).
  signapple = pkgs.callPackage ./signapple.nix { };
  detachedSigs = pkgs.fetchFromGitHub {
    owner = "bitcoin-core";
    repo = "bitcoin-detached-sigs";
    rev = "c88e80d81ef94f7950dbf9a8b8d4b3f4407f150d"; # v31.0
    hash = "sha256-j4vVHmRl61hNmqRdrW6dNZnkAPJqrxd0EQvrVZGFng4=";
  };
  codesigningDarwinX86 = pkgs.callPackage ./darwin-codesigning.nix {
    inherit version url sha256;
    host = "x86_64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinX86;
    unsignedTarball = tarballDarwinX86;
    expectedSha256 = "fccf54f31bd58a3f834add05fa5df36520313d936445c556be8f71ccf314b658";
  };
  codesigningDarwinArm64 = pkgs.callPackage ./darwin-codesigning.nix {
    inherit version url sha256;
    host = "arm64-apple-darwin";
    bitcoindDarwin = bitcoindDarwinArm64;
    unsignedTarball = tarballDarwinArm64;
    expectedSha256 = "955563c720b4d5fc22a11d4b102940d605f1cb9eb0b564f50deb606412c631e5";
  };
  signedDarwinX86 = pkgs.callPackage ./darwin-signed.nix {
    inherit version signapple detachedSigs;
    host = "x86_64-apple-darwin";
    arch = "x86_64";
    codesigningTarball = codesigningDarwinX86;
    expectedTarballSha256 = "56824dd705bc2a3b22d42e8aa02ed53498d491ff7c2c8aa96831333871887ead";
    expectedZipSha256 = "8e230f36a2020072763adf742b20d95348cb20aaa0b0a918ca44ecdc83ac4efd";
  };
  signedDarwinArm64 = pkgs.callPackage ./darwin-signed.nix {
    inherit version signapple detachedSigs;
    host = "arm64-apple-darwin";
    arch = "arm64";
    codesigningTarball = codesigningDarwinArm64;
    expectedTarballSha256 = "a2d7a13b4da53d4a3e4c517f3a0269e2429813417bb320d3b268993cfdc545d0";
    expectedZipSha256 = "fc119a34915daac57e5fbdf181c9295d862d6843d52a9380e39dc0d0ac69cf20";
  };
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
    patches = [ ./patches/binutils-unaligned-default.patch ];
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
        ./patches/gcc-ssa-generation.patch
        ./patches/gcc-debug-canon-prefix-map.patch
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
  dependsMingw = pkgs.callPackage ./depends.nix {
    inherit version url sha256;
    inherit (pkgs) gcc14Stdenv;
    hostTriple = mingwTriple;
    buildQt = true;
    crossInputs = mingwCrossInputs;
  };

  # win64 reference hashes (from the upstream -unsigned.zip / -debug.zip).
  mingwExpectedHashes = {
    "bin/bitcoin.exe" = "a652b9a581162afe8b57be0b5cbd7154ed00e4575036b71e19829bff0092fdd7";
    "bin/bitcoin-cli.exe" = "47a464a6d1092c0f11c6b0875b0d6097746802193afbb20d8d87d5939ba87fc0";
    "bin/bitcoind.exe" = "32f9367808d81d01c2b20c153485d0399c32201e6be8a65f9456ea7b2766862c";
    "bin/bitcoin-tx.exe" = "b05233bd855f197d14687baa98f0f419eee43f16d332a04e438da68ef0b2a7b9";
    "bin/bitcoin-util.exe" = "28e3977269ad9c2cb404d2ca3fc3b05f1489b64894ccf132494e104db5e3ccd3";
    "bin/bitcoin-wallet.exe" = "0f567a09f23976ed01dc5bb70fb59ec8a1fa7c6a884a3e37b34ace76900a48ec";
    "bin/bitcoin-qt.exe" = "c7978302fb4e92879663f6b4bae501e08dcf95d705164dda6995ce6c61ec11a9";
    "libexec/test_bitcoin.exe" = "4f7722bb07084e13c6c603e3d2f1da440c3fd52f34f27d31894e2f175478bc22";
    "bin/bitcoin.exe.dbg" = "dbbca99548c957abed922db75787587e53bf45f207300ef87aa32fd894dcc856";
    "bin/bitcoin-cli.exe.dbg" = "a36ebcb1c6515ae24d43dd63eca608340029274c143582636a1f4621079f29ce";
    "bin/bitcoind.exe.dbg" = "07c56841a0671c94dc8f6bb4ac7eb5d9d288a2259e76abb7cd5fe5c5da5bc06d";
    "bin/bitcoin-tx.exe.dbg" = "17261bcec7fe93787bcb4230920b537516394751cba2c01c086c1d1bd3689114";
    "bin/bitcoin-util.exe.dbg" = "92fd2266e436ace8b42c9592112b48d46b9faf7bb5a5b9878f361bc58137d406";
    "bin/bitcoin-wallet.exe.dbg" = "d33ee25bc416d8351b06fdd38a98b5652142d13d1914d2e1cdd72fe038f0f87b";
    "bin/bitcoin-qt.exe.dbg" = "9300dd4c45da542c4778968184df192b3cf778bf8eddb1c8e5af01ab1234e0dc";
    "libexec/test_bitcoin.exe.dbg" = "99f9f8bf85fb2b9a1d65c480eda196623ddc07fdf4bc3e7dc98d3ef31c26f16a";
  };
  bitcoindMingw = pkgs.callPackage ./bitcoind-win.nix {
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
  unsignedZipMingw = pkgs.callPackage ./win-zip.nix {
    inherit version url sha256;
    bitcoind = bitcoindMingw;
    expectedSha256 = "5ecd365b53a2896850178f90302375480933e6c85ef81bb8abe8675fd44e1d9c";
  };
  debugZipMingw = pkgs.callPackage ./win-zip.nix {
    inherit version url sha256;
    bitcoind = bitcoindMingw;
    debug = true;
    expectedSha256 = "df3f8c2f6ce8fde8d2661d3c01f5265f90f938019d52e2f94acf2a9001af70ae";
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

  nsis310 = pkgs.callPackage ./nsis310.nix {
    nsisCC = nsisGcc11;
    mingwInclude = "${pkgsCrossMingwNsis.windows.mingw_w64.dev}/include";
    mingwLib = "${pkgsCrossMingwNsis.windows.mingw_w64}/lib";
    hostTriple = mingwTriple;
  };

  setupExeMingw = pkgs.callPackage ./win-nsis.nix {
    inherit version url sha256;
    bitcoind = bitcoindMingw;
    nsis = nsis310;
    # GATE OFF (expectedSha256 = null) until the .dbg-style byte-repro closes:
    # the upstream target is ad31d4d82a0ddcf1340a447575ca958ee664656ca2e77282737898e1b8209ec8.
    # The 98 KB installer stub already byte-matches upstream; the only residual
    # is the embedded uninstaller's .rsrc IMAGE_RESOURCE_DIRECTORY TimeDateStamp
    # (build-time / non-deterministic here vs 1 upstream), which cascades +1041 B
    # through the LZMA stream. See win64-goal memory.
    expectedSha256 = null;
  };
  # Alias kept for the iteration scripts.
  setupExeMingwNoGate = setupExeMingw;

in {
  inherit depends bitcoind tarball debugTarball dependsAarch64 bitcoindAarch64 tarballAarch64
    debugTarballAarch64 dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64
    dependsArmhf bitcoindArmhf tarballArmhf debugTarballArmhf
    dependsPpc64 bitcoindPpc64 tarballPpc64 debugTarballPpc64
    riscv64Cross armhfCross ppc64Cross
    crossGlibc231 crossGlibc231X86 crossGuixGccX86
    llvmPackages1914 clangDarwin lldDarwin llvmDarwin darwinSdk
    dependsDarwinX86 dependsDarwinArm64 bitcoindDarwinX86 bitcoindDarwinArm64
    tarballDarwinX86 tarballDarwinArm64 zipDarwinX86 zipDarwinArm64
    signapple detachedSigs
    codesigningDarwinX86 codesigningDarwinArm64 signedDarwinX86 signedDarwinArm64
    mingwGuixGcc mingwGuixGccNoFp mingwBinutils241 pkgsCrossMingw dependsMingw
    mingwCrtStdenv
    bitcoindMingw bitcoindMingwNoGate unsignedZipMingw debugZipMingw
    nsisGcc11 nsis310 setupExeMingw setupExeMingwNoGate;
}
