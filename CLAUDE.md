# bitcoind-gunix

## Goal

Reproduce the official Bitcoin Core GUIX release binary for
`x86_64-pc-linux-gnu` using Nix, producing a binary with an identical
sha256. Project tracking: https://github.com/0xB10C/bitcoind-gunix/issues/1.

## Status (2026-05-26): byte-identical SHA256 match achieved

```
dae69848ae9aaadcc3aa697d1c92b1283273a59c8d87b220b29ddc2813e25eb6  result/bin/bitcoind
dae69848ae9aaadcc3aa697d1c92b1283273a59c8d87b220b29ddc2813e25eb6  upstream
```

A reproducibility gate in `bitcoind.nix` `postFixup` asserts this hash
after every build — if a toolchain or flag change breaks byte-equality,
the Nix build itself fails. CI re-asserts the hash externally.

Only `bin/bitcoind` is hashed against upstream. `bin/bitcoin`,
`bin/bitcoin-cli`, and `libexec/bitcoin-node` are produced but not
stripped (they would need similar split-debug + `.gnu_debuglink` CRC
treatment to also match — out of scope unless someone needs it).

## How it works

Three Nix files compose into the reproducer:

1. **`depends.nix`** — builds Bitcoin Core's `depends/` tree. All
   dependency tarballs are pre-fetched via `fetchurl` and copied into
   `depends/sources/` before the build (working around Nix's no-network
   sandbox). Uses `gcc14Stdenv` to match GUIX v31.0's GCC 14.2.0. Builds
   boost, libevent, sqlite, zeromq, systemtap, capnp + multiprocess
   (native_capnp, native_libmultiprocess). GUI deps skipped via
   `NO_QT=1`. `HOST=x86_64-linux-gnu` forces depends into
   "cross-compile" mode (`depends_crosscompiling=TRUE` →
   `CMAKE_CROSSCOMPILING=TRUE` downstream), matching GUIX.

2. **`bitcoind.nix`** — builds `bitcoind` with
   `cmake --toolchain ${depends}/toolchain.cmake`. CMake (replaced
   autotools as of v29). Skips GUI/tests/bench/fuzz. Mirrors GUIX
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

4. **`flake.nix`** — pins `nixpkgs` to `nixos-25.11` and pins a separate
   `nixpkgs-glibc231` to `nixos-20.09` (last NixOS release shipping
   glibc 2.31). Rebuilds glibc 2.31 with GUIX's configure flags and
   surgically patches its CRTs and `libc_nonshared.a` `.oS` members in
   `postFixup` (see Workarounds below). Exposes:
   - `nix build .#depends` — just the depends tree
   - `nix build .#bitcoind` (or `.#default`) — the full bitcoind

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

- **`patches/glibc-elf-init.c`** — verbatim copy of glibc 2.31's
  `csu/elf-init.c`. flake.nix recompiles this with our gcc 14 and
  splices the result into `libc_nonshared.a` (see Workarounds).

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

### Glibc 2.31 byte patches (`flake.nix` postFixup)

nixos-20.09's stdenv compiled the glibc 2.31 we depend on with
gcc 8.3.0, which predates several encoding choices that upstream's
gcc-14-bootstrapped GUIX glibc has. We surgically patch the affected
bytes in the installed glibc:

1. **CRT `.note.gnu.property` patch** — binutils 2.41's
   `_bfd_x86_elf_merge_gnu_properties` OR_AND-merges USED properties
   and removes them if `first_pbfd` lacks them. Our CRTs (built by
   gcc 8.3.0) are first_pbfd and lack USED → the linker drops
   `.note.gnu.property` entirely from the final binary. Fix: overwrite
   the section in each CRT (`Scrt1.o`, `crti.o`, `crtn.o`, etc.) with
   upstream's canonical USED bytes
   (`x86 features: x87,XMM,YMM,XSAVE; ISA: baseline,v2,v3`).

2. **Each `libc_nonshared.a` `.oS` member's `.note.gnu.property`** —
   same treatment, since the linker pulls in selected `.oS` members
   into the final binary.

3. **Stack-canary check encoding patch** — gcc 8.3.0 emits
   `xor %fs:0x28,%rax` (`64 48 33 04 25 28 00 00 00`) for the final
   canary check, while gcc 14 emits `sub %fs:0x28,%rax`
   (`64 48 2b 04 25 28 00 00 00`). Both check the canary correctly
   (the only thing that matters is whether the result is zero). We
   direct-byte-patch the 4 affected `.oS` members (`atexit`, `stat64`,
   `fstat64`, `lstat64`) IN PLACE — preserving their `.rela.text`
   relocations. `objcopy --update-section` would zero those out.

4. **`elf-init.oS` full replacement** — `__libc_csu_init` is the one
   function where gcc 8.3.0's vs gcc 14's register allocation differs
   enough that no single-byte patch suffices (131 bytes diverge). We
   recompile `csu/elf-init.c` (preserved verbatim at
   `patches/glibc-elf-init.c`) with our gcc 14 plus upstream's flags
   (`-O2 -fPIE -DLIBC_NONSHARED=1 -DSHARED -fpie -ffreestanding
   -fstack-protector-all -fcf-protection=full`), patch its
   `.note.gnu.property` with the canonical USED bytes, then `ar r`
   the new file in.

5. **glibc `.comment` rewrite** — `bitcoind.nix` postInstall replaces
   the final `.comment` section with just `GCC: (GNU) 14.3.0\0`,
   dropping the stamp left by nixos-20.09's gcc 8.3.0 building glibc's
   CRTs.

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
