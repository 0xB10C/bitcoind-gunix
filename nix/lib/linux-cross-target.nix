{ pkgs, version, url, sha256, buildSystem }:

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
          patches = (old.patches or [ ]) ++ [ ../patches/gcc-ssa-generation.patch ] ++ gccExtraPatches;
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
      bitcoind' = pkgs.callPackage ./release-cross.nix {
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
    }
