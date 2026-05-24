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

### Remaining deltas (deeper investigation)

1. **`.text` +200 KB / `.eh_frame` -176 KB** — net code/unwind shift. Each
   stapsdt probe encodes its arguments with different register/stack
   choices in ours vs upstream, showing the compiler made different
   code-gen decisions despite both binaries reporting GCC 14.3.0.
   GUIX patches its gcc 14 with `gcc-ssa-generation.patch`
   (`contrib/guix/patches/`), which alters SSA version numbering and
   changes generated code. Worth trying as the next step.

2. **`.note.gnu.property` (CET property) absent in ours** — this section is
   contributed by glibc's CRT objects (Scrt1.o etc.). GUIX builds its
   glibc with CET-enabled gcc; nixos-20.09's glibc 2.31 was not. To
   match, we'd need to either rebuild glibc 2.31 with CET, or override
   the CRT objects.

3. **`.note.ABI-tag` minimum kernel: 2.6.32 vs upstream 3.2.0** — this
   is set at glibc build time via `--enable-kernel=...`. nixos-20.09
   used the default 2.6.32; GUIX's glibc uses 3.2.0. Would need a
   custom glibc 2.31 build to fix.

4. **`.comment` has extra `GCC: (GNU) 8.3.0` string** — old nixpkgs's
   glibc 2.31 was built with gcc 8.3.0, leaving that stamp on its
   CRT objects, which gets pulled into our final binary's `.comment`.
   Would also be fixed by rebuilding glibc 2.31 with our gcc 14.

(2), (3), and (4) all argue for rebuilding glibc 2.31 itself in our
build (with CET, `--enable-kernel=3.2.0`, and gcc 14) rather than
pulling the prebuilt glibc from nixos-20.09.
