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

## Current state (2026-09-20)

- **Target:** the `v32.0rc2` tag, guix time-machine pin `c5eee3336cc1`
  (UNCHANGED from rc1). `version = "32.0rc2"`,
  `sourceDateEpoch = 1789731029`, src
  `sha256-7qz3Kd/yChMAxm7Yx2bMbtzkLAvtKkjjJi8ZN6WBnq8=`. Reference hashes: the
  rc2 guix.sigs attestation (4 signers, byte-identical), checked in as the
  21-line `noncodesigned.SHA256SUMS`.
- **rc1 → rc2 is a small delta** (13 commits): `depends/` untouched;
  `contrib/guix/` changes are codesigning-only (osslsigncode 2.5 → 2.14 plus
  `nss-certs`; `codesign.sh` gained an `osslsigncode verify` pass). Source
  changes: the asmap-version backport (`netgroup.{cpp,h}`, `rpc/net.cpp`,
  `init.cpp`), `torcontrol.cpp` backoff, the `0d4d0ce37b9e` static-const
  refactor, the version bump, docs/man. No toolchain changed.
- **x86_64 needs `distsrcChroot = true`** (nix/x86_64-linux-gnu/toolchain.nix).
  rc2's `netgroup.h` change pushed `test/orphanage_tests.cpp` into the regime
  where the PARSED source path decides var-tracking's location-list choice, so
  the release passes now compile at GUIX's literal DISTSRC inside an
  unshare+chroot. Both x86_64 artifacts then match the attestation
  (`0255103718033e6a…` and `8e8c88785ac4c289…`, verified 2026-09-20). See the
  `distsrcChroot` entry in the root-cause catalogue for the three traps this
  re-entry hides — each one produced a build that SUCCEEDED while being wrong.
- **The previous target**, the branch-off commit, was verified against a
  local guix build (the user's `/home/infra/guix-ref-f3fec67c3eeb/bitcoin/`,
  35 GB: outputs, the GUI-pass `distsrc-*/build` trees with CMakeCache.txt
  and objects, the depends caches) — still the oracle for single-CU replays,
  since the toolchains are identical.
- **All 21 attested non-codesigned artifacts** are gated, checked with one
  `nix build` over all of them:
  - the source dist archive `bitcoin-32.0rc2.tar.gz` (`sourceDistArchive`:
    GitHub's tag archive re-gzipped with `gzip6.c`)
  - 5 linux release + 5 debug tarballs (`tarball`, `debugTarball`, and the
    `Aarch64`/`Riscv64`/`Armhf`/`Ppc64` variants)
  - darwin x86_64/arm64 `-unsigned.tar.gz`, `-unsigned.zip`,
    `-codesigning.tar.gz` (`tarballDarwin*`, `zipDarwin*`, `codesigningDarwin*`)
  - win64 `unsignedZipMingw`, `debugZipMingw`, `setupExeMingw`, `codesigningMingw`
- **Signed artifacts are wired up AND gated** against bitcoin-detached-sigs
  `v32.0rc2` (tag `23d1304d`, peels to `c573e805`; carries `osx/` + `win/`):
  `signedDarwinX86`/`signedDarwinArm64` (2 each), `signedMingw` (2), plus
  `codesignaturesArchive`. Unlike rc1, this rc HAS an `all.SHA256SUMS` — 10
  of the 11 guix.sigs signers published a byte-identical one — so it is
  checked in at the repo root and `upstreamSha256` resolves all 7 extra
  filenames with no code change. win64 needs osslsigncode **2.14**
  (`osslsigncode214`), per rc2's `manifest_codesign.scm`; `codesign.sh`'s new
  `osslsigncode verify` pass only re-reads what `attach-signature` already
  wrote, so it cannot change the emitted bytes. **Verified 2026-09-21: all
  28 artifacts reproduce and `.#sha256sums` equals the checked-in
  all.SHA256SUMS** (see the win64 note on 2.14's `-CAfile` removal).
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
