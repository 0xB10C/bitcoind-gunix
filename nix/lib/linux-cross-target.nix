{ pkgs, version, src, buildSystem, sourceDateEpoch }:

  # --- generic linux-gnu cross target generator ---
  # The aarch64/riscv64 recipe parameterized over the target triple: cross
  # binutils 2.46 (compressed-debug-sections, bundled zlib), GUIX's glibc
  # 2.31 (forced default-PIE gcc-14 CC, --disable-static-pie, drv-0
  # debug-prefix-map, pic-hardening-off, unsplit static libs), gcc 14.3.0
  # with GUIX's linux-base-gcc flags + the ssa patch (libgcc -g
  # multiplicity, GUIX maps, libstdc++ strip-debug), NoFp wrapper
  # variants, kernel headers 6.1.166, then both build passes, package.sh
  # and the 2 archive gates. See the aarch64 section above for the
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
  # - extraCXXFLAGS: build_linux.sh's per-host extras (armhf -Wno-psabi).
  #   The ELF interpreter is NOT a knob: release-cross.nix asks upstream's
  #   own glibc_dynamic_linker (libexec/setup.sh) for it.
  # The NoFp wrappers strip exactly "-fno-omit-frame-pointer" — on these
  # targets the cc-wrapper injects no leaf-FP variant (x86_64/aarch64-only
  # for gcc 14) and no -march (no gcc.arch platform attrs).
    { triple
    , nixpkgsPath ? pkgs.path
    , gccArchFlags ? [ ]
    , gccExtraPatches ? [ ] # extra patches for the final cross gcc only (not the glibc CC)
    , gccNativeInputs ? [ ] # prepended to the cross gcc's build env (e.g. armhf's pinned gawk)
    , glibcPatches ? [ ]
    # Sections to remove from the installed glibc SHARED objects. ld only
    # reads these .so files, but every section it reads takes a global BFD
    # section id, and ld names ppc64/ARM long-branch (and Cortex-A8
    # erratum) stubs after those ids and emits them in hash-table order.
    # Where our glibc .so carry a section GUIX's lack, every later id
    # shifts and the stubs of the big binaries come out reordered.
    # - ppc64: [ ".gnu.attributes" ] (rs6000 Tag_GNU_Power_ABI_FP in
    #   libm.so.6/libc.so.6); proven by relinking guix's own objects
    #   against copies minus that section: every section matches.
    , glibcStripSharedSections ? [ ]
    # Restrict that strip to these sonames (resolved to their real files);
    # null = every ELF lib/*.so*. armhf needs it: GUIX's ld-linux keeps the
    # section its libc/libpthread lack.
    , glibcStripSharedFiles ? null
    , debugCanonMap ? false # route the /build→DISTSRC rewrite through the gcc canon env var (ppc64)
    , canonDepends ? false # route the depends→/bitcoin rewrite through the canon env var too
                           # (instead of -ffile-prefix-map): gcc ggc-allocates every FIRED argv
                           # map rewrite, and GUIX never fires a map on depends (it lives at the
                           # real /bitcoin) — the extra allocations flip var-tracking loclists
                           # in big CUs (armhf net_processing, ppc64 qt). Needs gccExtraPatches
                           # to include gcc-debug-canon-prefix-map.patch.
    , extraCXXFLAGS ? ""
    , fatalLinkWarnings ? true # build_linux.sh adds -Wl,--fatal-warnings everywhere but riscv64
    , pnameSuffix
    # Upstream-hash gates: the archive hashes come from the checked-in
    # SHA256SUMS (via default.nix's upstreamSha256 lookup). There is no
    # per-binary gate any more — upstream publishes no per-binary hashes,
    # and package.nix prints every binary/.dbg hash for the log instead.
    , tarballSha256 ? null
    , debugTarballSha256 ? null # null = no upstream hash — archive built ungated
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

      linuxHeaders61' = import ./linux-headers-61.nix { inherit pkgs pkgsCross; };

      # Stock cross gcc14 wrapper used as the glibc's forced CC — see
      # gcc14X86NoFp/gcc14Aarch64NoFpCC. Only default-PIE is baked (GUIX's
      # linux-base-gcc); no branch-protection/CET analog on these targets.
      gcc14NoFpCC = pkgsCross.buildPackages.gcc14.cc.overrideAttrs (o: {
        configureFlags = (o.configureFlags or [ ]) ++ [
          "--enable-default-pie=yes"
          "--with-as=${crossBinutils'}/bin/${triple}-as"
          "--with-ld=${crossBinutils'}/bin/${triple}-ld"
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
          rev = "28eb5caf895ced5d895cb02757e109004a2d33e5";
          hash = "sha256-qNwcD7BCXzHJvKr9m8PuJ8qkQ74KjQczRx5XHViWWR0=";
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
            "--enable-kernel=3.17.0"
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
          # Target objdump for the generated gnu/stubs-*.h: configure's
          # `$CC -print-prog-name=objdump` yields a bare host `objdump`, which
          # reads no target object, so the stubs lists came out EMPTY. The
          # 11 missing armhf __stub_* macros alone flipped a var-tracking list
          # in index/base.cpp (every armhf .dbg). GUIX puts the target
          # binutils first on PATH for the same lookup (cross-base.scm).
          "OBJDUMP=${crossBinutils'}/bin/${triple}-objdump"
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
        '' + pkgs.lib.optionalString (glibcStripSharedSections != [ ]) ''
          # See glibcStripSharedSections. Only real ELF shared objects:
          # symlinks resolve to them, linker scripts (libc.so) are text, and
          # the static archives (whose linked members' debug info feeds the
          # .dbg files) stay untouched.
          for f in ${if glibcStripSharedFiles == null then "$out/lib/*.so*" else pkgs.lib.concatMapStringsSep " " (n: "$(readlink -f $out/lib/${n})") glibcStripSharedFiles}; do
            [ -L "$f" ] && continue
            head -c4 "$f" | grep -q ELF || continue
            ${crossBinutils'}/bin/${triple}-objcopy ${pkgs.lib.concatMapStringsSep " " (s: "--remove-section=${s}") glibcStripSharedSections} "$f"
          done
        '';
      });

      crossBinutils' = import ./cross-binutils-246.nix { inherit pkgs pkgsCross; };
      crossBintools' = pkgsCross.stdenv.cc.bintools.override {
        bintools = crossBinutils';
        libc = crossGlibc231';
      };

      # Cross gcc 14.3.0 with GUIX's linux-base-gcc flags — see
      # crossGuixGcc (aarch64). No --enable-standard-branch-protection
      # (aarch64-only), no --enable-cet (x86-only), no
      # -Wa,-mrelax-relocations (GOTPCRELX is x86-only).
      crossGuixGcc' = pkgsCross.stdenv.cc.override {
        bintools = crossBintools';
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
            "--disable-lto"
            "--disable-nls"
            "--disable-tm-clone-registry"
            "--with-as=${crossBinutils'}/bin/${triple}-as"
            "--with-ld=${crossBinutils'}/bin/${triple}-ld"
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
              ${crossBinutils'}/bin/${triple}-objcopy \
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

      # TWO depends trees, like upstream's two build passes: build_linux.sh
      # builds depends with NO_QT=1 under BASE_CACHE .../GUIX/BUILD,
      # build_linux_gui.sh builds the full tree under .../GUIX/GUI.
      dependsNoQt' = pkgs.callPackage ./depends.nix {
        inherit version src;
        inherit (pkgs) gcc14Stdenv;
        hostTriple = triple;
        buildQt = false;
        crossInputs = crossInputs';
      };
      depends' = pkgs.callPackage ./depends.nix {
        inherit version src;
        inherit (pkgs) gcc14Stdenv;
        hostTriple = triple;
        buildQt = true;
        crossInputs = crossInputs';
      };
      releaseArgs = {
        inherit version src;
        inherit (pkgs) gcc14Stdenv;
        inherit extraCXXFLAGS debugCanonMap canonDepends fatalLinkWarnings;
        hostTriple = triple;
        crossInputs = crossInputsNoFp';
        guixGcc = crossGuixGcc'.cc;
        linuxHeaders = linuxHeaders61';
      };
      bitcoindNoGui' = pkgs.callPackage ./release-cross.nix (releaseArgs // {
        pname = "bitcoind-${pnameSuffix}-nogui";
        depends = dependsNoQt';
      });
      bitcoindGui' = pkgs.callPackage ./release-cross.nix (releaseArgs // {
        pname = "bitcoind-${pnameSuffix}-gui";
        depends = depends';
        guiOnly = true;
      });
      # Upstream's libexec/package.sh over the merged install tree: split
      # debug info, copy the committed extras, build both archives.
      packaged' = pkgs.callPackage ./package.nix {
        inherit version src sourceDateEpoch;
        hostTriple = triple;
        noGui = bitcoindNoGui';
        gui = bitcoindGui';
        crossInputs = crossInputsNoFp';
        pname = "bitcoin-${pnameSuffix}-packaged";
      };
      # The install tree package.sh split the debug info out of — the
      # binaries and .dbg the archives were made from, kept as its own attr
      # for per-binary diffing against a reference build.
      bitcoind' = packaged'.installed;
      mkArtifact = args: pkgs.callPackage ./artifact.nix { } ({ packaged = packaged'; } // args);
      tarball' = mkArtifact {
        file = "bitcoin-${version}-${triple}.tar.gz";
        expectedSha256 = tarballSha256;
      };
      debugTarball' = mkArtifact {
        file = "bitcoin-${version}-${triple}-debug.tar.gz";
        expectedSha256 = debugTarballSha256;
      };
    in {
      depends = depends';
      dependsNoQt = dependsNoQt';
      bitcoindNoGui = bitcoindNoGui';
      bitcoindGui = bitcoindGui';
      bitcoind = bitcoind';
      packaged = packaged';
      tarball = tarball';
      debugTarball = debugTarball';
      crossGlibc231 = crossGlibc231';
      crossGuixGcc = crossGuixGcc';
      crossGuixGccNoFp = crossGuixGccNoFp';
    }
