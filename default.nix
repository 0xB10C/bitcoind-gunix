{ pkgs ? import <nixpkgs> {} }:

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
      # Skip glibc's C++ link test — the cross build stdenv's libstdc++ is
      # gcc 15's, built against a modern glibc, and won't link against the
      # 2.31 being built. C++ is test-only; the installed glibc is pure C.
      libc_cv_cxx_link_ok = "no";
    };
    # Force the cross C compiler to gcc 14.3.0 (GUIX's version). glibc is a
    # stdenv bootstrap component, so `.override { stdenv = … }` is ignored
    # — on nixos-26.05 the cross glibc would otherwise build with the
    # bootstrap cross gcc 15.2.0, giving __libc_csu_init the gcc-15
    # register allocation (diverges from upstream's gcc-14 codegen). Force
    # CC only (not CXX — forcing CXX breaks glibc's cstdlib/cmath
    # generation; the shipped glibc is all C).
    # `aarch64-linux-gnu-gcc` is the cross gcc14's driver name
    # (targetPrefix = "aarch64-linux-gnu-").
    preConfigure = (old.preConfigure or "") + ''
      export CC=${pkgsCrossAarch64.buildPackages.gcc14}/bin/aarch64-linux-gnu-gcc
    '';
    makeFlags = (old.makeFlags or [ ]) ++ [
      "CC=${pkgsCrossAarch64.buildPackages.gcc14}/bin/aarch64-linux-gnu-gcc"
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
  # aarch64-native binutils and can't run on the build machine). Same
  # override as crossBinutils241X86.
  crossBinutils241 = pkgsCrossAarch64.stdenv.cc.bintools.bintools.overrideAttrs (_: {
    version = "2.41";
    src = pkgs.fetchurl {
      url = "mirror://gnu/binutils/binutils-2.41.tar.bz2";
      sha256 = "sha256-pMS+wFL3uDcAJOYDieGUN38/SLVmGEGOpRBn9nqqsws=";
    };
    # Drop newer-binutils patches that may not apply to 2.41. Keep the
    # default cross outputs (incl. `dev`) — the cross binutils' postInstall
    # references $dev.
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
in {
  inherit depends bitcoind tarball debugTarball dependsAarch64 bitcoindAarch64 tarballAarch64
    crossGlibc231 crossGlibc231X86 crossGuixGccX86;
}
