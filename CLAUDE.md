# bitcoind-gunix

## Goal

Reproduce the official Bitcoin Core GUIX release binary for `x86_64-pc-linux-gnu` using Nix — ideally producing a binary with an identical hash.

Project status is tracked in https://github.com/0xB10C/bitcoind-gunix/issues/1.

## How it works (current, post-v31.0 update on branch `2025-05-claude`)

The build is split into two derivations:

1. **`depends.nix`** — builds Bitcoin Core's `depends/` tree. All dependency tarballs are pre-fetched via Nix's `fetchurl` and copied into `depends/sources/` before the build starts, working around Nix's no-network sandbox. Uses `gcc14Stdenv` to match GUIX v31.0's GCC 14.2.0. Builds: boost, libevent, sqlite, zeromq, systemtap, capnp + multiprocess (native_capnp, native_libmultiprocess). GUI deps (Qt6, xcb-*, freetype, fontconfig, expat, libxkbcommon, qrencode) are skipped via `NO_QT=1`.

2. **`bitcoind.nix`** — builds `bitcoind` using `cmake --toolchain ${depends}/toolchain.cmake`. CMake replaces the autotools build that v27.0 used. Skips GUI, tests, bench, fuzz. Mirrors the GUIX release flags (`REDUCE_EXPORTS=ON`, `CMAKE_SKIP_RPATH=TRUE`, `-O2 -g`). After install, runs `./split-debug.sh` from the cmake build dir to produce `-s` (stripped) and `-d` (debug) variants.

3. **`default.nix`** — entry point; targets Bitcoin Core **v31.0**.

4. **`flake.nix`** — pins nixpkgs to `github:NixOS/nixpkgs/nixos-25.11`. Builds:
   - `nix build .#depends` — just the depends tree
   - `nix build .#bitcoind` (or `.#default`) — the full bitcoind

## Patches

- **`patches/depends-funcs-test-source-exists.patch`** — re-adds the `test -f` short-circuit in `depends/funcs.mk:fetch_file` that upstream removed in commit `46135d90ea9` (Sep 2025). Without it, the depends Makefile always tries to `curl` even when sources are pre-staged, which fails in Nix's sandbox.

## Workarounds baked into the Nix derivations

These are subtle and easy to break, so document the reasoning:

- **depends postFixup path rewrite**: libevent's exported CMake config files (`LibeventTargets-static.cmake`) hardcode the absolute build-time staging path as `_IMPORT_PREFIX`. `depends.nix` `sed`-replaces `/build/bitcoin-<ver>/depends/x86_64-pc-linux-gnu` → `$out` in any `*.cmake`/`*.pc` files under `$out` so consumers (the bitcoind build) can find the installed libraries.

- **bitcoind preConfigure symlink**: `libmultiprocess`'s `mpgen` binary has the depends-build-time absolute path *baked into the ELF as a string literal* via the `capnp_PREFIX` macro (`src/ipc/libmultiprocess/include/mp/config.h.in`). At codegen time `mpgen` execs `<capnp_PREFIX>/bin/capnp` and dies if the path doesn't exist. We `ln -s ${depends} depends/x86_64-pc-linux-gnu` from PWD (`/build/bitcoin-31.0`) so the absolute path resolves through the symlink. This matches the historical v27.0 trick (originally added for Qt).

## CI

`.github/workflows/nix-ci.yml` — runs `nix-build` on GitHub Actions, currently pinned to `nixos-25.11`. Uses Cachix (`0xb10c-bitcoind-gunix`) for build caching. **TODO**: switch CI from `nix-build` to `nix build` (or add a flake-aware invocation) so it actually exercises the flake.

## Current build output (as of v31.0 update)

```
result/bin/
  bitcoind       308 MB  (unstripped, dynamically linked, glibc 2.40)
  bitcoind-d     297 MB  (split debuginfo)
  bitcoind-s      17 MB  (stripped)
  bitcoin-cli     23 MB
  bitcoin         13 MB  (multi-call wrapper)
result/libexec/
  bitcoin-node          (multiprocess child binary)
```

`bitcoind --version` reports `Bitcoin Core daemon version v31.0.0 bitcoind` ✓.

## Open problems

### Binary size / hash mismatch (the main unsolved problem)
Our `bitcoind` is **~308 MB unstripped** / **~17 MB stripped**; upstream GUIX is ~96 MB unstripped / much smaller stripped. The bulk of the gap is debug info volume + linkage differences:

- Nix links against **glibc 2.40** with a `RUNPATH` pointing into `/nix/store/`; GUIX uses **glibc 2.31** with relocatable / no RUNPATH.
- glibc ≥ 2.34 merged `libpthread`/`libdl`/`librt`/`libutil` into `libc.so.6`, so `NEEDED` lists differ.
- gcc 14 emits more debug info than gcc 10 / 11 by default in some configs.

Approaches tried (see issue #1):
- Custom glibc stdenv in Nix (josibake, Jul 2025) — complex, partial progress
- Patch GUIX to use a matching gcc toolchain — hit build errors

### Non-fatal `./gen_id` errors
During the depends build, `make` prints `env: './gen_id': No such file or directory` twice. The build completes anyway (the `build_id` shell expansion silently produces an empty string). Worth investigating since deterministic build IDs likely matter for reproducibility, but doesn't block functional builds.

## Branch convention

Each Bitcoin Core version gets its own branch (e.g. `v27.0`, `v26.0`). Active development uses dated branches (e.g. `2025-05-claude`).

## Commit log summary for branch `2025-05-claude` (off `v27.0`)

```
ci: update nixos 24.05 -> 25.11
add: nix flake pinning nixpkgs to nixos-25.11
depends: bump gcc10Stdenv -> gcc14Stdenv
depends: drop GUI-related packages, skip Qt build
depends: drop db48, miniupnpc, libnatpmp
depends: bump versions to match Bitcoin Core v31.0
update: Bitcoin Core v27.0 -> v31.0
depends: include capnp source, build multiprocess IPC
depends: add cmake and which to buildInputs
depends: rewrite build-time paths in cmake/pkg-config files
bitcoind: rewrite for v31.0 CMake build
bitcoind: symlink depends to match capnp_PREFIX baked-in path
bitcoind: fix split-debug.sh path after CMake switch
bitcoind: invoke split-debug.sh from build dir (cwd)
```

`bitcoin/` (the v31.0 source checkout for reference), `shell.nix`, and `CLAUDE.md` are intentionally untracked.

## Next focus: closing the gap to the GUIX binary

### Comparison results (stripped binaries, v31.0)

Upstream GUIX release tarball is cached at `/tmp/upstream-v31/bitcoin-31.0/bin/bitcoind` (downloaded from https://bitcoincore.org/bin/bitcoin-core-31.0/bitcoin-31.0-x86_64-linux-gnu.tar.gz).

| Metric | Upstream GUIX | Ours (`bitcoind-s`) |
|---|---|---|
| Size | 17,826,248 B (17.0 MiB) | 16,552,032 B (15.8 MiB) |
| Compiler (`.comment`) | GCC 14.3.0 | GCC 14.3.0 |
| Interpreter | `/lib64/ld-linux-x86-64.so.2` | `/nix/store/.../glibc-2.40-224/lib/ld-linux-x86-64.so.2` |
| `NEEDED` | libpthread, libm, libc, ld | libstdc++, libm, libgcc_s, libc, ld |
| `RUNPATH` | (none) | `/nix/store/.../glibc-2.40-224/lib:/nix/store/.../gcc-14.3.0-lib/lib` |

### Section-level bloaty diff (`bitcoind-s` against upstream as base)

```
+293% +9.98Ki  .dynstr           ← extra Nix store paths in RUNPATH
 +52% +4.22Ki  .dynsym           ← extra dynamic symbols for libstdc++/libgcc
 +34% +2.44Ki  .rela.plt
 +34% +1.62Ki  .plt
 -6.1% -26.8Ki .gcc_except_table
-31.2%  -338Ki .eh_frame
 -6.4%  -733Ki .text             ← upstream statically links libstdc++/libgcc
 -7.1% -1.22Mi TOTAL
```

### Interpretation

The main structural difference is **upstream statically links libstdc++ and libgcc** (their code gets embedded in `.text`, growing it), while ours dynamically links them (so we have smaller `.text` but extra `NEEDED` entries and a `RUNPATH` pointing into the Nix store).

The glibc version mismatch (2.31 upstream vs 2.40 ours) shows up as the `libpthread.so.0` `NEEDED` entry: glibc ≥ 2.34 merged libpthread/libdl/librt/libutil into `libc.so.6`. This requires upstream/Nix to use the same glibc version to fix — a much deeper change.

### Concrete next steps (in atomic-commit order)

1. **Disable nixpkgs' RUNPATH injection**. Even with `-DCMAKE_SKIP_RPATH=TRUE`, the stdenv's setup hooks add a RUNPATH pointing at glibc and gcc-libs. We need `dontPatchELF` or to explicitly run `patchelf --remove-rpath` post-install, plus probably set `NIX_DONT_SET_RPATH` / `NIX_CC_USE_RESPONSE_FILE` accordingly.
2. **Static link libstdc++ and libgcc**: add `-static-libstdc++ -static-libgcc` (or `LDFLAGS="-Wl,-Bstatic -lstdc++ -lgcc"` style). GUIX does this via toolchain config; for us it'll be a `cmakeFlags`/`env.LDFLAGS` change.
3. **Patch the ELF interpreter** to `/lib64/ld-linux-x86-64.so.2`. `patchelf --set-interpreter` in postFixup, plus `dontPatchELF` to keep stdenv from re-injecting Nix store paths.
4. **Investigate the glibc version gap** — likely the deepest change, needs a custom glibc 2.31 stdenv (the route josibake hit in Jul 2025). Defer until 1–3 are landed.

### Tools used / recommended

- `readelf -d` — dynamic section (NEEDED, RUNPATH); quick sanity checks
- `readelf -p .comment` — compiler version
- `file` — confirms interpreter path, stripped status
- `bloaty <ours> -- <upstream>` — section-level size diff
- `diffoscope` — deep recursive diff
- `bitcoin-maintainer-tools/build-for-compare.py` — fanquake's helper, not used yet

### Status after glibc 2.31 stdenv rebuild

After overriding the entire stdenv to use glibc 2.31 (see commit
`build: rebuild gcc 14 against glibc 2.31, use it for everything`):

| Metric | Upstream | Ours | Δ |
|---|---|---|---|
| Stripped size | 17,826,248 B | 17,850,736 B | +0.14% (+24 KB) |
| Interpreter | `/lib64/ld-linux-x86-64.so.2` | same | ✅ |
| NEEDED | libpthread, libm, libc, ld | same | ✅ |
| RUNPATH | (none) | (none) | ✅ |
| Compiler `.comment` | GCC 14.3.0 | GCC 14.3.0 + GCC 8.3.0 | extra CRT-builder string |
| Dynamic symbols | 344 | 344 | ✅ |

bloaty section deltas (positive = ours bigger):
```
+200 KiB  .text
+176 KiB  -.eh_frame  (ours smaller)
 +1.7 KB  .rela.dyn
 +672 B   .data.rel.ro
 +640 B   .rodata
 +478 B   .gcc_except_table
 +376 B   .eh_frame_hdr
  +48 B   -.note.gnu.property  (missing in ours)
  +16 B   .comment
```

### Status after applying GUIX gcc patches + configure flags + path prefix-maps

Subsequent commits applied GUIX's full toolchain configuration:

- `gcc-ssa-generation.patch` and `binutils-unaligned-default.patch`
  applied (`patches/` dir, wired in via `default.nix` overrideAttrs).
  Verified both apply: `vmovaps` is now encoded as `vmovups`.
- GUIX's `linux-base-gcc` configure flags appended to gcc:
  `--enable-initfini-array=yes --enable-default-ssp=yes --enable-default-pie=yes
  --enable-host-bind-now=yes --enable-standard-branch-protection=yes
  --enable-cet=yes --enable-gprofng=no --disable-gcov --disable-libgomp
  --disable-libquadmath --disable-libsanitizer`.
- `bitcoind.nix` adds `-ffile-prefix-map` flags to remap:
  - `${depends}` → `/bitcoin/depends/x86_64-linux-gnu` (matches upstream
    boost-header paths exactly: 9/9 match)
  - `/build/bitcoin-31.0/src` → `.` (matches upstream's relative
    `./addrdb.cpp` etc., 160/160 match)
  - `/build/bitcoin-31.0` → `/bitcoin` (broad fallback). GCC applies the
    LAST matching prefix-map, not the longest.
- Attempted to rebuild glibc 2.31 (`flake.nix` overrideAttrs) with
  GUIX's glibc configure flags (`--enable-cet`, `--enable-stack-protector=all`,
  `--enable-bind-now`, etc.). The rebuild ran (configure flags verified in
  the derivation) but `.note.gnu.property` is STILL absent in the final
  binary. Likely cause: nixos-20.09's stdenv that rebuilds the glibc still
  uses old gcc 8.3.0 and binutils ~2.32 without CET support, so even with
  `--enable-cet` glibc didn't emit CET CRT objects. To actually get CET-
  enabled CRTs we'd need to also override nixos-20.09's stdenv (gcc) used
  to rebuild glibc.

### Current delta to upstream

| Metric | Upstream | Ours | Δ |
|---|---|---|---|
| Stripped size | 17,826,248 B | 17,908,080 B | **+0.46% (+81,832 B)** |
| Interpreter | `/lib64/ld-linux-x86-64.so.2` | same | ✅ |
| NEEDED | libpthread, libm, libc, ld | same | ✅ |
| RUNPATH | (none) | (none) | ✅ |
| Dynamic symbol count | 344 | 344 | ✅ |
| Path strings (`/bitcoin/...`) | 9 | 9 | ✅ |
| `./*.cpp` relative paths | 160 | 160 | ✅ |
| `.note.gnu.property` (CET) | present (32 B) | absent | ❌ |
| `.comment` | `GCC 14.3.0` | `GCC 8.3.0`+`GCC 14.3.0` | ❌ extra stamp |
| `.note.ABI-tag` kernel | 3.2.0 | 2.6.32 | ❌ (got worse after glibc override?) |

bloaty section deltas (positive = ours bigger):
```
+258 KiB  .text                         ← largest remaining
-176 KiB  -.eh_frame  (ours smaller)
 +1.8 KB  .rela.dyn
 +1.1 KB  .gcc_except_table
 +672 B   .data.rel.ro
 +352 B   .rodata
  -48 B   -.note.gnu.property  (missing in ours)
  +16 B   .comment
TOTAL: +80 KB
```

### What's still likely contributing to .text +258 KiB

Same compiler version (GCC 14.3.0) on both. Same source. Same `-O2 -g`.
Same patches. So the codegen differences must come from somewhere
subtler:

- **Different binutils version**: ours is 2.44, GUIX may be different.
  Different gas/ld can change alignment, section padding, GOT/PLT layout,
  and CFI encoding.
- **libstdc++ template instantiations**: even with the same gcc source,
  building libstdc++ in a slightly different environment can produce
  different specializations and inline-ranges. GUIX builds gcc inside
  their full container; we build inside Nix's sandbox.
- **CFI encoding**: ours has 22,778 FDEs vs upstream's 22,731 (47 more)
  but `.eh_frame` is 176 KiB SMALLER. That's ~8 bytes less per FDE — a
  systematic CFI encoding difference. Likely from binutils gas behavior
  or compiler `-fasynchronous-unwind-tables` defaults.
- **Function alignment / function-count**: ~50,037 endbr64 in ours vs
  50,030 upstream (7 more functions in ours). At 16-byte default
  function alignment (`-falign-functions=16`), 7 extra functions add
  ~112 bytes of padding. Tiny.

### Findings from GUIX build log (`v31-guix-build.log`, untracked)

User provided a real `./bitcoin-31.0` GUIX build log (20,449 lines).
Key takeaways:

1. **GUIX cross-compiles even for native x86_64**. Their depends and
   bitcoin compiles invoke `x86_64-linux-gnu-gcc` (not bare `gcc`),
   driven by a cross-toolchain assembled via `make-bitcoin-cross-toolchain`
   in `contrib/guix/manifest.scm`. The build process: build cross-
   binutils → cross-gcc-sans-libc → kernel headers → cross-libc → final
   cross-gcc against the new libc. We do a *native* gcc 14 rebuild
   against glibc 2.31 which may produce subtly different code paths.

2. **Two gcc versions in the build**. Line 18549 shows a "Build C
   compiler" of `gcc-toolchain-14.2.0/bin/gcc` (used for build-host
   tools) while the target compile uses `x86_64-linux-gnu-gcc` from
   gcc 14.3.0. Native nixpkgs gcc 14 in our build is 14.3.0 too.

3. **GUIX depends compile flags include `-O2 -pipe`** (sqlite config at
   line 18550). We use `-O2` without `-pipe`. `-pipe` just affects
   pipeline-vs-tempfile communication and shouldn't change output, but
   could affect timing.

4. **`-ffile-prefix-map` is used during depends builds**. The Qt configure
   line uses
   `-ffile-prefix-map=/bitcoin/depends/work/build/x86_64-linux-gnu/qt/6.8.3-d0332da80a9=/usr`
   to map depends-internal build paths to `/usr`. Each depends package
   gets its own per-package prefix-map.

5. **Bitcoin core's CMake feature detection** (line ~19400) confirms
   `CXX_SUPPORTS__FCF_PROTECTION_FULL` and `LINKER_SUPPORTS__FCF_PROTECTION_FULL`
   succeeded — so bitcoin's cmake adds `-fcf-protection=full` to
   `core_interface`. But `core_interface` is "a usage requirement for
   all targets except secp256k1" (per top-level CMakeLists comment),
   so secp256k1 doesn't get CET unless we force it globally.

### CET / .note.gnu.property investigation (resolved: revert)

Long debug session showing the merging is more subtle than just
"propagate CET if all inputs have it":

- The linker drops `.note.gnu.property` from the final binary entirely
  if AND-merged properties (like `X86_FEATURE_1_AND` for IBT/SHSTK)
  can't be unified across inputs. Verified with minimal link tests.
- Our libstdc++.a, libgcc.a, and rebuilt glibc CRTs ALL have CET
  (IBT, SHSTK). Bitcoin's own .o files do too (`core_interface` adds
  `-fcf-protection=full`). Depends .o files have OR-properties
  (`x86 feature used: x86, XMM`, `x86 ISA used: x86-64-baseline`) but
  no CET marker.
- We tried forcing global `-fcf-protection=full` to give every input
  CET. The output then had ONLY `x86 feature: IBT, SHSTK` and lost
  the USED variants that upstream actually keeps.
- Upstream's binary has the auto-detected USED variants ONLY (no CET
  marker). This means upstream's linker merge is more permissive
  than ours: it drops the AND property (CET) silently when not all
  inputs have it, but keeps the OR properties (USED variants).
- Our binutils 2.44 is stricter — when it can't merge an AND
  property cleanly because of missing inputs, it drops the entire
  `.note.gnu.property` section.
- **Conclusion**: this requires a binutils downgrade or patch. Defer.
  Reverted `-fcf-protection=full` globally; back to baseline (delta
  +81,832 B).

### Tractable next items

1. **Strip `GCC: (GNU) 8.3.0` from `.comment`** — need to rebuild
   glibc 2.31 with a recent gcc (e.g. our patched 14.3.0) so its
   CRT objects don't carry an old `.comment` stamp.
2. **`.note.ABI-tag` kernel** — appears as 2.6.32 in our binary
   even though glibc 2.31 was configured with `--enable-kernel=3.2.0`.
   Likely the CRT note.ABI-tag is hardcoded from nixos-20.09's
   glibc package; need to verify and possibly override.
3. **`.text` +258 KiB / `.eh_frame` -176 KiB** — still the
   structural delta. Investigate compile-command differences via
   the GUIX log, or compare disassembly per function.

### Outstanding atomic-commit threads

1. Get `.note.gnu.property` populated in our binary (need a CET-aware
   stdenv to rebuild glibc 2.31 — likely overriding both gcc AND the
   stdenv used to rebuild glibc).
2. Verify and fix `.note.ABI-tag` kernel = 3.2.0 (need
   `--enable-kernel=3.2.0` in glibc configure; nixos-20.09 already passes
   this — investigate why our binary still shows 2.6.32).
3. Strip the duplicate `GCC: (GNU) 8.3.0` from `.comment` (will be fixed
   when glibc 2.31 is rebuilt with gcc 14).
4. Track down the `.text` +258 KiB delta (compare disassembly of a small
   function between ours and upstream, look for systematic codegen
   differences).
5. Track down the `.eh_frame` -176 KiB delta (likely binutils-gas CFI
   encoding diff).
