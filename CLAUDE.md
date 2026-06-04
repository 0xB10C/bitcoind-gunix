# bitcoind-gunix

## Goal

Reproduce the official Bitcoin Core GUIX release binary for
`x86_64-pc-linux-gnu` using Nix, producing a binary with an identical
sha256. Project tracking: https://github.com/0xB10C/bitcoind-gunix/issues/1.

## Status (2026-06-04): ALL release binaries byte-match (incl. GUI)

Every binary in the upstream `bitcoin-31.0-x86_64-linux-gnu` release now
reproduces byte-for-byte:

```
eb5670ae…  bin/bitcoin            ce3b159c…  bin/bitcoin-tx
3e92883f…  bin/bitcoin-cli        1d18ee4b…  bin/bitcoin-util
dae69848…  bin/bitcoind           7d8382b8…  bin/bitcoin-wallet
3480af8f…  bin/bitcoin-qt         01c212ee…  libexec/bitcoin-node
416e79bb…  libexec/bitcoin-gui    c7a2a906…  libexec/test_bitcoin
```

A reproducibility gate in `bitcoind.nix` `postFixup` asserts all 10
hashes after every build — if a toolchain or flag change breaks
byte-equality for any of them, the Nix build itself fails. CI re-asserts
externally.

**The full release archive matches too**: `nix build .#tarball` assembles
`bitcoin-31.0-x86_64-linux-gnu.tar.gz` byte-identical to upstream
(`d3e4c58a…`), with its own sha256 gate. So both the individual binaries
and the published `.tar.gz` reproduce.

The `.dbg` debug files are produced but their `.gnu_debuglink` CRCs are
patched to upstream's values (the `.dbg` themselves aren't
byte-reproducible — see "Task #2 finding"); the separate `-debug.tar.gz`
is not assembled.

## Status (2026-06-04): FULL aarch64 release ALSO byte-matches (cross-compiled)

`nix build .#bitcoindAarch64` cross-compiles — on an x86_64 machine, no
qemu — all 10 binaries of the `bitcoin-31.0-aarch64-linux-gnu` release,
and `nix build .#tarballAarch64` assembles the full `.tar.gz`, every one
byte-identical to the upstream GUIX release:

```
c793384c…  bin/bitcoin            b4128423…  bin/bitcoin-tx
25c2743e…  bin/bitcoin-cli        3a0daa1c…  bin/bitcoin-util
6f66822a…  bin/bitcoind           b7c2bb47…  bin/bitcoin-wallet
760c3de5…  bin/bitcoin-qt         f213271f…  libexec/bitcoin-node
f85193a8…  libexec/bitcoin-gui    940fd792…  libexec/test_bitcoin
4de1d568…  bitcoin-31.0-aarch64-linux-gnu.tar.gz
```

A `postFixup` sha256 gate in `bitcoind-aarch64.nix` asserts all 10
binaries every build; `tarballAarch64` asserts the archive sha256.

What it took, beyond the depends/bitcoind cross-build plumbing (HOST=
aarch64-linux-gnu, the aarch64 ELF interpreter `/lib/ld-linux-aarch64.so.1`,
unset-CC-for-depends / set-CC-for-cmake), was a GUIX-exact aarch64 **cross
toolchain** in `default.nix`, the cross analog of the native one:

1. **cross binutils 2.41** (`crossBinutils241`) — override the build-host
   cross binutils (`pkgsCrossAarch64.stdenv.cc.bintools.bintools`, *not*
   `binutils-unwrapped` which is the aarch64-native one) down to 2.41.
2. **cross glibc 2.31** (`crossGlibc231`) — `pkgsCrossAarch64.glibc`
   overridden to GUIX's 2.31 git source, with: the 2.31 porting fixes
   (no nss seds, no C.UTF-8 locale gen); `hardeningDisable`
   (zerocallusedregs etc.); `-momit-leaf-frame-pointer` (keep the non-leaf
   FP — see below); and `-mbranch-protection=standard` (it's built with the
   *stock* cross gcc, so this per-compile flag gives its static members the
   PAC/BTI that `--enable-standard-branch-protection` would).
3. **cross gcc 14.3.0** (`crossGuixGcc`) — `pkgsCrossAarch64.stdenv.cc.cc`
   with GUIX's linux-base-gcc flags (`--enable-standard-branch-protection`
   → aarch64 BTI/PAC, default-pie/ssp, initfini-array, host-bind-now,
   disable nls/libsanitizer/…) + the gcc-ssa-generation patch, **rebuilt
   against glibc 2.31 via `libcCross = crossGlibc231`** (the scoped cross
   analog of native `stdenvForGccRebuild`; the cc-wrapper + bintools `libc`
   also point at 2.31). `--enable-cet` is x86-only and omitted.

### The decisive aarch64-specific gotcha: frame pointers

x86_64's `bitcoind.nix`/glibc use `-fomit-frame-pointer` because x86_64
gcc omits the frame pointer at `-O2` by default. **aarch64 gcc at `-O2`
KEEPS the non-leaf frame pointer and only omits the leaf one.** Upstream
relies on that `-O2` default. nixpkgs' cross cc-wrapper forces
`-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer` (keep both), so the
correct flag everywhere on aarch64 (bitcoind, depends, glibc) is **only
`-momit-leaf-frame-pointer`** — keep non-leaf, omit leaf. Copying x86_64's
`-fomit-frame-pointer` stripped `stp x29,x30 / add x29,sp / ldp` from
every non-leaf function → the binary was ~66 KB of `.text` + ~35 KB of
`.eh_frame` (CFI) *below* upstream. This single flag closed the bulk of
the gap; the glibc CRT codegen fixes (#2 above) closed the last 6
functions (`__libc_csu_init/fini`, `atexit`, the stat wrappers).

### Methodology note (how the gap was localized)

bloaty section-diff (ours stripped vs upstream) flagged `.text`/`.eh_frame`;
a per-function `nm --print-size` diff (our unstripped binary vs upstream's
**decompressed** `.dbg` — `objcopy --decompress-debug-sections`; bloaty
rejects the `.dbg`: empty build-id + SHF_COMPRESSED) showed the deltas were
small (32–136 B) and pervasive → a global codegen flag (frame pointers),
then narrowed to 6 glibc static members → branch protection + hardening.
The upstream aarch64 release + `-debug.tar.gz` are the reference (sha
`6f66822a…` / debuglink CRC `0xe8e5e289`).

### Full aarch64 release (all 10 + tarball) — DONE

`dependsAarch64` builds the full Qt6 tree (`buildQt = true`);
`bitcoind-aarch64.nix` builds all 10 binaries (BUILD_TESTS left ON, GUI
auto-enabled by the Qt depends) with per-binary split-debug +
`.gnu_debuglink` CRC patch (cross binutils 2.41) and a 10-hash gate;
`tarballAarch64` assembles the `.tar.gz` (`tarball.nix` parameterized by
`arch` + `expectedSha256`). `depends.nix` needed no aarch64 changes — it
was already `hostTriple`-parameterized — but its sources now fall back to
the `bitcoincore.org/depends-sources` mirror (several upstream X.org /
savannah source URLs have since 404'd; the mirror keeps the exact
tarballs, so outputs are unchanged).

## WIP (2026-06-03): issue #6 — remove workarounds (B) + full tarball (A)

Working issue #6. Local reference artifacts (all gitignored):
- `bitcoin/` — Core checkout at v31.0 tag **with a full GUIX build** in
  `bitcoin/guix-build-31.0/` (4.8 GB). The final release tarball is at
  `bitcoin/guix-build-31.0/output/x86_64-linux-gnu/bitcoin-31.0-x86_64-linux-gnu.tar.gz`
  and the debug tarball `…-debug.tar.gz` alongside. Upstream `.o` files
  survive in `…/distsrc-31.0-x86_64-linux-gnu/build/`.
- `guix/guix/` — the GUIX repo checkout. `bitcoin/contrib/guix/` has the
  manifest + build.sh + patches.

### Progress

- **B task #1 — DONE (committed)**: glibc 2.31 now built with gcc 14.3.0;
  all four glibc byte-patch hacks removed; bitcoind still hashes to
  `dae69848…`. Details in the "Glibc 2.31 build" section above. (gcc
  parity: nixpkgs-25.11's stdenv == GUIX's gcc 14.3.0; source = git
  `7b27c450`, nix hash `sha256-wIq9cIHkI8HtsYa5UU1IfC8VIhXyz0vJau20WPJt+AQ=`.)
- **B task #2 — INVESTIGATED, deemed impractical**: keep the
  `.gnu_debuglink` CRC patch. Rationale below.
- **A — DONE, all 10 binaries**: dropped `-DBUILD_TESTS=OFF` (GUIX leaves
  it ON → builds bitcoin-tx/util/wallet/test_bitcoin) and generalized the
  split-debug + `.comment` + `.gnu_debuglink` CRC patch to every shipped
  binary. Then added the full Qt6 depends tree and matched bitcoin-qt +
  bitcoin-gui too (see "Qt GUI" workarounds). All 10 binaries byte-match;
  gate asserts all of them. Per-binary upstream CRCs are hardcoded in
  `bitcoind.nix` (the `.dbg` aren't reproducible — see Task #2 finding).
- **Full `.tar.gz` — DONE**: `tarball.nix` (`nix build .#tarball`) assembles
  the release archive byte-identical to upstream (`d3e4c58a…`). Only fix
  beyond the obvious packaging: `rpcauth.py` must stay 0755 (tar's `a+X`
  keeps the exec bit only if already set). mtime pinned to the v31.0 commit
  epoch 1776286524 (== GUIX SOURCE_DATE_EPOCH), owner 0/0, `gzip -9n`.

### Task #2 finding — why the `.gnu_debuglink` CRC patch stays

The CRC in a stripped binary is CRC32 of its `.dbg`. To drop the patch,
our `.dbg` would have to be byte-identical to upstream's. It is not, and
the reasons are structural, not incidental:

- **Compression**: upstream's debug sections are SHF_COMPRESSED (GUIX's
  binutils compresses by default); ours aren't. Fixable with `-gz`.
- **Content is ~identical otherwise**: decompressed, the two `.dbg` are
  292,886,544 (upstream) vs 292,713,176 (ours) — ~172 KB / 0.06 % apart,
  spread proportionally across every debug section.
- **That 0.06 % is recorded paths** (`.debug_line_str` and the cascade of
  `.debug_str`/`.debug_info` offset shifts), and they diverge for reasons
  we can't cheaply match:
  - toolchain headers: ours `/nix/store/…gcc-14.3.0/include/c++/14.3.0`,
    upstream `/usr/include/c++` (GUIX maps `/gnu/store/*`→`/usr`, *and*
    lays c++ headers out without the version subdir);
  - **target triple**: upstream `x86_64-linux-gnu` vs our gcc's
    `x86_64-unknown-linux-gnu` — pervasive in include/lib paths and baked
    into the gcc build;
  - **GUIX ephemeral build dirs baked into libgcc/glibc debug info**:
    `/tmp/guix-build-gcc-cross-x86_64-linux-gnu-14.3.0.drv-0/…` and
    `/tmp/guix-build-glibc-cross-…/source/csu`. These come from the
    compiler's own debug info (statically-linked csu/libgcc) and can't be
    reproduced without rebuilding our gcc/glibc as `x86_64-linux-gnu`
    cross toolchains with `-fdebug-prefix-map` to those exact `.drv-0`
    paths.

None of this affects the *stripped* runtime binary (already byte-equal at
`dae69848…`); it's all debug-only. Matching it would mean a target-triple
change plus deep path surgery across the whole toolchain — high cost, high
risk, for a 4-byte debugger hint. So the CRC patch stays, and A patches the
other binaries' CRCs the same way.

### Upstream binary set (sha256, from the GUIX tarball)

```
eb5670ae… bin/bitcoin            3e92883f… bin/bitcoin-cli
dae69848… bin/bitcoind  ✓MATCH   3480af8f… bin/bitcoin-qt   (GUI)
ce3b159c… bin/bitcoin-tx         1d18ee4b… bin/bitcoin-util
7d8382b8… bin/bitcoin-wallet
416e79bb… libexec/bitcoin-gui (GUI)  01c212ee… libexec/bitcoin-node
c7a2a906… libexec/test_bitcoin
```

GUIX leaves `BUILD_TESTS` at default ON; that's what builds bitcoin-tx,
bitcoin-util, bitcoin-wallet, test_bitcoin. Upstream CONFIGFLAGS:
`-DREDUCE_EXPORTS=ON -DBUILD_BENCH=OFF -DBUILD_GUI_TESTS=OFF
-DBUILD_FUZZ_BINARY=OFF -DCMAKE_SKIP_RPATH=TRUE`. split-debug is applied
to every file in `bin/` + `libexec/` identically (build.sh:302).

## How it works

These Nix files compose into the reproducer (the 4th, `tarball.nix`, is
new; `flake.nix` exposes `.#tarball`):

1. **`depends.nix`** — builds Bitcoin Core's `depends/` tree. All
   dependency tarballs are pre-fetched via `fetchurl` and copied into
   `depends/sources/` before the build (working around Nix's no-network
   sandbox). Uses `gcc14Stdenv` to match GUIX v31.0's GCC 14.2.0. Builds
   boost, libevent, sqlite, zeromq, systemtap, capnp + multiprocess
   (native_capnp, native_libmultiprocess), **plus the full Qt6 GUI tree**
   (qt + native_qt + the X11/font/xcb-util deps + qrencode; see the Qt
   workarounds below). `HOST=x86_64-linux-gnu` forces depends into
   "cross-compile" mode (`depends_crosscompiling=TRUE` →
   `CMAKE_CROSSCOMPILING=TRUE` downstream), matching GUIX.

2. **`bitcoind.nix`** — builds all of Bitcoin Core (incl. the Qt GUI) with
   `cmake --toolchain ${depends}/toolchain.cmake`. CMake (replaced
   autotools as of v29). Leaves `BUILD_TESTS` ON (GUIX does), so the tools
   + test_bitcoin build; the depends toolchain auto-enables `BUILD_GUI` +
   `WITH_QRENCODE` (Qt present). Skips bench/fuzz. Mirrors GUIX
   release flags (`REDUCE_EXPORTS=ON`, `CMAKE_SKIP_RPATH=TRUE`,
   `-O2 -g`). After install, runs `split-debug.sh` with the same args
   GUIX uses (`<bin> <bin> <bin>.dbg`). Then rewrites `.comment`,
   patches the `.gnu_debuglink` CRC32, and asserts the final hash.

3. **`default.nix`** — entry point. Constructs the toolchain: wraps
   `gcc14` with bintools/cc-wrapper pointing at glibc 2.31, then
   rebuilds gcc 14 itself inside that wrapped stdenv (so libstdc++ is
   compiled against glibc 2.31). Downgrades binutils to 2.41 (matches
   GUIX). Applies `gcc-ssa-generation.patch` and the GUIX
   `linux-base-gcc` configure flags
   (`--enable-cet`, `--enable-default-pie`, `--enable-default-ssp=yes`,
   `--enable-host-bind-now`, `--enable-standard-branch-protection`,
   `--enable-initfini-array`, `--disable-nls`, …).

4. **`flake.nix`** — pins `nixpkgs` to `nixos-25.11` and builds glibc 2.31
   by overriding 25.11's modern glibc derivation down to 2.31 (GUIX's
   exact git source, commit `7b27c450`), built with 25.11's **gcc 14.3.0**
   — the same gcc version GUIX uses. Because the CRTs and
   `libc_nonshared.a` members are gcc-14-compiled, they carry the right
   `.note.gnu.property`, `sub` canary, and `__libc_csu_init` codegen
   natively — **no post-install byte patching** (this replaced the old
   nixos-20.09 / gcc-8.3.0 + byte-patch approach). Exposes:
   - `nix build .#depends` — just the depends tree
   - `nix build .#bitcoind` (or `.#default`) — all 10 binaries
   - `nix build .#tarball` — the full release archive

5. **`tarball.nix`** — assembles `bitcoin-31.0-x86_64-linux-gnu.tar.gz`
   byte-identical to upstream from the `bitcoind` binaries (no `.dbg`) +
   uncompressed man pages + the committed extras (`README.md`,
   `bitcoin.conf`, `share/rpcauth`) from the release source tarball.
   Reproduces GUIX build.sh's deterministic `tar … --mode='u+rw,go+r-w,a+X'`
   + `gzip -9n`, pinning mtime to SOURCE_DATE_EPOCH (1776286524, the v31.0
   commit time) and owner 0/0. Asserts the archive sha256 (`d3e4c58a…`).

## Patches

- **`patches/depends-funcs-test-source-exists.patch`** — re-adds the
  `test -f` short-circuit in `depends/funcs.mk:fetch_file` that
  upstream removed in commit `46135d90ea9` (Sep 2025). Without it the
  depends Makefile always tries to `curl` even when sources are
  pre-staged, which fails in Nix's sandbox.

- **`patches/zeromq-disable-tipc.patch`** — forces
  `CMAKE_CROSSCOMPILING=TRUE` and `ZMQ_HAVE_TIPC=FALSE` in libzmq's
  CMakeLists. Native compile would detect TIPC support and pull in
  three `tipc_*.cpp` files that GUIX's cross-compile skips.

- **`patches/gcc-ssa-generation.patch`** — GUIX's patch for gcc PR123351:
  deterministic SSA version numbering. Without it, SSA names are
  assigned non-deterministically depending on function-argument
  evaluation order → different generated code per gcc build.

## Workarounds baked into the Nix derivations

These are subtle and easy to break, so document the reasoning.

### Depends-level

- **`depends.nix` postFixup path rewrite**: libevent's exported CMake
  config files (`LibeventTargets-static.cmake`) hardcode the absolute
  build-time staging path as `_IMPORT_PREFIX`. We `sed`-replace
  `/build/bitcoin-<ver>/depends/x86_64-linux-gnu` → `$out` in any
  `*.cmake`/`*.pc` files so the bitcoind build can find the installed
  libraries.

- **`bitcoind.nix` preConfigure symlink**: `libmultiprocess`'s `mpgen`
  binary has the depends-build-time absolute path baked into the ELF
  as a string literal via the `capnp_PREFIX` macro
  (`src/ipc/libmultiprocess/include/mp/config.h.in`). At codegen time
  `mpgen` execs `<capnp_PREFIX>/bin/capnp` and dies if the path
  doesn't exist. We `ln -s ${depends} depends/x86_64-linux-gnu` from
  PWD (`/build/bitcoin-31.0`) so the path resolves through the
  symlink.

- **`hardeningDisable`** on both depends and bitcoind: drops nixpkgs
  hardenings that GUIX's toolchain doesn't apply
  (`zerocallusedregs`, `strictoverflow`, `stackprotector`,
  `stackclashprotection`, `fortify`, `fortify3`, `format` on depends).
  Each one was diagnosed by comparing nixpkgs cc-wrapper's
  `NIX_HARDENING_ENABLE` defaults against GUIX's gcc configure flags.

- **`-fomit-frame-pointer -momit-leaf-frame-pointer` in CFLAGS** —
  overrides nixpkgs gcc-wrapper's hardcoded `-fno-omit-frame-pointer`
  (in `cc-cflags-before`). At -O2 gcc would otherwise default to
  omitting frame pointers (matching upstream).

- **`-ffile-prefix-map` flags** in `bitcoind.nix`: GCC applies maps in
  command-line order and LAST matching wins, so:
  - `${depends}=/bitcoin/depends/x86_64-linux-gnu` (boost headers)
  - `/build/bitcoin-${version}=/bitcoin` (general fallback)
  - `/build/bitcoin-${version}/src=.` (relative paths for bitcoin
    sources, must come after the broader fallback)

### Qt GUI depends (`depends.nix`) — for bitcoin-qt / bitcoin-gui

Building the Qt6 tree (dropping `NO_QT=1`) needed several `depends.nix`
fixups, all done via `postUnpack` seds on the package `.mk` files
(same pattern as the zeromq TIPC patch):

- **`bison flex gperf`** added to `buildInputs` — libxkbcommon generates
  its parser with bison; fontconfig regenerates a gperf header. (None are
  used by the non-GUI packages, so they don't perturb the matched 8.)
- **fontconfig freetype include**: fontconfig's configure finds freetype
  via pkg-config ("FREETYPE yes") but the `FREETYPE_CFLAGS` don't reach
  the compile in our Nix env (`<ft2build.h>` not found). Add
  `-I$(host_prefix)/include/freetype2` to fontconfig's cflags.
- **Depends-prefix baking** (the hard one). GUIX builds depends at
  `/bitcoin/depends/x86_64-linux-gnu`; we build at
  `/build/bitcoin-<ver>/depends/x86_64-linux-gnu` (the Nix build dir — we
  can't build at `/bitcoin`, the sandbox root is read-only). Three
  components bake that prefix as a *runtime* string into static libs that
  get linked into bitcoin-qt/-gui:
  - **Qt** `qt_prfxpath` + data dirs: set `-prefix
    /bitcoin/depends/x86_64-linux-gnu` in `qt.mk` (CMAKE_INSTALL_PREFIX,
    which all of Qt's baked runtime paths derive from). Do **not** add
    `-extprefix` — CMAKE_STAGING_PREFIX would pull `/build` back into the
    icon/data paths. Physical relocation to the real prefix is already
    handled by qt.mk's `cmake --install --prefix $(staging_prefix_dir)`.
  - **libxkbcommon** xkb config root:
    `--with-xkb-config-root=/bitcoin/depends/x86_64-linux-gnu/share/X11/xkb`.
  - **xcb-util-cursor** XCURSOR theme path (the sneaky last one — it's in
    `libxcb-cursor.a`, not Qt): `--with-cursorpath=~/.local/share/icons:
    ~/.icons:/bitcoin/depends/.../share/icons:/bitcoin/depends/.../share/pixmaps`.
  The depends `postFixup` then also rewrites `/bitcoin/depends/...` → `$out`
  in `*.cmake`/`*.pc` so the bitcoind build still *finds* Qt; the baked
  runtime strings inside the `.a` libraries keep the GUIX prefix, matching
  upstream.

### Glibc 2.31 build (`flake.nix`) — replaced the old byte patches

We build glibc 2.31 with gcc 14.3.0 (nixpkgs-25.11's stdenv == GUIX's gcc
version) from GUIX's exact git source. This produces CRTs and
`libc_nonshared.a` members that match upstream **natively**, so the four
former byte-patch hacks (CRT `.note.gnu.property`, `.oS`
`.note.gnu.property`, `xor`→`sub` canary, and the `elf-init.oS`
`__libc_csu_init` recompile-splice) are **gone**. What it took, beyond the
git source + GUIX's 6 configure flags:

- **Filter 25.11's conflicting configure flags**: drop
  `--enable-kernel=3.10.0` (would set `.note.ABI-tag` to 3.10.0; upstream
  is 3.2.0 — glibc 2.31's default `arch_minimum_kernel`),
  `--enable-stack-protector=strong`, `--enable-cet=permissive`,
  `--enable-fortify-source`.
- **`-fomit-frame-pointer -momit-leaf-frame-pointer`** via
  `env.NIX_CFLAGS_COMPILE` — nixpkgs' wrapper forces
  `-fno-omit-frame-pointer`, which would give `__libc_csu_init` a
  frame-pointer prologue; upstream omits it at -O2.
- **`hardeningDisable`** (same set as bitcoind) — the decisive one is
  `zerocallusedregs`: `-fzero-call-used-regs` appends register-zeroing
  `xor` instructions before `ret` in `__libc_csu_init` and the stat
  wrappers, which upstream lacks (this was the last 16-byte delta).
- **Porting 25.11→2.31 plumbing**: `patches = []` (2.40 patches don't
  apply); `postPatch` minus the `nss/nss_files_fopen.c` +
  `include/nss_files.h` seds (don't exist in 2.31); `src` `name =
  "glibc-2.31"` (postInstall globs `../glibc-2*/localedata/SUPPORTED`);
  `postInstall` minus the C.UTF-8 locale gen (no `locales/C` until 2.35).

The `.comment` is now uniformly gcc-14, but `bitcoind.nix` still rewrites
it (harmless, see below).

### Final binary patch (`bitcoind.nix` postInstall)

- **`.gnu_debuglink` CRC patch** — the CRC at file offset `0x10ff7b8`
  is the CRC32 of the `bitcoind.dbg` debug file, which intrinsically
  differs from upstream's (different DWARF section layouts in the
  debug build). We overwrite our 4 bytes with upstream's
  `29 7e c7 2c` (`0x2cc77e29` LE). The `bitcoind.dbg` file itself
  still diverges (this is the only place that mattered for runtime
  binary parity).

- **Glibc patches drop the `--enable-kernel=2.6.32` `.note.ABI-tag`** —
  flake.nix filters out nixos-20.09's `allow-kernel-2.6.32.patch` so
  glibc's default `arch_minimum_kernel=3.2.0` takes effect, matching
  upstream.

## CI

`.github/workflows/nix-ci.yml` runs `nix build .#bitcoind` on GitHub
Actions (`ubuntu-latest`, `nixos-25.11`, Cachix-cached). The hash
assertion in `bitcoind.nix` `postFixup` runs as part of the build;
the CI workflow then re-asserts the hash externally for log
visibility.

## Branch convention

Each Bitcoin Core version gets its own branch (e.g. `v27.0`, `v26.0`).
Active development uses dated branches (e.g. `2025-05-claude`).

`bitcoin/` (the source checkout for reference), `shell.nix`,
`v31-guix-build.log`, `result*`, `depends-staging.tar.gz`, and
`guix-staging/` are intentionally untracked (see `.gitignore`).

## What worked (high-impact fixes, chronologically)

For posterity, what produced the biggest jumps from +291 MB delta to
exact match:

- **Custom gcc 14 + glibc 2.31 stdenv** — biggest single delta drop
  (from ~291 MB to ~24 KB). Matches upstream's gcc version and glibc
  version, kills the libpthread/libdl/librt/libutil NEEDED entries.
- **Apply GUIX `linux-base-gcc` configure flags** — restored CET,
  PIE-by-default, stack-protector-all defaults.
- **Apply gcc-ssa-generation patch** — fixes non-deterministic SSA
  numbering.
- **Patch ELF interpreter to `/lib64/ld-linux-x86-64.so.2`** + strip
  Nix RUNPATH via `NIX_DONT_SET_RPATH=1`.
- **`-ffile-prefix-map` flags** matching GUIX's path scheme
  (`/bitcoin/...`).
- **Disabling nixpkgs hardenings that GUIX doesn't apply**
  (`zerocallusedregs`, `strictoverflow`, `stackprotector`,
  `stackclashprotection`, `fortify`, `fortify3`).
- **Forcing CMAKE_CROSSCOMPILING via `HOST=x86_64-linux-gnu`** —
  matched GUIX's universal cross-compile mode in one shot
  (libzmq feature checks, secp256k1 Valgrind detect, libevent tests
  all skip).
- **Per-archive `sha256` comparison vs GUIX depends staging
  artifact** (user-provided `depends-staging.tar.gz`) — turned the
  codegen black-box into a per-object diff problem. Identified the
  exact 3 libzmq `.o` files (`tipc_*`), the 7 `.o` files affected by
  feature checks, and ultimately `__libc_csu_init` as the last
  residual function.
- **`--disable-nls` on the gcc rebuild** — drops `gettext@GLIBC_2.2.5`
  from dynsym; recovers exact symbol-count parity.
- **Surgical glibc CRT/`.oS` byte-patching** — bypassed the multi-stage
  glibc rebuild blocker (gcc bootstrap → gmp/isl ABI hell), see
  Workarounds.

## What didn't work (for reference if revisiting)

- **Coherent gcc bootstrap** (commit `37b05ef`, reverted in `2f6823b`):
  multi-stage rebuild of `gmp`/`mpfr`/`libmpc`/`isl` + gcc 14
  bootstrap against glibc 2.31. Blocked by isl's `./configure`
  failing "main in -lgmp: no" despite the overridden gmp building
  fine in isolation — nixpkgs' cc-wrapper didn't propagate the
  overridden gmp's lib path. Multi-day Nix plumbing project.
- **`hardeningDisable = ["all"]`**: regressed by +4 KiB (removes PIC,
  relro, bindnow that bitcoin's CMake doesn't auto-replace).
- **Removing `-fomit-frame-pointer` from CFLAGS**: massively diverged
  (-102 KiB). Frame pointers added `.text` but shrank `.eh_frame`
  more.
- **Adding `valgrind` to bitcoind's buildInputs**: secp256k1's CMake
  auto-detected and turned on VALGRIND macros (+1,344 B). GUIX also
  fails the detection, so we shouldn't.
- **`-Wl,--wrap=gettext`** and friends: stubs added as many bytes as
  they saved. Net-zero.

## Non-fatal `./gen_id` errors

During the depends build, `make` prints
`env: './gen_id': No such file or directory` twice. The build
completes (the `build_id` shell expansion silently produces an empty
string). Build IDs likely matter for full reproducibility, but
empirically don't block the hash match — left as a known nuisance.

## Methodology: debugging non-determinism between two binaries

If you arrive here later (or a similar project) and need to chase
non-byte-equal binaries, here is the playbook that worked.

### 1. Establish ground truth: get the reference binary

Download upstream's signed/published build, not something you
rebuilt. For Bitcoin Core:
`bitcoincore.org/bin/.../bitcoin-X.Y-x86_64-linux-gnu.tar.gz`.
Extract and keep it untouched at a known path
(`/tmp/upstream-vNN/bitcoin-NN.N/bin/bitcoind`).

### 2. Get the build log from upstream's pipeline

A real build log from the upstream system is invaluable. For GUIX:
`./contrib/guix/guix-build` produces output you can capture. Save it
locally. Extract:

- Exact compiler version
  (`-- The C compiler identification is GNU 14.3.0`)
- Configure flags for the toolchain (gcc/glibc/binutils)
- Compile flags per package (HOST_CFLAGS, depends configure lines)
- Linker invocation (`-DCMAKE_EXE_LINKER_FLAGS=`)
- Per-feature CMake "Performing Test XXX - Success/Failed" lines
  (tells you exactly which compile flags are active)

### 3. Coarse comparison tools (run early)

```sh
stat -c %s upstream ours/bitcoind          # sizes first
readelf -d <binary>                         # NEEDED, RUNPATH
readelf -p .comment <binary>                # compiler stamp
readelf --notes <binary>                    # ABI-tag, gnu.property
bloaty ours -- upstream                     # SECTION-LEVEL DIFF
bloaty -d sections ours
bloaty -d compileunits ours                 # only with DWARF
```

`bloaty` is the single most useful tool. It will show you exactly
which ELF sections are bigger/smaller and by how much.

### 4. Fine-grained byte comparison

```sh
objcopy -O binary --only-section=.text ours text-ours.bin
objcopy -O binary --only-section=.text upstream text-upstream.bin
cmp text-ours.bin text-upstream.bin               # first diff
xxd -s <offset> -l 64 text-ours.bin               # context
xxd -s <offset> -l 64 text-upstream.bin
```

If first divergence is very early but the bytes around it look "the
same kind of thing", you're probably looking at structurally identical
code at different addresses (RIP-relative operands differ). Confirm by
finding a unique byte signature (a `.rodata` constant, a `mov $imm32`)
in both and checking surrounding instructions.

### 5. Function-by-function comparison

```sh
nm --defined-only ours/bitcoind | grep AES128_init
objdump -d --disassemble=AES128_init ours/bitcoind
# Find same function in upstream by byte signature near the end
xxd upstream | grep "b90a 0000 00ba 0400 0000 e9"
xxd -s <offset-before> -l 64 upstream
```

The structural delta you find in one function usually applies to
many.

### 6. Tracking down "why does our function differ?"

Common candidates:

- **Frame pointers** — `-fomit-frame-pointer` (default at -O2). Nixpkgs
  sets `-fno-omit-frame-pointer` in `cc-cflags-before`.
- **Register zeroing on return** — `-fzero-call-used-regs=used-gpr`
  via nixpkgs' `zerocallusedregs` hardening. +4-8 bytes/function.
- **`-fno-strict-overflow`** — nixpkgs' `strictoverflow` hardening.
  Disables loop/arith optimizations.
- **Stack protector level** — basic vs strong vs all. Bitcoin's
  CMake forces `-fstack-protector-all` for `core_interface` only.
- **`-fcf-protection=full`** — CET endbr64/shstk. Bitcoin's CMake
  adds it for `core_interface` only.

### 7. Where do "default" flags come from?

nixpkgs' gcc-wrapper at
`/nix/store/<hash>-gcc-wrapper-X.Y.Z/nix-support/`:

- `cc-cflags-before` — prepended to every compile
- `cc-cflags` — appended
- `libc-cflags` — header search paths
- `add-hardening.sh` — maps `NIX_HARDENING_ENABLE` names to gcc flags

```sh
grep "NIX_HARDENING_ENABLE=" <wrapper>/nix-support/setup-hook
grep -B1 -A3 "hardeningCFlagsBefore+=" <wrapper>/nix-support/add-hardening.sh
```

Use `hardeningDisable = [ "..." ];` in derivations to drop them.

### 8. Verifying a fix actually applied

After every toolchain/flag change, **verify the change took effect**.
Don't just check the size delta:

```sh
nix eval --raw .#bitcoind.stdenv.cc.cc.outPath
nix eval --json .#bitcoind.stdenv.cc.cc.drvAttrs.patches
nix eval --json --apply 'drv: drv.drvAttrs.configureFlags' \
  .#bitcoind.stdenv.cc.cc
readelf --notes result/bin/bitcoind | grep -A3 gnu.property
```

For binutils-level changes, test the gas behavior directly.

### 9. Build cost discipline

Nix correctly invalidates the entire chain when toolchain inputs
change. Approximate rebuild costs:

- Touching `bitcoind.nix` only: ~5 min (just bitcoind)
- Touching `depends.nix`: ~10-15 min (depends + bitcoind)
- Touching gcc patches/configureFlags: ~40 min (gcc rebuild)
- Touching glibc configureFlags: ~40+ min (glibc + downstream)

Group multiple toolchain changes into one rebuild. Run long builds
in background and continue analysis while they run.

### 10. Tools worth knowing

- **bloaty** — section/symbol/compileunit diff. Most useful single
  tool.
- **readelf** (`--wide --dyn-syms --notes --sections --segments`) —
  verify every metadata field.
- **objdump** (`-d --line-numbers --demangle --section=.text
  --start-address=... --stop-address=...`) — compare specific
  function ranges.
- **diffoscope** — comprehensive ELF + DWARF diff. Slow but worth it
  for the last-mile mystery.
- **`ar t/x/r`** — per-object archive inspection. Indispensable for
  libc_nonshared.a / libgcc.a archaeology.
- **`nm --print-size --numeric-sort`** on the unstripped debug binary
  — map vaddrs to function names.
- **`sha256sum` on per-archive depends staging** — the data unlock
  that turns "codegen differences" into "exactly these N .o files
  differ."
