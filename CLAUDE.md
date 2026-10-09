# bitcoind-gunix

## Goal

Reproduce Bitcoin Core's GUIX release artifacts byte-for-byte with Nix, for
every GUIX host: x86_64/aarch64/riscv64/armhf/powerpc64 linux, x86_64/arm64
darwin, and win64. Project tracking:
https://github.com/0xB10C/bitcoind-gunix/issues/1.

The dated status journal that used to live here (v23 → v31.1 → the v32.x
branch-off, ~2600 lines) is in git history: see CLAUDE.md at commit
`90e0ff24483c` and earlier. This file keeps the current state, how the tree
is built, the root causes that matter, and the method.

## Current state (2026-10-09)

- **Target:** the `v32.0rc3` tag (`2633a1ded5cd`), guix time-machine pin
  `c5eee3336cc1` (UNCHANGED since rc1). `version = "32.0rc3"`,
  `sourceDateEpoch = 1790872883`, src
  `sha256-IjnYm1qV2lVOYClwDZvhRi7We8wGZQh1aP01U/laSX0=`. Reference hashes:
  the rc3 guix.sigs attestations — all 13 signers published a byte-identical
  `noncodesigned.SHA256SUMS`, 11 of them a byte-identical `all.SHA256SUMS`;
  both are checked in at the repo root.
- **rc2 → rc3 is the smallest delta yet** (28 commits): `contrib/guix/` and
  `depends/` are untouched ENTIRELY, so every toolchain pin and every
  packaging script is the one rc2 was verified against. `depends/` has in
  fact not moved since the branch-off, which makes the GUIX win64 depends
  tree at `/home/infra/guix-ref-f3fec67c3eeb/bitcoin/depends/x86_64-w64-mingw32`
  the exact tree rc3 builds against (all 4106 of its headers verified
  byte-identical to ours). Source changes: fee-estimator fallbacks, wallet
  descriptor hashing, net/net_processing, init, a new logging category,
  generated docs/man + share/examples, tests and CI.
- **Detached signatures:** bitcoin-detached-sigs `v32.0rc3` (tag `c77aa3c5`,
  peels to `146215d4`) already carries both `osx/` and `win/`, so all 28
  artifacts are gated from the first build — unlike rc2, which needed the
  signed set wired up in a second commit.
- **22 of the 28 artifacts reproduce** (verified 2026-10-09, one
  `nix build`): the source dist archive, all 5 linux release + 5 debug
  tarballs, all 10 darwin artifacts INCLUDING the signed ones, and the
  codesignatures archive. x86_64 keeps `distsrcChroot = true`.
- **The 6 win64 artifacts do NOT reproduce** (4 unsigned + the 2 signed
  derived from them) — a single var-tracking location list in a single CU.
  Localized to the byte; see the `win64 at v32.0rc3` entry in the
  GGC/var-tracking section of the root-cause catalogue for the evidence,
  the ten hypotheses ruled out, the single-CU replay harness, and what is
  still missing to close it.
- **The branch-off commit** was verified against a local guix build (the
  user's `/home/infra/guix-ref-f3fec67c3eeb/bitcoin/`, 35 GB: outputs, the
  GUI-pass `distsrc-*/build` trees with CMakeCache.txt and objects, the
  depends caches) — still the oracle for single-CU replays, since the
  toolchains are identical. Its win64 `CMakeCache.txt` is also the only
  local record of GUIX's real `/gnu/store` toolchain paths and of the ~90
  `-ffile-prefix-map` arguments build.sh generates from `find /gnu/store`.
- **Published rc artifacts are downloadable**, which gives byte-level
  oracles even without a local guix build:
  `https://bitcoincore.org/bin/bitcoin-core-32.0/test.rc3/` carries all 28
  files (both win64 zips verified against the attestation on 2026-10-09 and
  kept in `/home/infra/rc3-reference/`). Note the directory is
  `bitcoin-core-<final version>/test.rc<N>/`, not `bitcoin-core-<rc>/`.
- **All 21 attested non-codesigned artifacts** are gated, checked with one
  `nix build` over all of them:
  - the source dist archive `bitcoin-32.0rc3.tar.gz` (`sourceDistArchive`:
    GitHub's tag archive re-gzipped with `gzip6.c`)
  - 5 linux release + 5 debug tarballs (`tarball`, `debugTarball`, and the
    `Aarch64`/`Riscv64`/`Armhf`/`Ppc64` variants)
  - darwin x86_64/arm64 `-unsigned.tar.gz`, `-unsigned.zip`,
    `-codesigning.tar.gz` (`tarballDarwin*`, `zipDarwin*`, `codesigningDarwin*`)
  - win64 `unsignedZipMingw`, `debugZipMingw`, `setupExeMingw`, `codesigningMingw`
- **Signed artifacts are wired up AND gated** against bitcoin-detached-sigs
  `v32.0rc3`: `signedDarwinX86`/`signedDarwinArm64` (2 each), `signedMingw`
  (2), plus `codesignaturesArchive`. win64 needs osslsigncode **2.14**
  (`osslsigncode214`), per rc2's `manifest_codesign.scm` (unchanged at rc3);
  `codesign.sh`'s `osslsigncode verify` pass only re-reads what
  `attach-signature` already wrote, so it cannot change the emitted bytes
  (see the win64 note on 2.14's `-CAfile` removal).
- **Aggregators:** `.#noncodesignedSha256sums` (21 artifacts) and
  `.#sha256sums` (all 28), each diffed against its checked-in attestation.
  (For an UNTAGGED commit the dist archive can't be
  built: GitHub's commit archive uses a 40-char prefix, which changes the
  pax long-path headers.)
- **Gates:** every artifact derivation looks its expected sha256 up by
  published filename in the git-tracked `noncodesigned.SHA256SUMS` (+ an
  optional `all.SHA256SUMS`); a missing filename builds ungated with a log line.
  `.#noncodesignedSha256sums` (the flake default) builds all 21 and writes
  the file in upstream order, failing unless it equals the checked-in file.

## How the tree is built

- `flake.nix` pins nixos-26.05 and exposes `packages.{x86_64,aarch64}-linux.*`
  (attr names = TARGET; "cross everywhere": the same definitions build every
  target from either build host). All logic is in `default.nix` + `nix/`.
- `default.nix`: the source (GitHub's commit archive repacked under the
  DISTNAME prefix `bitcoin-${version}/`), the SHA256SUMS lookup, and one
  `nix/<target>/toolchain.nix` per GUIX host.
- **linux:** `nix/x86_64-linux-gnu/` and `nix/aarch64-linux-gnu/` have bespoke
  toolchain definitions; riscv64/armhf/ppc64 call the generator
  `nix/lib/linux-cross-target.nix`. Each builds a GUIX-exact cross trio —
  binutils (`lib/cross-binutils-246.nix`), glibc 2.31, gcc 14.3.0 — then
  `lib/depends.nix`, two `lib/release-cross.nix` passes, `lib/package.nix`,
  and `lib/artifact.nix` gates.
- **Two passes per platform**, like upstream's `build_<os>.sh` +
  `build_<os>_gui.sh`: a `NO_QT` depends tree with `-DBUILD_GUI=OFF`, then the
  full Qt depends tree building only `bitcoin-gui`/`bitcoin-qt` (win64: only
  `bitcoin-qt`). Both install into one prefix.
- **Upstream scripts we RUN:** `contrib/guix/libexec/setup.sh` is sourced
  (sandbox-safe copy made by `nix/lib/guix-setup.sh`, which asserts its three
  rewrites: two `/usr/bin` lines, and the quotes around TAR_OPTIONS' `--mtime`
  that crash nixpkgs' tar); `libexec/package.sh` runs verbatim up to its
  trailing outdir block (split-debug, security/symbol checks, archives, the
  NSIS installer, codesigning tarballs); `split-debug.sh.in` and
  `GenerateWindowsInstaller.cmake.in` are configure_file'd by hand;
  `cmake/script/macos_zip.sh` is used directly.
- **Upstream scripts we cannot run:** `build_{linux,macos,win}{,_gui}.sh` —
  their `HOST_CFLAGS` come from `find /gnu/store` (no store → no prefix maps),
  their toolchain paths from `$GUIX_ENVIRONMENT/manifest`, and they run depends
  in-tree. Our targeted prefix maps emulate their result.
- **darwin:** `nix/darwin/toolchain.nix` + `release.nix`; both passes and
  package.sh run inside ONE unshare/userns chroot at guix's literal paths
  (package.sh's `deploy` target needs the GUI pass's build tree).
- **win64:** `nix/win64/toolchain.nix` (mingw toolchain, CRT, depends, both
  passes, packaging), `release.nix` (one pass), `nsis-toolchain.nix`.

## Toolchain pins (guix `c5eee3336cc1` + contrib/guix manifest_build.scm)

- **linux:** cross binutils 2.46.0 (fresh origin, `--enable-gprofng=no`,
  `--enable-compressed-debug-sections=all`, bundled zlib); linux-libre headers
  6.1.166 (vanilla 6.1.166 uapi headers are equivalent); glibc 2.31 at commit
  `28eb5caf` with guix's configure flags incl. `--enable-kernel=3.17.0`,
  `--enable-stack-protector=all`, x86 `--enable-cet`; gcc 14.3.0 with
  linux-base-gcc flags (`--enable-default-pie/ssp`, `--enable-host-bind-now`,
  `--enable-initfini-array`, `--disable-{gcov,libgomp,libquadmath,libsanitizer,lto,nls,tm-clone-registry}`,
  x86 `--enable-cet`, aarch64 `--enable-standard-branch-protection`) +
  `gcc-ssa-generation.patch`. armhf adds guix's triplet flags
  (`--with-arch=armv7-a --with-mode=thumb --with-fpu=neon`).
- **win64:** mingw-w64 13.0.0 msvcrt with POSIX threads (winpthreads merged
  into the cross libc); mingw-w64-base-gcc 14.3.0; final binutils 2.46.0 +
  `binutils-unaligned-default.patch`; CRT/winpthreads and NSIS stubs use guix's
  DEFAULT cross binutils 2.44 (+ its four patches) and a plain gcc-14; NSIS 3.11.
- **darwin:** clang/lld/libcxx 19.1.7 (= nixpkgs `llvmPackages_19`), bare
  (no cc-wrapper), Xcode 26.1.1 extracted SDK.

## Root-cause catalogue

Every entry was verified at the byte/section level before it was fixed. The
pattern to remember: identical code with different metadata is almost always
a path, a recorded flag, a generated file, or an allocation-order effect.

### Recorded paths and flags (linux + win64 `.dbg`)
- `DW_AT_producer` records every explicit flag: use NoFp cc-wrapper variants
  (strip `-fno-omit-frame-pointer`/`-mno-omit-leaf-frame-pointer` instead of
  adding `-fomit-*`), drop nixpkgs' `-frandom-seed`, build RelWithDebInfo,
  filter aarch64's configured `--with-arch=armv8-a` (the driver self-injects
  `-march`), and bake default-PIE / branch protection into the glibc CC.
- Comp dirs and header paths: DISTSRC = `/distsrc-base/distsrc-<ver>-<host>`,
  store → `/usr` header maps (c++ headers version-less), glibc/libgcc built
  with guix's `/tmp/guix-build-*.drv-0` ephemeral dirs mapped in, libgcc `-g`
  multiplicity, libstdc++/libsupc++ archives strip-debug'd.
- Kernel header VERSION leaks (enum DIEs), so the headers track the pin.
- Qt's posix shm/sem configure checks fail in the sandbox → preseeded (two
  feature-gated empty objects' STT_FILE entries).
- win64 PE: no compressed debug sections in the final binutils (COMDAT
  `.debug_frame$` selection), in-source split mingw header dirs for the CRT,
  gcc-CFI cache vars, frame pointers and hardening off in the CRT.

### Building at GUIX's literal DISTSRC (the `distsrcChroot` re-entry)
The prefix maps fix what gcc RECORDS, not what it PARSES, and var-tracking's
GGC trajectory follows the parsed path. At v32.0rc2 that alone decided one
location list in `test/orphanage_tests.cpp`, so x86_64 sets
`distsrcChroot = true`: `postPatch` re-execs the builder through
`unshare --user --map-root-user --mount` into a chroot with the tree bound at
`/distsrc-base/distsrc-<ver>-<host>`, then runs the ordinary phases there
(same technique as `nix/darwin/release.nix`). Three traps, all hit at rc2 and
all invisible as *build failures*:
- **`bash -ec`, not `bash -c`.** Nix runs the real builder as `bash -e`. Without
  `-e` a failing `buildPhase` falls through to `fixupPhase` and the derivation
  SUCCEEDS with an empty `$out` (96 bytes), which nix registers happily; it only
  surfaces downstream as `Can't open .../bin/*` in packaging. `nix log` is
  unavailable here (`store = daemon`, no `/nix/var/log/nix`), so capture build
  output with `-L` into a file and always read the recorded `EXIT=` line.
- **`NIX_ENFORCE_PURITY=0`.** cc-wrapper drops every absolute `-I`/`-L`/`-isystem`
  not under `$NIX_STORE`, `$NIX_BUILD_TOP` or `/tmp` (`utils.bash` `badPath`;
  one purity block each in cc-wrapper and ld-wrapper). Under `/build/...` the
  tree's own includes were exempt; under `/distsrc-base` they are not, so every
  project-internal include disappears while depends' store includes still
  resolve. darwin never hit this — its clang toolchain is bare, no cc-wrapper.
- **Re-scrub `-frandom-seed`.** `preConfigure` strips it from
  `NIX_CFLAGS_COMPILE`, but sourcing `$stdenv/setup` inside the chroot re-runs
  nixpkgs' reproducible-builds hook, which re-appends it AFTER that scrub. It
  lands in `DW_AT_producer`: 5 distinct producers x 25 bytes = exactly the
  +125 bytes of `.debug_str` that made all 10 binaries differ from GUIX, with
  every other debug section (`.debug_line_str` included) already identical.

### GGC/var-tracking loclists flips (the chaotic class)
gcc's `.debug_loclists` choice among equivalent locations depends on GGC
allocation order and on DECL_UID/hash-table order, so tiny unrelated
differences flip ONE location list in a big CU while everything else matches.
- Fired argv prefix maps ggc-allocate their rewrites. Fix:
  `patches/gcc-debug-canon-prefix-map.patch` (malloc'd canonical rewrite via
  `NIX_DEBUG_CANON_PREFIX_MAP`, also for `__FILE__` macro maps) with
  `canonDepends` (depends → `/bitcoin/depends/<host>`) and `debugCanonMap`
  (`/build` → DISTSRC, so generated CUs get no duplicate file entry). Default
  ON in linux-cross-target; also wired on x86_64, aarch64 and win64.
- **Empty glibc `gnu/stubs-*.h`** (found at the branch-off): glibc's configure
  takes OBJDUMP from `$CC -print-prog-name=objdump`, a bare host objdump that
  reads no target object, so no `__stub_*` macros were generated. The 12
  missing armhf macros alone flipped `current_time` in `index/base.cpp` in
  every armhf `.dbg`. Fix: glibc makeFlags `OBJDUMP=<triple>-objdump` on all
  linux targets (guix prepends the target binutils to PATH).
- Also seen: armhf `it` in net_processing.cpp, ppc64 qt CUs, aarch64 and
  riscv64 bitcoind CUs. Sweeps showed even k unused `extern`s or `#define`s
  flip it back and forth non-monotonically, so look for ANY preprocessor-visible
  input difference, not for a count.

**win64 at v32.0rc3 — OPEN.** The 6 win64 artifacts miss; everything else
reproduces. Localized completely, cause not yet found:
- `unsigned.zip`: of 26 members only `libexec/test_bitcoin.exe` differs
  (same uncompressed size, different CRC); the other 8 binaries, the
  man pages and the configs are byte-identical. `debug.zip`: only
  `test_bitcoin.exe.dbg`.
- the stripped `.exe` differs in exactly **6 bytes**: the PE optional-header
  CheckSum (file offset 0xd8) and the last 4 bytes of `.gnu_debuglink` (the
  CRC32 of the `.dbg`, at 0x1e47200+24). Code and data are identical — both
  diffs are derived from the `.dbg`. That is why all four published
  artifacts miss on one CU.
- in the 1 GB `.dbg`, `.debug_line`, `.debug_str`, `.debug_line_str`,
  `.debug_abbrev` and `.debug_rnglists` are byte-identical; only
  `.debug_loclists` (ours +9 B) and `.debug_info` differ. Of 547 loclists
  units exactly ONE differs — unit 36 = CU 36 = `test/cuckoocache_tests.cpp`
  (body 214855 B vs GUIX's 214846 B). All 7 518 828 differing byte-runs in
  `.debug_info` were mechanically verified to be nothing but that shift: a
  4-byte LE loclist offset +9 (the 4 apparent exceptions are carry-crossing
  adjacent offsets plus the one `DW_AT_location` that moved +2).
- the difference itself: over `[0x65,0x6b)` GUIX emits ONE entry
  (`DW_OP_regval_type r1; DW_OP_stack_value`), we split the range and use
  `DW_OP_breg2 +0x48; DW_OP_stack_value` for `[0x65,0x6a)` — equivalent
  locations, a different var-tracking representative. 21 B vs 30 B.

Ruled out, each with evidence:
- **The parsed source path** (the lever that fixed x86_64-linux at rc2).
  `distsrcChroot` was implemented for win64 and confirmed to engage
  (`Build files have been written to: /distsrc-base/distsrc-32.0rc3-x86_64-w64-mingw32/build`);
  it produced BYTE-IDENTICAL output, so it was reverted. Unlike x86_64-linux,
  win64 is path-insensitive here.
- **The parsed depends path.** GUIX parses depends headers at the short real
  `/bitcoin/depends/<host>` (35 chars) and fires no prefix map on them; we
  parse them at the 67-char store path and rewrite via the canon env var.
  Bind-mounting our depends at GUIX's literal path, rewriting
  `includes_CXX.rsp` and unsetting `NIX_DEBUG_CANON_PREFIX_MAP` changed
  NOTHING (214863 both ways) — even though this CU is boost-test-heavy.
- **depends header content.** All 4106 headers byte-identical to GUIX's own
  win64 depends tree (see Current state).
- **The toolchain pins.** `contrib/guix/` is untouched since rc2, which
  matched byte-for-byte; `manifest_build.scm`'s `mingw-w64-base-gcc` is
  unchanged. GUIX's mingw-only gcc extras are not candidates either:
  `gcc-7-cross-mingw.patch` touches only `libsupc++/new_opa.cc` (a library
  source, not a parsed header) and `cross-gcc-snippet`'s
  `os/mingw32-w64 → os/newlib` copy is dead for a mingw target
  (`configure.host` picks `os/mingw32-w64` directly).
- **The parsed TOOLCHAIN header path**, tested properly with a controlled
  two-arm compile: both arms use `-nostdinc -nostdinc++` plus the same six
  `-isystem` dirs in our gcc's own order, so the ONLY variable is the prefix
  string; arm A at our 73-char `/nix/store/…-x86_64-w64-mingw32-gcc-14.3.0`,
  arm B at GUIX's 79-char
  `/gnu/store/6ydp3m6zfiznlzzkgp0appz217dcygyb-gcc-cross-x86_64-w64-mingw32-14.3.0`
  (bind-mounted onto our tree), with the `-ffile-prefix-map` rewritten to
  match. Arm A reproduces the baseline 214863 (so the `-nostdinc`
  reconstruction is faithful) and arm B gives 214863 too — no change. NOTE:
  do NOT test this by just invoking the relocated driver. gcc relocates via
  `make_relative_prefix(argv[0])`, and the relocated search list comes out in
  a DIFFERENT ORDER (the `include/c++` dirs move from first to last), which
  breaks `cstdlib`'s `#include_next <stdlib.h>` outright — that arm changes
  two variables and fails to compile.
- **nixpkgs' mcfgthread `-isystem` noise.** `NIX_CFLAGS_COMPILE` carries
  `-isystem <mcfgthread-dev>/include` FOUR times, which GUIX has no
  counterpart for (it uses winpthreads via the cross libc). Stripping all
  four changes nothing. (Consistent with `.debug_line` being identical: no
  mcfgthread header is actually reached.)
- **The CMake-generated `bitcoin-build-config.h`.** Its macro set is
  identical to the GUIX branch-off win64 tree's apart from `USE_QRCODE`,
  which is expected because the local GUIX tree is the GUI pass and the
  replay is the NoQt pass — every `HAVE_*`/platform check agrees. (This was
  the best remaining "parsed but invisible" candidate, in the same class as
  the Qt posix shm/sem preseed and the empty glibc `gnu/stubs-*.h`.)
- **Our gcc's configure line.** It carries GUIX's `mingw-w64-base-gcc`
  flags verbatim (`--enable-default-ssp=yes --enable-gprofng=no
  --enable-host-bind-now=yes --enable-threads=posix --disable-{gcov,libgomp,
  libsanitizer,lto,nls}`). The nixpkgs extras that GUIX lacks
  (`--enable-plugin`, `--with-system-zlib`, `--disable-libstdcxx-pch`,
  `--enable-default-pie`) are all either codegen-neutral or demonstrably
  inert here: ANY codegen-affecting default would move all 8 binaries, and 7
  of 8 are byte-identical.
- **Our own `gcc-debug-canon-prefix-map.patch`** — the ONLY source-level
  difference between our mingw gcc and GUIX's. A gcc rebuilt with that patch
  dropped (8 patches instead of 9; store path
  `gh0r8bi2siym0fk8dgvkwfis71008aqx`) compiles this CU to the IDENTICAL
  214863 / `.debug_info` 0x280df4. So the patch is not the cause — and this
  is also the positive half of the "validate both directions" rule for it:
  inert when it does not fire, exactly as its header claims.
- **The HOST compiler that builds our cross gcc.** This was the strongest
  remaining non-input hypothesis, by direct precedent: CLAUDE.md's darwin entry
  has rcc's `std::sort` tie breaking differently under libc++ vs libstdc++. It
  is dead — `mingwGuixGcc.cc.stdenv.cc` is **gcc 14.3.0**, the same version
  GUIX builds its cross gcc with (its win64 `CMakeCache.txt` store paths show
  `gcc-14.3.0`), so cc1plus is compiled by the same libstdc++ release and any
  `std::sort`/`qsort` tie is broken the same way.
- **Host allocator state.** `MALLOC_PERTURB_=165`, `MALLOC_TOP_PAD_`,
  `MALLOC_MMAP_THRESHOLD_`, `MALLOC_ARENA_MAX=1` and
  `GLIBC_TUNABLES=glibc.malloc.tcache_count=0` all leave it at 214863. The
  decision therefore does not read heap ADDRESSES — consistent with our
  builds being bit-reproducible under ASLR, and it means the lever is an
  allocation SEQUENCE / sort-tie difference, not an address one.

CONFIRMED BY AN INDEPENDENT GUIX BUILD (2026-10-09, the user's own, on
DIFFERENT hardware from this machine): all four published win64 hashes
reproduce exactly —
`d8cee48e…` codesigning.tar.gz, `c0f44ca3…` debug.zip, `4aa93275…`
setup-unsigned.exe, `d74c5c55…` unsigned.zip. Two consequences:
- The published win64 bytes ARE reproducible from guix pin `c5eee3336cc1`
  on arbitrary hardware, so the divergence is entirely on OUR side; it is
  not an artifact of whatever machine produced the release.
- It definitively kills any "GUIX's builder had unusual GGC state" theory
  (different physmem/rlimits on a second machine would have to land on the
  same answer by luck), which matches the `ggc-min-expand=30` red herring
  above.
That build's win64 `CMakeCache.txt` also confirms the toolchain is unchanged
from the branch-off: every store path is identical (`6ydp3m6z…`
gcc-cross-14.3.0, `gca8j0n2v…` binutils-cross-2.46.0, `bcm8is7b…`
cmake-minimal-3.31.10, `z6ykgdnq…` winpthreads-13.0.0, `x0iw1v0m…`
posix-toolchain, `fzsjy9a5…` gcc-cross-lib), with 89 distinct `/gnu/store`
paths in the `-ffile-prefix-map` set. Its base `CXX_FLAGS` are
`-O2 -g <89 maps> -fdebug-prefix-map=<DISTSRC>/src=. -fno-ident` — ONE debug
map where we pass two (`/build→DISTSRC` plus `/build/src=.`); the
`distsrcChroot` arm above already collapsed ours to that single map and
changed nothing, so the map count is not the lever either.

WHAT IS STILL MISSING TO CLOSE THIS. Every input has now been shown
identical and every path and allocator knob shown inert, which leaves the
compiler BINARY itself — and we have GUIX's output bytes but not GUIX's
mingw compiler, so the decisive comparison cannot be run. The local
branch-off reference does NOT fill the gap: its win64 distsrc tree is the
GUI pass only (377 objects, no `test_bitcoin.dir`, no
`cuckoocache_tests.cpp.obj`) and `guix-x86_64-toolchain.tar.gz` contains no
mingw store paths. What would close it, in order of value:
1. GUIX's mingw cross toolchain closure for pin `c5eee3336cc1`
   (`gcc-cross-x86_64-w64-mingw32-14.3.0` + its `-lib`,
   `binutils-cross-…-2.46.0`, the mingw-w64 libc/winpthreads), e.g.
   `tar czf win64-toolchain.tar.gz $(guix gc --requisites <gcc-cross path>)`
   after a win64 guix build. Bind-mounted at its literal `/gnu/store` paths
   (the replay chroot already does this), compiling this one CU with GUIX's
   own cc1plus against OUR inputs splits "compiler binary" from "inputs" in
   a single ~1-minute run.
2. The single object `build/src/test/CMakeFiles/test_bitcoin.dir/
   cuckoocache_tests.cpp.obj` from a guix win64 rc3 build — the .o oracle
   this CU has never had, which turns the comparison into a DIE-level diff
   instead of an inference from the linked `.dbg`.
3. The whole NoQt-pass (`build_win.sh`) distsrc tree, which is where
   test_bitcoin is built; the GUI pass does not build it.

Where that leaves it: GGC allocation order is deterministic given the gcc
source plus the input, the input is identical by every measure above, and
our build is deterministic (two independent builds, one of them at a
different path, produced identical bytes). So the divergence is a GGC-margin
difference whose source is not yet identified. The next untried angle is a
gcc instrumented to log ggc allocation counts at the point var-tracking
chooses this list, compared between a trigger and a non-trigger compile —
the same "patch the tool to print its internal order" technique the linker
stub-order entry below used.

Classified: the CU is GGC-timing sensitive. `--param ggc-min-expand=30`
reproduces GUIX's loclists length exactly (214854) and is NOT recorded in
`DW_AT_producer` (`.debug_str` identical) — but it is a red herring: it also
makes the object's `.debug_info` 26 B LARGER than GUIX's CU, which our
baseline already matches, so it is a different outcome that happens to share
one length. `ggc-min-heapsize` (4096…262144) and a dummy `-D` macro move
nothing. 30 is gcc's `params.opt` default; `ggc_min_expand_heuristic()`
returns `30 + 70*min(physmem_GB,1)` = 100 on any machine with ≥1 GB and no
RSS rlimit, so GUIX's builders are on 100 too — if they were not, every
target would diverge, not one CU.
Remaining suspicion: a GGC-allocation-volume difference between our mingw
gcc binary and GUIX's, which the two targets below can discriminate.

Single-CU replay harness (in `/home/infra/rc3-replay`, ~1 min per
iteration instead of an hours-long rebuild): `nix print-dev-env` of
`.#bitcoindMingwNoGui` → `devenv.sh`; `go.sh` unshares a user+mount
namespace, binds the tree at `/build/bitcoin-<ver>` and runs
`phases="configurePhase"`; then the exact compile line is lifted from
`build/src/test/CMakeFiles/test_bitcoin.dir/flags.make` (+
`includes_CXX.rsp`) and run directly, so one `.cpp` is recompiled per
iteration. Two traps: source `devenv.sh` WITHOUT `set -u` (nixpkgs hooks
reference unset vars like `shareDocName`) and resolve bash with
`readlink -f` (the chroot has no `/run/current-system`). Validation: the
object's `.debug_loclists` body size equals the linked `.dbg`'s unit body
exactly, so the two numbers to hit are **loclists body 214846** and
**`.debug_info` 0x280df4 (2 625 012)**; our baseline gives 214855 /
0x280df4. A direct byte compare of object vs linked loclists does NOT work
(unrelocated addresses diverge at byte 71) — compare sizes.

### Linker stub order (armhf, ppc64)
GNU ld names ppc64 long-branch and ARM long-branch/Cortex-A8-erratum stubs
after GLOBAL BFD section ids and emits them in `bfd_hash_hash % 4051` order.
Shared libraries ld only reads still consume ids, so one extra section in a
glibc `.so` reorders the stubs of big binaries.
- ppc64: our `libm.so.6`/`libc.so.6` carried `.gnu.attributes` → removed.
- armhf: `libc.so.6` + `libpthread.so.0` carry one section more than guix's
  (`.ARM.extab` removed; ld only counts, so the identity is unconfirmed).
  `ld-linux-armhf.so.3` must KEEP it: stripping it too broke test_bitcoin,
  whose big stub group is anchored after ld-linux's ids.
- Knobs: `glibcStripSharedSections` / `glibcStripSharedFiles`.

### Generated build-time tables
- armhf: gcc's `config/arm/parsecpu.awk` iterates an awk array unordered; gawk
  5.4 vs guix's 5.3.0 reorders a table baked into crtbegin/crtend → gawk 5.3.0
  pinned into the armhf gcc build.
- darwin: rcc sorts qrc children with `std::sort` by qt_hash, and
  `:/translations/he`/`gu` collide; libc++ vs libstdc++ order the tie
  differently → native depends tools built with clang + libc++ like guix's
  `llvm_toolchain` (wrapper scripts, since depends overwrites build_LDFLAGS).

### darwin specifics
- LC_UUID hashes the UNSTRIPPED image incl. N_SO/N_OSO stabs → build inside an
  unshare chroot at guix's literal DISTSRC / `/bitcoin/depends/<host>` paths.
- CMake's PATH-derived find prefixes find the build glibc's ELF `librt.so` →
  `CMAKE_SYSTEM_IGNORE_PATH=<glibc>/lib` for depends.
- kj fibers are ON upstream now (setup.sh's `llvm_toolchain` exports no
  LIBRARY_PATH), and guix's cmake 3.31 no longer triggers qtbase's cocoa PCH
  guard — neither needs a workaround any more.
- App bundle zip: Qt translations come out of the store 0444 → chmod before
  rezipping with `macos_zip.sh`. setup.sh is sourced under `set +u`.

### win64 specifics
- NSIS stubs: guix builds them with its DEFAULT cross gcc (gcc-14 now); nixpkgs'
  `--enable-default-pie` must be filtered (implicit `-pie` added
  `.edata`/`.reloc` and shifted the whole installer). `SOURCE_DATE_EPOCH=1` and
  faketime at epoch+1 for the `.rsrc` resource-directory timestamp.
- CRT/winpthreads: gcc 14 (gcc 15 changes crtexe's dllimport codegen) with
  guix's default cross binutils, no unaligned-vector patch.
- `package.nix` sets `dontUseCmakeConfigure` (cmake is an input only for
  `cmake -P GenerateWindowsInstaller.cmake`).
- **osslsigncode 2.14 (v32.0rc2) removed `-CAfile` from `attach-signature`.**
  2.5 verified in-process after attaching and still wrote the output; 2.14
  split verification into a separate `verify` command, so `-CAfile` there is
  a hard `Unknown option` error that writes NOTHING. That is why upstream's
  codesign.sh gained a standalone `osslsigncode verify … -ignore-crl
  -ignore-cdp` (and nss-certs) in the same change. `nix/win64/signed.nix`
  passes only `-in/-out/-sigin`, and must NOT wrap the call in `|| true`:
  with no verification step left to tolerate, swallowing the exit code just
  turns a missing signature into a later `mv: cannot stat`. The separate
  verify pass re-reads what was already written, so it changes no bytes and
  is not reproduced.

## Retargeting to a new commit or release

1. Bump `commit`/`version`/`sourceDateEpoch` in `default.nix` (the repack
   handles untagged commits).
2. Diff upstream `contrib/guix/` (manifest pins and patches, `setup.sh`,
   `build_*.sh`, `package.sh`) and `depends/packages/` against the previous
   target; follow the guix time-machine pin into the guix checkout
   (`guix/` in the repo) for binutils/glibc/gcc/mingw/nsis/clang versions and
   package phases. `CMakeCache.txt` of a guix build lists the exact store paths.
3. Get reference hashes (guix.sigs for releases, or a local guix build) into
   `noncodesigned.SHA256SUMS`, build all 20 attrs in ONE `nix build`, then
   localize any gate failure with the method below.

## Method

- Localize: archive → files (`cmp`), file → ELF sections (objcopy
  `--only-section`, decompress debug sections first), `.dbg` → one CU via
  per-table walks of `.debug_line`/`.debug_loclists`, then the DIE via readelf
  and a normalized DIE-dump diff.
- Guix build trees keep objects: a guix `.o` is a perfect oracle for a
  single-CU replay. Replay chroot recipe (all rootless): `nix print-dev-env` of
  the release pass → `unshare -rm` chroot with a persistent bind-mounted
  `/build`, the drv's own configurePhase + `make`, then rebuild one object with
  edited compile lines. Bind-mount our trees at guix's literal
  `/distsrc-base`, `/bitcoin/depends` and `/gnu/store/<guix-hash>-…` paths to
  emulate guix's environment exactly (our gcc honors plain
  `C_/CPLUS_INCLUDE_PATH`, not guix's `CROSS_*`).
- For chaotic flips, sweep perturbations (extra externs/macros, GGC params,
  malloc perturbation) to classify the sensitivity, then compare generated
  headers (c++config.h, gnu/stubs, bits/*) against pristine sources.
- Linker stub order: a binutils build with `bfd_section_init` /
  `arm_build_one_stub` patched to print section ids and stub names; collect2
  always runs gcc's baked `--with-ld` (`-B`/`-fuse-ld` do not redirect it), so
  capture collect2's argv with `-v` and run the tracing ld directly; model the
  stub order offline with `bfd_hash_hash`; confirm by relinking against glibc
  `.so` copies with sections added or removed.
- Refactors: compare the drvPaths of all 20 gated attrs before and after
  (`nix eval --json .#packages.x86_64-linux --apply …drvPath`); identical
  drvPaths need no rebuild.
- Before trusting a patch to gcc, validate both directions: the trigger case
  fixed AND a non-trigger compile byte-identical to the unpatched compiler.

## Ops hazards on this machine

- A host-side scheduled GC (~00:00) deletes every built store path: this
  container's daemon registers no GC roots (`gcroots` not writable). Expect
  full rebuilds after midnight; `result-*` links do not protect anything.
- Run the full re-verification as ONE `nix build` over all the gated attrs.
  Nix's defaults (max-jobs 24, all cores) are NOT usable for a cold full
  rebuild under the agent harness: a single client peaked at 88 GB of 125 GB
  (`/sys/fs/cgroup/memory.peak`, no cgroup limit and no kernel OOM) and the
  harness's low-memory guard SIGINTed it twice — once at defaults, once at
  `--max-jobs 6` (which still gives every job all 24 cores: load hit 55+).
  `--max-jobs 4 --cores 6` completed the cold 28-artifact rebuild with
  99 GB still available at its lowest point. Two parallel nix clients get
  killed the same way.
- `ftpmirror.gnu.org` times out: fetch GNU tarballs from sourceware.org,
  check the hash, `nix-store --add-fixed sha256 <file>`.
- `/tmp` is a 13 GB tmpfs: keep large scratch on disk.

## CI

`.github/workflows/nix-ci.yml` builds every gated artifact per target (the
nix gates fail the job on a hash mismatch), plus two aarch64-hosted jobs, and a
`print-hashes` job that lists all 20 artifact hashes. darwin jobs need
`sysctl kernel.apparmor_restrict_unprivileged_userns=0` for the unshare chroot.

## Working conventions

- Stay on the current branch (never switch branches), never push.
- Atomic commits, each verified before committing: a gated `nix build` with
  matching hashes for behavior changes; identical drvPaths for refactors.
- Keep this file current: state, root causes, method — not a dated journal.
