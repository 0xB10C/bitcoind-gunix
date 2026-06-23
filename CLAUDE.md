# bitcoind-gunix

## Goal

Reproduce the official Bitcoin Core GUIX release binary for
`x86_64-pc-linux-gnu` using Nix, producing a binary with an identical
sha256. Project tracking: https://github.com/0xB10C/bitcoind-gunix/issues/1.

## Status (2026-06-23): aarch64-on-aarch64 trivial-cross chain BUILDS end-to-end under qemu — 10/20 artifacts byte-match, libzmq codegen diverges

After commits e56088fa…c610b8cc (5 trivial-cross fixes), the local
qemu-emulated `nix build .#packages.aarch64-linux.bitcoindAarch64`
runs the full chain — bootstrap nolibc gcc, glibc 2.31, cross gcc14,
the entire depends tree (boost/libevent/sqlite/zeromq/capnp/Qt6/the
X11 stack), and all 10 bitcoin binaries + their `.dbg` files — to
completion. Of the 20 artifacts:

- **10/20 byte-match upstream** (the 5 CLI tools + their `.dbg`):
  `bin/bitcoin`, `bin/bitcoin-cli`, `bin/bitcoin-tx`, `bin/bitcoin-util`,
  `bin/bitcoin-wallet` (and `.dbg` for each).
- **10/20 diverge** — exactly the 5 binaries that statically link
  libzmq (bitcoind, bitcoin-qt, libexec/{bitcoin-node, bitcoin-gui,
  test_bitcoin}) + their `.dbg` files.

`addr2line` on the first byte divergence in bitcoind localizes it to
**libzmq's `src/ctx.cpp`** (`zmq::ctx_t::connect_inproc_sockets`,
`zmq::thread_ctx_t::set`, `zmq::ctx_t::find_endpoint`,
`zmq::ctx_t::connect_pending`, etc.); ours allocates a smaller stack
frame (`sub sp, sp, #0xf0`) than upstream (`sub sp, sp, #0x110`) for
the same function. Same total binary size, same `.comment` (gcc 14.3.0),
same section layout — a register-allocation/spilling difference, not
a path or debug-info flip. The 5 non-zmq-linking binaries match
exactly, so the divergence is contained to libzmq's object files.

Most likely cause: **qemu-vs-native nondeterminism in gcc's
host-arithmetic-dependent codegen heuristics**. gcc's `genoutput`/
`genrecog` and the register-allocator cost model use floating-point;
qemu-user emulation's fp can round differently than native aarch64,
shifting allocation decisions in some functions. The successful
non-zmq binaries are simpler and don't trigger the flip; libzmq's
`ctx.cpp` does. Definitive proof requires building on a real aarch64
host (the `ubuntu-24.04-arm` CI runner is what byte-validates).

### The 5 trivial-cross fixes (in commit order)

1. **`gccWithoutTargetLibc.cc` `--disable-fixincludes`**
   (e56088fa, narrowed to gccWithoutTargetLibc in 6bb3ffb7).
   gcc-15.2 unconditionally sets `STMP_FIXINC=stmp-fixinc`; on aarch64
   build-host, target `aarch64-linux-gnu` canonicalizes to the same
   internal triple as host `aarch64-unknown-linux-gnu` (unlike x86's
   `pc` vendor default), gcc sees build==target, runs `fixinc.sh`
   against `/usr/include`, fails in the sandbox.
2. **`gccWithoutTargetLibc.cc` `inhibit_libc` when `--without-headers`**
   (695264c7). `gcc/configure.ac:2577-2582` only sets `inhibit_libc`
   when host!=target OR newlib; for trivial-cross's bootstrap (no
   target libc yet), inject `if test "x$with_headers" = xno; then
   inhibit_libc=true; fi` after the existing `:${inhibit_libc=false}`
   so libgcc doesn't try to `#include <stdio.h>`.
3. **`gccWithoutTargetLibc.cc` libgcc install-layout**
   (b8d233c0). The nolibc bootstrap installs `libgcc_s.so{,*.1}` at
   `$out/lib/` instead of `$out/aarch64-linux-gnu/lib/`. nixpkgs'
   `preFixupLibGccPhase` expects the cross layout. Relocate explicitly.
4. **TOP-level `configure.ac` `--with-headers` exit 1 deletion**
   (af4bce22). `configure.ac:2743-2747` bails with `*** --with-headers
   is only supported when cross compiling` and `exit 1` when
   `is_cross_compiler=no`. nixpkgs' cc-wrapper always passes
   `--with-headers`. Delete the `exit 1` (keep the warning) via sed on
   both `configure` and `configure.ac`.
5. **gcc14 `CROSS=-DCROSS_DIRECTORY_STRUCTURE` injection** (af4bce22
   broad version, c610b8cc narrow version — replaces broad).
   `gcc/configure.ac:2526-2533` only sets `CROSS` when host!=target.
   With `CROSS` unset, `gcc/cppdefault.cc:31-36` `#undef
   CROSS_INCLUDE_DIR`s → gcc's preprocessor search NEVER includes
   `$(prefix)/$(target_alias)/sys-include/` (where `--with-headers`
   copied glibc headers) → cc-wrapper's `-idirafter $libcCross/include`
   provides them → DWARF records the un-mapped store paths.
   *Narrow* version (c610b8cc): append a fallback `if test
   x"${with_headers}" != x && ... ; then CROSS="-DCROSS_DIRECTORY_
   STRUCTURE"; fi` AFTER the closing `fi` of the existing host!=target
   gate, instead of broadening the gate itself. The broad version
   also forced `ALL=all.cross`, which skips lang.all.cross's target
   libstdc++ build path → boost link fails with `cannot find -lstdc++`.
6. **gcc14 install layout + pkgconfig stub** (c610b8cc). On trivial-
   cross, `--enable-shared` installs `libstdc++.so*`, `libgcc_s.so*`,
   `libstdc++*.a`, `libsupc++.a` at `$out/lib/` instead of
   `$out/aarch64-linux-gnu/lib/`. nixpkgs' gcc `moveToOutput
   "$targetConfig/lib/lib*.so*" $lib` finds nothing → cross
   `$lib/aarch64-linux-gnu/lib/` empty → boost link fails. Pre-
   relocate `.so*` AND `.a` archives (bitcoind uses `-static-libstdc++
   -static-libgcc`, needs the .a there too) before nixpkgs'
   postInstall runs. Gate on derivation name `*aarch64-linux-gnu-gcc-*`
   so the build-host NATIVE gcc14 (no triple prefix) is not disturbed.
   Also stub `$out/{lib,share}/pkgconfig/gcc-trivial-cross-stub.pc`
   so nixpkgs' `_multioutDevs` sed loop (`multiple-outputs.sh:176`,
   no nullglob) finds at least one `.pc` to iterate.

CI's `continue-on-error: true` on `build-on-aarch64-host` was removed
in af4bce22-era prep but the byte-equality of zmq-linked binaries
remains an aarch64-runner-only proof. The qemu-emulated local build
runs to completion and asserts what it can.

## Status (2026-06-20): aarch64-on-aarch64 trivial-cross fix in flight — `--disable-fixincludes` overlay, CI un-pinned

The aarch64-host build path (the `build-on-aarch64-host` arm CI job that
was `continue-on-error: true` since 2026-06-11 — the only POSTPONED gap
on issue #6, see that status section below) gets a one-derivation fix:
`nix/aarch64-linux-gnu/toolchain.nix` now imports `pkgsCrossAarch64`
with a `fixincludesOverlay` that appends `--disable-fixincludes` to
`gccWithoutTargetLibc.cc` (the bootstrap nolibc cross-stage-static
gcc 15.2 that fails first), `gcc14.cc` (our `crossGuixGcc` base), and
`gcc15.cc` (the libc-aware cross gcc nixpkgs builds before our gcc-14.3
override applies). Gated on `buildSystem == "aarch64-linux"` so x86_64
build-host drvs are byte-identical pre/post.

Why: gcc-15.2 `gcc/configure.ac:2595` sets `STMP_FIXINC=stmp-fixinc`
unconditionally, zeroed only by `--disable-fixincludes` (line 2606); on
an aarch64 build host both our target `aarch64-linux-gnu` and the
host's `aarch64-unknown-linux-gnu` canonicalize to the same internal
triple (unlike x86_64's `pc` default vendor — which is why the x86
cross-to-self never hit this), gcc's build system sees build == target,
runs fixinc.sh against /usr/include, fails in the sandbox. The overlay
catches every gcc that would hit this; verified at eval level (x86 drvs
unchanged) and that the flag survives our
`.override { libcCross = crossGlibc231 }` + `.overrideAttrs` layering
into `crossGuixGcc`.

CI's `continue-on-error: true` is removed; final byte-proof comes from
the green `build-on-aarch64-host` run. Local qemu-emulated build of the
bootstrap nolibc gcc on x86_64 (via `boot.binfmt.emulatedSystems` set
on the NixOS host so the nspawn container inherits the registration)
runs in parallel as a sanity check.

## Status (2026-06-14, darwin LC_UUID): root-caused — zero byte/UUID patching anywhere in the project

The darwin `bitcoin-qt`/`bitcoin-gui` LC_UUID divergence (the project's
LAST byte patch, `patch-uuid.py`/`uuidPatches`) is now root-cause fixed
and the patch machinery is REMOVED entirely.

Root cause: `qtbase_plugins_cocoa.patch` disables precompiled headers for
`QCocoaIntegrationPlugin` only when `CMAKE_VERSION VERSION_LESS "3.25" AND
NOT QT_FEATURE_sessionmanager`. Bitcoin's qt.mk disables sessionmanager
unconditionally on every host, so the guard reduces to the cmake-version
check. GUIX builds depends with cmake-minimal **3.24.2** (guard fires →
PCH disabled for QCocoaIntegrationPlugin, i.e. `qnsview.mm` + the rest of
the cocoa plugin sources in `libqcocoa.a`); nixpkgs' cmake is >=3.25 (guard
never fires → PCH stays enabled, Qt's default). PCH usage doesn't change
`qnsview.mm`'s emitted `.text`/`.data` but shifts the unstripped image's
Objective-C `_OBJC_SELECTOR_REFERENCES_`/`_OBJC_CLASSLIST_REFERENCES_$_`
symtab numbering by a small constant — enough to flip lld's xxh3 LC_UUID
(an xxh3 of the UNSTRIPPED link-time image).

Fix (`depends.nix`, darwin `postPatch`): append a sed to `packages/qt.mk`
that strips the `CMAKE_VERSION VERSION_LESS "3.25" AND ` clause from
qtbase's cocoa `CMakeLists.txt`, so `DISABLE_PRECOMPILE_HEADERS ON` fires
unconditionally — matching GUIX's effective cmake-3.24.2 behavior. A
build-configuration fix, not a binary patch.

Verified: with this fix, the UNSTRIPPED `bitcoin-qt`/`bitcoin-gui` LC_UUID
match upstream's exactly (`4C4C4470-5555-3144-A1E1-F35D6E3FD77F` /
`4C4C446C-5555-3144-A10B-6656C86400B1` for x86_64, similarly for arm64) —
no patching needed. Removed entirely: `patch-uuid.py`, `uuidPatches`,
`patchOutCmds`/`qtUuidHex`, `captureUnstripped`/`unstripped` output, and
the throwaway `bitcoindDarwinX86Debug` derivation (from
`bitcoind-darwin.nix`, `default.nix`, `flake.nix`). Rebuilt + re-verified
ALL 30 darwin checks (10 binaries × 2 archs via the `withGate=true`
postFixup, + 5 downstream artifacts × 2 archs: `-unsigned.tar.gz`,
`-unsigned.zip`, `-codesigning.tar.gz`, signed `.tar.gz`, signed `.zip`) —
every hash still matches upstream's SHA256SUMS with **zero byte/UUID
patches anywhere in the project**.

The `unshare --user --map-root-user --mount` chroot (for matching GUIX's
literal DISTSRC paths in the Mach-O N_SO/N_OSO stabs that feed LC_UUID)
remains REQUIRED and structural: the Nix sandbox root is read-only
(no `CAP_SYS_ADMIN` in the initial user namespace for bind-mounts/chroot),
but creating a new user namespace (`CLONE_NEWUSER` via `--map-root-user`,
the rootless-container trick) grants those capabilities scoped to that
namespace — there is no flag-based alternative, since `-fdebug-prefix-map`/
`-ffile-prefix-map` have no effect on linker-recorded STABS. CI note:
Ubuntu 24.04+'s AppArmor `unprivileged_userns_restriction`
(`kernel.apparmor_restrict_unprivileged_userns`) blocks `CLONE_NEWUSER` on
`ubuntu-latest` runners (`unshare: write failed /proc/self/uid_map:
Operation not permitted`) — both darwin jobs DID hit this on first run, so
`nix-ci.yml` now runs `sudo sysctl -w
kernel.apparmor_restrict_unprivileged_userns=0` as the first step of
`build-darwin-x86`/`build-darwin-arm64`, before the darwin nix-build steps
(`runner` has passwordless sudo on GH-hosted runners).

## Status (2026-06-14, win64 + PROJECT COMPLETE): ALL v31.0 win64 artifacts reproduce — issue #6 DONE, every target byte-identical

win64 is now fully reproduced: all 6 published artifacts byte-match
upstream's SHA256SUMS:

- `bitcoin-31.0-win64-unsigned.zip` (`5ecd365b…`)
- `bitcoin-31.0-win64-debug.zip` (`df3f8c2f…`)
- `bitcoin-31.0-win64-setup-unsigned.exe` (`ad31d4d8…`)
- `bitcoin-31.0-win64-codesigning.tar.gz` (`62baf547…`)
- signed `bitcoin-31.0-win64-setup.exe` (`1893e819…`)
- signed `bitcoin-31.0-win64.zip` (`82fd2c50…`)

`win-codesigning.nix` (`.#codesigningMingw`) assembles the codesigning
tarball — `windeploy/{detached-sig-create.sh, win-codesign.cert, unsigned/
{bitcoin-31.0-win64-setup-unsigned.exe, bitcoin-31.0/…}}` (the same tree as
`-unsigned.zip`'s `bitcoin-31.0/`, minus `.dbg`), packed with the same
`find|sort|tar|gzip -9n` as the release archives. Byte-matched on the first
build.

`win-signed.nix` (`.#signedMingw`) mirrors `codesign.sh`'s `*mingw*)` case:
extracts the codesigning tarball, applies `bitcoin-detached-sigs`' v31.0
`.pem` signatures (9 total: setup + 7 `bin/*.exe` + `libexec/test_bitcoin.exe`)
via `osslsigncode attach-signature`, moves the signed setup.exe out, and
`find|sort|zip -X@`s the signed `bitcoin-31.0/` tree. Both outputs
byte-matched on the first build. Two findings:

- **osslsigncode pinned to GUIX's 2.5** (`osslsigncode25` —
  `pkgs.osslsigncode.overrideAttrs` with `fetchFromGitHub rev="2.5"`;
  nixpkgs ships 2.13). attach-signature's PE-patching (cert-table RVA/size
  write + checksum recompute) is version-sensitive.
- **`-CAfile` is a no-op for output bytes**: `append_signature` +
  `update_data_size` (checksum recompute) run BEFORE the post-attach
  `check_attached_data`/`verify_signature` step, and on verification
  failure the already-written output is KEPT (only the exit code goes
  nonzero) — so `${cacert}/etc/ssl/certs/ca-bundle.crt` + `|| true` suffices
  regardless of whether the chain validates against it.

Issue #6 — and the whole multi-arch reproduction project — is now COMPLETE:
every published artifact of `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`riscv64-linux-gnu`, `armhf`, `powerpc64-linux-gnu`, `x86_64-apple-darwin`,
`arm64-apple-darwin`, and `x86_64-w64-mingw32` (incl. all signed/codesigning
variants) byte-matches upstream's GUIX v31.0 release.

## Status (2026-06-14, win64 NSIS): setup-unsigned.exe REPRODUCES byte-for-byte — codesigning + signed setup remain

`nix build .#setupExeMingw` produces `bitcoin-31.0-win64-setup-unsigned.exe`
byte-identical to upstream (`ad31d4d8…`, gate now ON). The `win64-setup-
unsigned.exe` (NSIS installer) = a ~98 KB NSIS STUB + an LZMA-solid payload
(the 7 stripped `.exe` we reproduce + COPYING/readme/conf/rpcauth/pixmaps).
GUIX builds it with `cmake --build build -t deploy` → makensis (nsis-x86_64
**3.10**; gnu/packages/installers.scm `make-nsis`: native makensis +
CROSS-compiled stubs). The stub is compiled by GUIX's **default** cross-gcc —
`%xgcc` = gcc-11 = **11.4.0** (the stub's `.comment` reads "GCC: (GNU)
11.4.0"), NOT the bitcoin base-gcc 14.3.0 — with the default cross-binutils
(2.41) + cross-libc (mingw-w64 12.0.0).

Wired up (`default.nix`): nixos-26.05 REMOVED gcc11, so a second flake input
**`nixpkgs2405`** (nixos-24.05, gcc11 = 11.4.0; its mingw cross binutils is
already 2.41) supplies it. `nsisHeaders12Overlay` (pin mingw-w64 → 12.0.0),
`nsisCrtBootSet` (a SEPARATE clean 24.05 import — the CRT compiler, to break
the splice cycle "gcc11.libcCross = this CRT", same trick as `mingwBootSet`),
`nsisCrtStdenv` (gcc 11.4.0 NoFp), `pkgsCrossMingwNsis` (mingw-w64 CRT REBUILT
with `nsisCrtStdenv` + GUIX's bare-gcc hardeningDisable + `--with-default-
msvcrt=msvcrt` (24.05's mingw_w64 recipe defaults msvcrt builds to UCRT in
12.0.0; force msvcrt.dll like GUIX's gcc-11 CRT) — else 24.05's default gcc
13.2.0 stamps the stub with "GCC 13.2.0"), `nsisGcc11` (NoFp gcc 11.4.0).
`nsis310.nix` (GUIX's `make-nsis` scons flags; `nsis-env-passthru.patch`;
preBuild `SOURCE_DATE_EPOCH=1` → version "v01-Jan-1970.cvs" + stub COFF PE
TimeDateStamp 1; buildPhase wraps the whole scons build in `faketime -f
"1970-01-01 00:00:01"` (epoch+1, using `pkgs2405.libfaketime` for glibc-ABI
compatibility with the 24.05 toolchain) so `ld`'s PE `.rsrc`
IMAGE_RESOURCE_DIRECTORY.TimeDateStamp — written via `time(NULL)`, a separate
field from the COFF ts and NOT covered by SOURCE_DATE_EPOCH — also comes out
deterministic). `win-nsis.nix` (reproduces cmake `generate_setup_nsi`'s
`@VAR@` substitution by hand — verified BYTE-IDENTICAL to GUIX's generated
`.nsi` after path-normalize — then `makensis -V2`; also strips
`.gnu_debuglink` from each release `.exe` via `mingwBinutils241 objcopy`
under the same frozen faketime, reproducing GUIX's `deploy` target which
strips the cmake build-tree binary directly, before split-debug ever added
that section).

DONE: the entire installer stub (exehead, ~98 KB) + the embedded uninstaller
+ both NSIS plugin DLLs + all 7 bundled release `.exe` byte-match upstream;
the decompressed LZMA-solid payload is byte-identical
(108573603 bytes); overall sha256 == `ad31d4d8…`. Attrs: `.#nsis310`,
`.#nsisGcc11`, `.#setupExeMingw` (gated, asserts `ad31d4d8…`).

NEXT: `win64-codesigning.tar.gz` (`62baf547…`) + osslsigncode-signed
`win64-setup.exe` (`1893e819…`) + signed `win64.zip` (`82fd2c50…`) — the win64
analog of the darwin signing flow (signapple.nix / detachedSigs already
established for darwin, but win64 signing uses osslsigncode + Authenticode,
not signapple).

## Status (2026-06-14, win64): ALL 8 PE binaries + both .dbg + unsigned.zip + debug.zip REPRODUCE byte-for-byte — NSIS + signing remain

`nix build .#bitcoindMingw` gates all 16 hashes (8 .exe + 8 .dbg, every one
byte-identical to upstream), `.#unsignedZipMingw` assembles `win64-unsigned.zip`
(`5ecd365b…`) and `.#debugZipMingw` `win64-debug.zip` (`df3f8c2f…`) — both
byte-match. The `.dbg` byte-repro (which closed the 6-byte CheckSum/CRC residue
on the stripped .exe) needed FIVE fixes, found by per-section/-CU diffing the
`.dbg` against the local GUIX build (`bitcoin/guix-build-31.0/distsrc-31.0-
x86_64-w64-mingw32`, which the user provided — its installed `.dbg` == published,
its `.obj` survive for per-object diffing):

1. **CRT/winpthreads DW_AT_producer** — drop the flags upstream's flag-free
   base-gcc never records (uniform +86 B/crt-CU, +75 B/winpthreads-CU,
   codegen-neutral since x86_64 -O2 already omits FP): build the CRT/winpthreads
   with a **NoFp wrapper** (`stripMingwFpFlags` — strips the wrapper's
   `-fno-omit-frame-pointer`/`-mno-omit-leaf-frame-pointer` instead of adding
   `-fomit…` via NIX_CFLAGS, so no FP flag is recorded); drop our extra `-g` from
   `mingwCrtDbgFlags` (the autoconf default `-g -O2` already supplies one);
   strip `-frandom-seed` (reproducible-builds hook); `ac_cv_prog_cc_c23=no` so
   autoconf 2.72's AC_PROG_CC doesn't append `-std=gnu23` to the crt's CC.
2. **CRT/winpthreads header dir tables** — GUIX's make-mingw-w64 (mingw.scm
   setenv phase) sets `CROSS_C_INCLUDE_PATH` to the IN-SOURCE split
   `mingw-w64-headers/{,include,crt,defaults/include,direct-x/include}`, NOT
   nixpkgs' MERGED `mingw_w64_headers` package. Mirror with `-isystem` in GUIX's
   order (`mingwCrtHeaderInc`) so each header records the same split dir GUIX
   does (corecrt.h→/crt, winnt.h→/include); the existing /build/mingw-w64-v12.0.0
   → ephemeral map rewrites them.
3. **gcc-builtin headers** — a few crt/winpthreads files pull `<xmmintrin.h>`
   etc. from the boot gcc's lib/gcc/<triple>/14.3.0/include → map to
   `/usr/lib/gcc/...` (added to `mingwCrtDbgFlags`).
4. **bitcoin's own CU header paths** — the final gcc's
   `--with-native-system-header-dir = mingwLibc/include` is a symlinkJoin; gcc
   REALPATHS each header through it to the component output, recording
   `${mingwCrt.dev}/include` + `${mingwPthreads}/include` (NOT
   `${guixGcc}/sys-include`). Map both components → /usr/include in
   bitcoind-win.nix.
5. **COMDAT `.debug_frame$` selection** (last ~268 .dbg bytes) — the FINAL
   binutils (`mingwBinutils241`) must NOT `--enable-compressed-debug-sections`:
   with it, gas emits PE `.zdebug_frame$<mangled>` for C++ COMDAT FDEs while the
   COMDAT group symbol stays `.debug_frame$<mangled>`; ld warns "COMDAT symbol
   does not match section name" and drops the IMAGE_COMDAT_SELECT_ANY (comdat 2)
   selection during cross-TU dedup → our COFF symtab had comdat 0 where upstream
   has 2. Uncompressed = names match = selection preserved (GUIX's .obj confirm
   uncompressed/comdat 2). (Linux .dbg ARE SHF_COMPRESSED so they keep the flag;
   PE .dbg are not — the flag was wrong for mingw.)
6. **.debug_loclists GGC poison on the 3 biggest binaries** (bitcoind/-qt/
   test_bitcoin, −44 B) — the depends `-ffile-prefix-map`'s per-header ggc_alloc
   shifts var-tracking's loclist representative choice (the armhf/ppc64 root
   cause). Fix = the SAME `canonDepends`: `gcc-debug-canon-prefix-map.patch` on
   `mingwGuixGcc` + route depends→/bitcoin through `NIX_DEBUG_CANON_PREFIX_MAP`
   (malloc'd, GGC-neutral; v6 covers the __FILE__ macro too) in bitcoind-win.nix.

(Earlier `.debug_frame` CIE-version + producer/header work — see the prior WIP
section below for the full toolchain context.)

REMAINING (issue #6 win64): NSIS `win64-setup-unsigned.exe` (`ad31d4d8…`, nsis
3.10) + `win64-codesigning.tar.gz` (`62baf547…`); osslsigncode-signed
`win64-setup.exe` (`1893e819…`) + `win64.zip` (`82fd2c50…`).

## Status (2026-06-13, win64 WIP): 8 PE binaries' CODE 100% byte-reproduced — only 6 .dbg-derived bytes differ (PE CheckSum + .gnu_debuglink CRC); .dbg/.zip/NSIS/signing remain

bitcoin-cli.exe (and all 8) now differ from upstream in EXACTLY 6 bytes: the
PE optional-header CheckSum (2 B @ 0xd8) and the .gnu_debuglink CRC32 (4 B) —
both computed FROM the .dbg. Every loadable section (.text/.data/.rdata/.pdata/
.xdata/.idata/.rsrc/.reloc/…) is byte-identical. So the codegen is DONE; the
binaries fully match once the .dbg is byte-reproduced (then the CRC + CheckSum
fall out). Root causes closed (each verified at disasm/byte level): bitcoind FP
(NoFp wrapper strips BOTH frame-pointer flags), CRT/winpthreads FP +
zerocallusedregs, the binutils-2.41 NOP-fill order, the gcc14 CRT (crtexe.c
__tmainCRTStartup — gcc15 made dllimport `mov`→`lea`, +16 B; needs gcc 14.3.0
via the src-swap trick — see win64-goal memory), and the CRT/winpthreads must
use PLAIN binutils 2.41 (NO unaligned-default patch — GUIX's make-mingw-w64
passes no #:xbinutils; only the FINAL gcc's binutils gets the patch, for
libgcc/bitcoin which pass -Wa,-muse-unaligned-vector-move).

REMAINING: .dbg byte-repro (closes the 6 bytes → unsigned.zip/debug.zip),
NSIS setup-unsigned.exe + codesigning.tar.gz, osslsigncode signing. See below.

## Status (2026-06-13, win64 earlier): mingw toolchain + depends BUILD

win64 (x86_64-w64-mingw32) is the last issue-#6 target. 6 artifacts to
reproduce: `win64-unsigned.zip` (5ecd365b…), `win64-debug.zip` (df3f8c2f…),
`win64-setup-unsigned.exe` (ad31d4d8…), `win64-codesigning.tar.gz`
(62baf547…), signed `win64-setup.exe` (1893e819…) + `win64.zip`
(82fd2c50…). 8 PE binaries (bitcoin{,-cli,-tx,-util,-wallet,-qt,d}.exe +
libexec/test_bitcoin.exe; NO node/gui — ENABLE_IPC OFF for WIN32). Upstream
refs in `tmpdiff/upstream-win64/{unsigned,debug}-extract`.

DONE: the GUIX-exact mingw toolchain (`default.nix`): `pkgsCrossMingw` =
mingwW64 cross, `libc="msvcrt"`, overlay pinning mingw-w64 **12.0.0** (override
`windows.mingw_w64_headers`). gcc **14.3.0** (`mingwGuixGcc`:
`--enable-default-ssp=yes --enable-host-bind-now=yes --disable-gcov
--disable-libgomp` + gcc-ssa-generation.patch) + binutils **2.41**
(`mingwBinutils241`, + binutils-unaligned-default.patch). **POSIX threads** —
NOT via the global `threads` overlay (leaks winpthreads' pthread.h into native
libcody → `process.h` error); instead MERGE winpthreads into the cross libc
(`mingwLibc` = symlinkJoin `[pthreads mingw_w64 mingw_w64.dev]`, **pthreads
FIRST** so its real `pthread_time.h` wins over the CRT dummy), passed as gcc
`libcCross` + cc-wrapper `libc` + bintools `libc`, with
`threadsCross={model="posix";package=null;}`. `dependsMingw` builds the full
win64 depends incl. Qt (depends.nix `isMingw` branch: LIBRARY_PATH =
`nativeLibraryPathDir` full gcc+glibc union; `CMAKE_SYSTEM_IGNORE_PATH=<glibc>/lib`
in funcs.mk + qt.mk so Qt's FindWrapRt HAVE_GETTIME check works — same
find_library glibc-leak as darwin; NO posix-shm/sem preseed, Windows Qt uses
the win32 backend). `bitcoind-win.nix` builds the 8 PE binaries
(HOST_CFLAGS `-O2 -g -fno-ident` + prefix maps, LDFLAGS
`-Wl,--no-insert-timestamp`, split-debug w/ mingw objcopy, no .comment),
`win-zip.nix` assembles the unsigned/debug .zip.

The CRT/winpthreads toolchain (the hard part): built by `mingwCrtStdenv` /
`mingwPthreadsStdenv` (from a SEPARATE clean cross import `mingwBootSet`, no
windows override → no splice cycle), using `stdenvNoLibc.cc` (NOT
`gccWithoutTargetLibc`, which drags in an uncacheable broken
`bash-x86_64-w64-mingw32`) with (a) bintools swapped to binutils 2.41 and (b)
the unwrapped gcc15 nolibc cc rebuilt with `--with-as/--with-ld=2.41` appended
(the bootstrap BAKES `--with-as=2.46`, which reverses the alignment NOP-fill
ORDER — short-first vs 2.41 long-first — seen in `pre_c_init` padding at .text
start). gcc15==gcc14 for the CRT (byte-identical), so only binutils 2.41
matters. winpthreads needs the CRT-aware variant (`mingwPthreadsStdenv`, libc =
boot CRT) because it links a shared libwinpthread; bitcoind statically links
the .a, so the shared-link CRT never reaches the binary. mingw_w64/pthreads
also get FP-omit + hardeningDisable(zerocallusedregs…) overrides (GUIX builds
the CRT with plain base-gcc, none of nixpkgs' wrapper injections).

ROOT CAUSES FIXED (each verified at the byte/disasm level): bitcoind frame
pointers (NoFp wrapper stripping BOTH `-fno-omit-frame-pointer` AND
`-mno-omit-leaf-frame-pointer`; x86_64 -O2 omits both, upstream producer is
flag-free); CRT/winpthreads frame pointers + `zerocallusedregs` (register-
zeroing xors) + the binutils-2.41 NOP-fill order. After all fixes the startup
(`pre_c_init`, long-first padding) and the bulk of .text/.rdata/.pdata match.

REMAINING (NOT yet reproduced):
- **Binaries**: residual ~96 B .text (+) / ~328 B .xdata (−) — a codegen size
  delta in the CRT/winpthreads/early region (.pdata is size-identical, so SAME
  function count; the .xdata delta points to a prologue/unwind difference in
  some functions). Could not localize further: the .dbg path spellings differ
  (not byte-matched) so function-level alignment is unreliable, and there is no
  local GUIX *mingw* reference to diff against (same wall as the darwin
  LC_UUID). Likely a subtle GUIX-vs-nixpkgs mingw-w64 12.0.0 CRT/winpthreads
  build-flag difference (e.g. GUIX's make `DEFS=-DHAVE_CONFIG_H
  -D__MINGW_HAS_DXSDK=1`, or a configure flag).
- **.dbg byte-repro** (needed for unsigned.zip — the stripped .exe embeds the
  `.gnu_debuglink` CRC of the .dbg): CRT/winpthreads need `-g` +
  `-fdebug-prefix-map` to GUIX ephemeral
  `/tmp/guix-build-mingw-w64-x86_64-winpthreads-12.0.0.drv-0/mingw-w64-v12.0.0/{mingw-w64-crt,mingw-w64-libraries/winpthreads}`;
  libgcc `-g`+map (`/tmp/guix-build-gcc-cross-x86_64-w64-mingw32-14.3.0.drv-0/build/x86_64-w64-mingw32/libgcc`);
  bitcoin CUs already map via `/build/bitcoin-31.0`→`${distsrc}/build/src`;
  toolchain header maps → /usr. See `tmpdiff/dbg-paths.txt`.
- **NSIS** `win64-setup-unsigned.exe` (cmake `deploy` target → makensis; pin
  nsis to GUIX's **3.10**, nixpkgs ships 3.11) + `win64-codesigning.tar.gz`.
- **Signing** (`win64-setup.exe`, `win64.zip`): osslsigncode 2.5 + win detached
  sigs from bitcoin-core/bitcoin-detached-sigs v31.0 — analogous to the darwin
  signed-artifacts flow.

Attrs: `.#mingwGuixGcc{,NoFp}`, `.#mingwBinutils241`, `.#dependsMingw`,
`.#bitcoindMingw` (gated, FAILS until the residual closes), `.#bitcoindMingwNoGate`
(builds; for diffing), `.#unsignedZipMingw` / `.#debugZipMingw` (gated).


## Status (2026-06-13): darwin x86_64 -unsigned artifacts REPRODUCE — all 10 binaries + .tar.gz + .zip; qt/gui LC_UUID patched

The full x86_64-apple-darwin `-unsigned` set byte-matches upstream:
`nix build .#bitcoindDarwinX86` gates all 10 Mach-O binaries,
`.#tarballDarwinX86` the `-unsigned.tar.gz` (`d1d0174f…`) and
`.#zipDarwinX86` the `-unsigned.zip` (`b8d9b991…`). Round-2 closed the
three round-1 root causes; two follow-on fixes + one accepted patch
finished it:

- **kj fibers — the LIBRARY_PATH must be a CURATED union.** Mirroring
  GUIX's `LIBRARY_PATH=$NATIVE_GCC/lib` with the RAW gcc+glibc lib dirs
  broke capnp's own tool links: `ld64.lld: …/glibc-2.42/lib/libpthread.so:
  unhandled file type`. nixpkgs' glibc 2.42 ships unversioned COMPAT
  SYMLINKS (libpthread/librt/libdl/libutil/libanl.so → .so.N, ELF stubs)
  that vanilla glibc dropped when those libs merged into libc in 2.34;
  capnp's `-lpthread` (CMake Threads) then hands ld64.lld the ELF and
  dies, where GUIX's `-lpthread` falls through to the SDK tbd. Fix:
  `darwinLibraryPathDir` in depends.nix — a runCommand union of gcc's lib
  + glibc's lib MINUS exactly those five compat links (one dir, like
  GUIX's). Re-verified both directions with direct clang/ld64.lld link
  tests: `-lpthread` links, `-lc` still errors (so the fibers
  makecontext check fails → KJ_USE_FIBERS=0, matching upstream).
- **LC_UUID — chroot fix WORKS for 8/10; qt/gui patched.** Building
  inside the unshare/userns chroot at GUIX's `/distsrc-base/distsrc-31.0-
  x86_64-apple-darwin` (depends at `/bitcoin/depends/<host>`) makes 8 of
  10 binaries byte-identical INCLUDING the UUID. bitcoin-qt and
  bitcoin-gui remained off by EXACTLY the 8 lld UUID digest bytes (byte 3
  + bytes 9-15 of the `"LLD\xa1UU1D"`+digest+swap(3,8) layout); the
  stripped images are otherwise byte-identical. The UUID is an xxh3 of
  the UNSTRIPPED link-time image, and the differing bytes live entirely
  in the Qt symtab/stabs region that `cmake --install --strip` removes
  AFTER lld hashes it. Ruled out every path leak (all N_SO/N_OSO stabs
  are GUIX-correct /distsrc-base, zero nix-store refs), .llvm./outlined/
  cold symbols, and codegen (__TEXT byte-identical). The residual is in
  the Qt local-symbol/stab content or ordering of the unstripped image;
  pinning it needs a GUIX darwin reference to diff against, which is
  UNAVAILABLE here (no guix binary, no darwin output in the local
  guix-build — only upstream's STRIPPED binary, which has no symtab).
  Matching the UUID is also REQUIRED for the signed artifacts (the
  detached-sig cdhash covers it). Decision (user-approved): copy
  upstream's literal UUID into exactly bitcoin-qt + bitcoin-gui post-link
  — the darwin analog of the historical .gnu_debuglink CRC patch.
  `patch-uuid.py` (new repo file; walks Mach-O load commands to LC_UUID
  0x1b, overwrites 16 bytes), `uuidPatches` knob in bitcoind-darwin.nix
  (values from the upstream -unsigned binaries), applied to $out/bin/
  bitcoin-qt + $out/libexec/bitcoin-gui AND the deploy app's
  Contents/MacOS/Bitcoin-Qt.
- **-unsigned.zip mode fix.** macdeployqtplus copies Qt's translations
  (Contents/Resources/qt_*.qm) straight from the read-only Nix store →
  mode 0444 → zip records the DOS read-only bit (external_attr
  0x81240001); upstream's GUIX deploy has them 0644 (0x81a40000). Fix:
  `chmod -R u+w build/dist/Bitcoin-Qt.app` before re-zipping (a no-op for
  the already-0755/0644 entries). The app binary is byte-identical to
  bin/bitcoin-qt, so it's UUID-patched too, then the zip is regenerated
  deterministically with the same cmake/script/macos_zip.sh
  (SOURCE_DATE_EPOCH touch + find|sort|zip -X@).

## Status (2026-06-13, later): ALL 10 darwin artifacts REPRODUCE — both arches, incl. -codesigning + SIGNED

macOS is DONE. Both arm64 and x86_64 now reproduce all FIVE published
artifacts each (10 total): -unsigned.tar.gz, -unsigned.zip,
-codesigning.tar.gz, signed .tar.gz, signed .zip — every one byte-matches
upstream's SHA256SUMS and self-gates:

```
x86_64                              arm64
fccf54f3…  -codesigning.tar.gz      955563c7…
56824dd7…  signed .tar.gz           a2d7a13b…
8e230f36…  signed .zip              fc119a34…
(+ the -unsigned.tar.gz/.zip from the prior status section)
```

- **signapple.nix** packages GUIX's exact signing toolchain: signapple
  @85bfcec + elfesteem @2eb1e53 (GUIX overrides signapple's own pyproject
  elfesteem pin, so we do too) + the achow101 **certvalidator FORK**
  @a145bf25 (signapple's `apply` verifies the result, hitting
  ValidationContext(additional_critical_extensions=…) which stock
  certvalidator lacks — stock fails with TypeError); asn1crypto + oscrypto
  1.3.0 from nixpkgs. Pure python, runs on Linux (no macOS APIs on the
  apply path). `.#signapple`.
- **detachedSigs** = bitcoin-core/bitcoin-detached-sigs @v31.0 (c88e80d8);
  osx/<host>/{bitcoin-31.0/{bin,libexec}/*.<arch>sign, dist/Bitcoin-Qt.app/…}.
- **darwin-codesigning.nix** assembles the -codesigning.tar.gz =
  unsigned-app/{detached-sig-create.sh, dist/Bitcoin-Qt.app, bitcoin-31.0/}
  (the bitcoin-31.0/ tree is byte-for-byte the -unsigned.tar.gz content, so
  it's extracted from the already-verified tarballDarwin), same
  deterministic find|sort|tar --mode|gzip -9n as the release archives.
- **darwin-signed.nix** mirrors codesign.sh: extract the codesigning
  tarball, `signapple apply` the app bundle + each binary in place, then
  the signed .zip (find|sort|zip -X@ over dist/) and signed .tar.gz
  (find|sort|tar over bitcoin-31.0/). Because the UUID-patched unsigned
  binaries are already upstream-identical, applying upstream's detached
  sigs reproduces the signed bytes exactly — confirmed for all four.

CI: two new x86_64-runner jobs `build-darwin-x86` / `build-darwin-arm64`
each build the full chain for one host and re-assert all 5 artifact
hashes (they push to Cachix like every other target).

Issue #6 remaining: win64 only.

## Status (2026-06-12, evening): macOS started — clang/lld 19.1.4 toolchain pinned, SDK staged, plan laid out

The macOS targets (arm64-/x86_64-apple-darwin, the next issue-#6 items)
are underway. 10 upstream artifacts to reproduce (5 per host):
`-unsigned.tar.gz` (48d34a14… arm64 / d1d0174f… x86_64), `-unsigned.zip`
(b639946d… / b8d9b991…), `-codesigning.tar.gz` (955563c7… / fccf54f3…),
and the SIGNED `.tar.gz` (a2d7a13b… / 56824dd7…) + `.zip` (fc119a34… /
8e230f36…) — the signed ones are reproducible too: codesign.sh applies
detached signatures (bitcoin-core/bitcoin-detached-sigs) with signapple
(pure python, pinned in manifest.scm), then re-tars/zips deterministically.

Structural differences vs the Linux targets (all verified in
manifest.scm/build.sh/darwin.mk):
- GUIX's darwin toolchain is just **clang-toolchain-19 + lld-19 (as ld)
  + zip + signapple** — no cross-gcc/glibc/binutils at all. depends/
  hosts/darwin.mk passes every cross flag explicitly (--target,
  -isysroot SDK, -nostdlibinc, -iwithsysroot, -mmacos-version-min=14.0,
  -mlinker-version=711, -Wl,-platform_version,macos,14.0,14.0,
  -Wl,-no_adhoc_codesign -fuse-ld=lld) against a bare `clang` from PATH.
- build.sh **unsets HOST_CFLAGS for darwin** → no `-g` anywhere, no
  DWARF, no .dbg/debug-tarball, no split-debug; install is
  `cmake --install --strip` (llvm-strip). Mach-O has no .comment and no
  DW_AT_producer ⇒ compile flags are never recorded — prefix-map flags
  may be added freely if `__FILE__` paths leak.
- depends darwin set: boost libevent qrencode qt sqlite zeromq capnp +
  native_{capnp,libmultiprocess,qt} — NO X11 stack.
- App zip: `cmake --build build -t deploy` → macdeployqtplus builds
  dist/Bitcoin-Qt.app, cmake/script/macos_zip.sh zips it (SOURCE_DATE_
  EPOCH touch + find|sort|zip -X@).

Done so far (committed in this change):
- **macOS SDK staged**: `Xcode-26.1.1-17B100-extracted-SDK-with-libcxx-
  headers` lives on the public mirror at https://bitcoincore.org/
  depends-sources/sdks/ (filename from darwin.mk, `.tar`, sha256
  9600fa93… = the hash in contrib/macdeploy/README.md). Downloaded +
  extracted into `bitcoin/depends/SDKs/` (gitignored; NEVER commit), and
  the future depends wiring can plain-`fetchurl` it like other sources.
- **LLVM/clang/lld pinned to GUIX's 19.1.4** (nixpkgs-26.05 ships
  19.1.7): `pkgsLlvm1914` in default.nix — an OVERLAY-based nixpkgs
  import (not a bare `llvmPackages_19.override`: LLVM_TABLEGEN comes
  from buildPackages via the splice machinery, which a local override
  doesn't reach — it would have run a 19.1.7 tblgen over 19.1.4 .td
  files; the overlay makes the splice self-consistent, tblgen = 19.1.4).
- **`clangDarwin` reunites the resource dir**: nixpkgs puts clang's
  builtin headers (stdarg.h…) in the separate `lib` output and reglues
  them via the cc-wrapper, which we deliberately DON'T use (GUIX uses
  bare clang; no wrapper = no injected-flag battles). clang realpaths
  its executable to find the resource dir, so symlinks don't work —
  `clangDarwin` is a copy-join of bin/ + complete lib/clang/19.
- **Smoke test passed**: C++/libc++ hello compiled + linked for BOTH
  darwin targets with exactly darwin.mk's flags → valid Mach-O 64-bit
  PIE executables (llvm-objdump verified). Linking needs NO darwin
  compiler-rt (GUIX's clang-runtime is linux-only as well).
- **Patch parity pre-verified**: GUIX clang-19 = pristine source (only
  driver search-path substitutions, neutralized by -nostdlibinc);
  nixpkgs' llvm/clang/lld 19 patches are install-dir/test/driver-path
  only — no codegen-relevant deltas.
- Upstream unsigned tarballs downloaded + hash-verified as diff
  references in `tmpdiff/upstream-darwin/`.

Next: depends for darwin (SDK fetchurl + SDK_PATH, darwin package set,
LIBRARY_PATH=$NATIVE_GCC/lib for native packages, /bitcoin/depends/
<triple> prefix-baking) starting with x86_64-apple-darwin; then bitcoind
(no CFLAGS env, cmake_install.cmake `-u -r` sed + --install --strip,
deploy target for the app zip, SOURCE_DATE_EPOCH=1776286524); then the
unsigned artifact assembly + gates; then signapple + detached-sigs for
the signed artifacts. Risk #1 is Qt 6.8.3-darwin cross in the Nix
sandbox (expect posix_shm-style feature-check divergences).

## Status (2026-06-12, night): darwin x86_64 ROUND 1 — within 8 bytes on 7/10 binaries; all three root causes identified, round 2 in flight

The full darwin pipeline now BUILDS end-to-end in the sandbox (depends
incl. Qt 6.8.3, all 10 Mach-O binaries, the deploy app zip), wired as
`dependsDarwin{X86,Arm64}` / `bitcoindDarwin{X86,Arm64}` (new
bitcoind-darwin.nix; manual cmake — the nixpkgs cmake hook would inject
-DCMAKE_C_COMPILER over the toolchain's multi-token clang) +
`tarballDarwin*` / `zipDarwin*` artifact drvs with upstream-hash gates.
Round 1 vs upstream (per-binary refs extracted from the published
-unsigned.tar.gz into tmpdiff/upstream-darwin/): 7 of 10 binaries
byte-identical EXCEPT the 8 bytes of LC_UUID; bitcoin-qt additionally
diverged in qt_prfxpath (+ its inlined strlen immediate — both already
fixed by the existing qt.mk -prefix sed which the interactive replay
lacked); bitcoin-node/bitcoin-gui/test_bitcoin additionally carried
+4.4 KB of kj FIBER code. Replay trick for darwin: `nix develop
.#dependsDarwinX86` + `make -C depends HOST=… SDK_PATH=… SOURCES_PATH=…`
in tmpdiff/darwin-replay iterates qt-configure-level problems in
minutes; bitcoind replays build straight against the replay depends.

Three root causes, each verified at the byte/check level:

- **CMake's PATH-prefix find probing poisons darwin try_compiles.**
  find_library derives search prefixes from every $PATH entry (strip
  /bin, probe <prefix>/lib) → finds the BUILD glibc's ELF librt.so →
  Qt's FindWrapRt link checks die in ld64.lld ("unhandled file type") →
  qt configure aborts ("Target Core links to WrapRt::WrapRt…"); zeromq's
  find_library(RT_LIBRARY rt) would leak -lrt into zmq.pc. Upstream's
  build succeeding proves GUIX's find is NOTFOUND (glibc 2.39 ships no
  unversioned librt.so; nixpkgs' 2.42 does). Fix: darwin-only
  `CMAKE_SYSTEM_IGNORE_PATH=<stdenv-glibc>/lib` via funcs.mk + qt.mk
  seds (depends.nix postPatch). NOT -DLIBRT=…-NOTFOUND (find_library
  re-runs on -NOTFOUND values) and NOT
  CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH=OFF (kills find_program's
  make/compiler lookup — tried, both rejected by test).
- **capnp/kj fibers: GUIX's LIBRARY_PATH export is load-bearing.**
  build.sh:80 exports LIBRARY_PATH=$NATIVE_GCC/lib for the darwin
  DEPENDS build (unset again after depends). GUIX's gcc-toolchain is a
  UNION incl. glibc (commencement.scm), so that dir holds glibc's ASCII
  libc.so linker script; clang forwards LIBRARY_PATH to the target link
  → ld64.lld errors on the script → capnp's
  check_library_exists(c makecontext) FAILS in GUIX's container →
  KJ_USE_FIBERS=0. Our env had no LIBRARY_PATH → -lc resolved to the
  SDK's libc.tbd → fibers ON → the 3 multiprocess-linking binaries
  gained fiber code + getcontext/setcontext/makecontext/mprotect/
  setjmp imports upstream lacks. Fix: depends.nix darwin env mirrors it.
  Verified: the check flips fail/pass with the env var alone, exact
  ld64.lld error reproduced. **But NOT the raw gcc+glibc lib dirs**
  (round-2 lesson): nixpkgs' glibc 2.42 installs unversioned COMPAT
  SYMLINKS for the 2.34-merged libs (libpthread.so→libpthread.so.0,
  librt/libdl/libutil/libanl.so) that vanilla glibc — GUIX's — never
  ships; with those on LIBRARY_PATH, capnp's tool links (-lpthread via
  CMake Threads) hand ld64.lld the ELF stub and die ("unhandled file
  type"), while GUIX's -lpthread falls through to the SDK tbd. Fix:
  `darwinLibraryPathDir` in depends.nix — a runCommand union of gcc's
  lib + glibc's lib MINUS exactly those five compat links (one dir,
  like GUIX's $NATIVE_GCC/lib). Both directions re-verified by direct
  clang/ld64.lld link tests: -lpthread links, -lc still errors.
- **LC_UUID fossilizes the pre-strip build paths.** lld computes the
  UUID as xxhash(unstripped output + output basename) BEFORE the
  install-time `cmake --install --strip`; the unstripped image carries
  the linker's debug-map stabs — N_SO (absolute source paths) + N_OSO
  (absolute object/archive paths) for bitcoin's OWN TUs (depends
  archives contribute none — verified; only the qt_prfxpath .rodata
  string carries a depends path and the -prefix sed pins it) — which
  strip removes. Byte-equal UUID therefore requires byte-equal
  UNSTRIPPED images = GUIX's literal paths. The sandbox root is
  read-only (mkdir /distsrc-base → EPERM), but USER NAMESPACES WORK
  inside the Nix sandbox: bitcoind-darwin.nix builds inside an
  `unshare --user --map-root-user --mount` chroot with a bind-mounted
  new root — source tree at /distsrc-base/distsrc-31.0-<host>, depends
  symlinked at /bitcoin/depends/<host>, --toolchain spelled through it
  (toolchain.cmake is fully CMAKE_CURRENT_LIST_DIR-relative, so every
  depends path then matches GUIX's BASEPREFIX spellings).

Round 2 (all three fixes) is building. Ops note: an auto-GC collected
the 19.1.4 toolchain mid-session (built with --no-link, no root) — keep
out-links (e.g. result-llvm-tools) for the darwin toolchain pieces.

## Status (2026-06-12, later): armhf + ppc64 .dbg loclists residue SOLVED — all 7 .dbg byte-identical, CRC patches GONE again, debug tarballs wired

The "loclists residue" (next section) is fixed: all 20 armhf and all 20
ppc64 artifacts byte-match upstream, `nix build .#debugTarballArmhf`
(`fc17562b…`) and `.#debugTarballPpc64` (`efe3e7d0…`) assemble both
`-debug.tar.gz` byte-identically, the `debuglinkCrcs` byte-patch
mechanism is REMOVED from bitcoind-cross.nix (zero byte patches anywhere,
again), and CI asserts both debug archives. Five of the v31.0 Linux
release families now reproduce completely — binaries, release archive
AND debug archive (outstanding: macOS x2, win64).

**Root cause (found by replay bisection, ~3 min/iteration)**: gcc's
`remap_filename` (file-prefix-map.cc) **ggc-allocates every rewrite a
`-ffile-prefix-map` actually performs**, and our depends map
(`store-path=/bitcoin/depends/<triple>`) fires on every depends header —
while GUIX's environment fires NO map there (their depends lives at the
real `/bitcoin`, which their per-store-item `/gnu/store/*→/usr` maps
never match; build.sh:212). Those few hundred extra GGC allocations
shift the arena and flip var-tracking's representative choice among
equivalent location expressions in the biggest CUs — armhf: variable
`it` in net_processing.cpp (split `r6-56`/`r5-16` vs upstream's single
`r5-16`, the SAME flip in the 5 binaries containing that CU); ppc64: a
qt CU. The toolchain-header `/usr` maps are innocent: GUIX fires those
too, with byte-equal remapped results (= equal allocation sizes).

Decisive experiments (unshare-chroot single-CU replays of the armhf
net_processing.cpp compile, `tmpdiff/replay2/`):
- source tree at GUIX's literal `/distsrc-base/distsrc-31.0-…` (B1) and
  at a same-shape path (B3a): **byte-identical .o to the sandbox build**
  — raw path length/shape/content of the source tree is completely
  inert (kills the env-mirroring/path-length hypothesis).
- depends at `/bitcoin/depends/<triple>` with the map dropped (B2):
  upstream's exact loclists; offset-normalized diff vs baseline = ONLY
  the two `it` lists (−20 bytes), every other section byte-equal.
- an **IDENTITY map** (`/bitcoin/…=/bitcoin/…`, rewriting every depends
  header to itself) restores the split byte-for-byte (H2), while an
  extra map matching NOTHING changes nothing (H1) → the map's
  *application* is the entire poison; argv content irrelevant.

**Fix**: route the depends rewrite through the canon mechanism —
`patches/gcc-debug-canon-prefix-map.patch` v5 accepts multiple
colon-separated pairs in `NIX_DEBUG_CANON_PREFIX_MAP` (canon rewrites
are malloc'd = GGC-neutral, the v4 lesson), new `canonDepends` knob in
mkLinuxCrossTarget/bitcoind-cross.nix drops the depends `-ffile-prefix-
map` from argv and adds the pair to the env var. **v6 (the second
lesson)**: `-ffile-prefix-map` is debug AND MACRO map — v5 alone broke
6 armhf RUNTIME binaries because the un-remapped depends `__FILE__`
paths hit nixpkgs' mangle-NIX_STORE-in-__FILE__.patch (uppercased store
hashes in `.rodata`, 9 boost strings, +256 B). v6 hooks the canon into
`remap_macro_filename` too, ordered maps-on-raw-first (cmake's
build-local `-fmacro-prefix-map=$src=.` must keep winning, firing
equivalently to GUIX's own map), then canon (malloc, no mangling), then
nixpkgs' mangle fallback. The v6 file-prefix-map.cc hunk is generated
against the POST-mangle source (nixpkgs' mangle patch rewrites the same
function; modify-hunks against pristine gcc don't apply). armhf: canon
patch + `canonDepends` + `debugCanonMap` (the full ppc64 wiring — third
root cause below); ppc64: `canonDepends` added as a second pair after
its existing `/build→DISTSRC` pair. riscv64/x86_64/aarch64 untouched
(their .dbg already matched WITH the poison — their big CUs sit below
the flip threshold; do NOT "clean up" their depends maps onto canon,
that would risk re-flipping). Dress-rehearsal replays with the
canon-patched gcc: env unset ⇒ byte-identical to the old compiler
(strict no-op, both directions per the playbook); env set + map
dropped ⇒ byte-identical to the B2/upstream form. Side-finding:
nixpkgs' cfi_startproc-reorder-label-14-1.diff patches only
libgcc/config/aarch64/lse.S — never an armhf suspect.

**Third root cause (uncovered when the loclists fix landed)**: the
armhf node/gui/test_bitcoin/qt `.dbg` divergences were NEVER
loclists-only — the build-dir GENERATED CUs (mpgen capnp, qt moc) had
carried the ppc64 dup-main-file divergence all along, mislabeled under
the "+20 loclists" finding (which had only been byte-verified on
bitcoind.dbg, the one diverger with NO generated CUs, and extrapolated
to the other four). Our `/build=$DISTSRC` argv map matches the
generated CUs' main files → duplicate file-table entry (visible on the
v5 side as a doubled line-table file entry, +1-shifted
`DW_AT_decl_file` implicit_consts in .debug_abbrev, and
`DW_OP_implicit_pointer` DIE offsets ±1) — upstream, building at the
real $DISTSRC, never remaps them. Fix: `debugCanonMap = true` on armhf
too (replay c3: the capnp CU's dup gone, file table upstream-exact,
.text/.rodata untouched; netproc/wallet byte-equal to the c1 forms —
the canon respelling is transparent for src/ CUs). The earlier claim
that armhf's v5 line tables "show the doubled entry on BOTH sides"
holds only for src/ CUs (each side's own map matches those); for
generated CUs it was wrong. Lesson: when a divergence class is found
in ONE artifact, verify it per-artifact before concluding it explains
the whole failing set.

## Status (2026-06-12): armhf + powerpc64 RELEASE tarballs reproduce — .dbg loclists residue documented (SOLVED — see above)

The 4th and 5th targets. `nix build .#tarballArmhf` (`8c19d007…`) and
`.#tarballPpc64` (`1d9c865a…`) byte-match the upstream release archives;
all 10 runtime binaries of each release byte-match (gated). The
`-debug.tar.gz` of these two targets is NOT byte-reproducible yet:
armhf has 5 diverging `.dbg` (bitcoind, bitcoin-qt, bitcoin-gui,
bitcoin-node, test_bitcoin), ppc64 has 2 (bitcoin-qt, bitcoin-gui) —
each differing from upstream's ONLY in `.debug_loclists` (+14…+36 bytes,
ONE list per file). Those binaries' `.gnu_debuglink` CRCs are
byte-patched to upstream's values (the CRC-patch mechanism returns,
gated to exactly these 7 binaries via `debuglinkCrcs` in
bitcoind-cross.nix); the 13 byte-identical `.dbg` of the two targets ARE
asserted. Pipeline: mkLinuxCrossTarget (default.nix) — the
riscv64/aarch64 recipe generalized — + bitcoind-cross.nix (riscv64 also
migrated onto both; its 22 artifacts still gate green).

Three root causes were found and fixed on the way (each verified at the
object/byte level before rebuilds):

- **armhf: awk hash-iteration order in gcc's own build.**
  gcc/config/arm/parsecpu.awk generates the arm ISA tables
  (all_implied_fbits etc.) with `for (x in array)` — unordered. nixpkgs'
  gawk 5.4.0 orders it differently than GUIX's 5.3.0, and the table is
  baked through the arm tm.h headers into crtstuff.c → crtbegin/crtend →
  EVERY binary's .rodata (the whole-release divergence, 72 B in
  bitcoin-cli). Fix: `gawk530` pinned into the armhf gcc build
  (gccNativeInputs; needs ac_cv_prog_cc_c23=no + -std=gnu17 — autoconf
  2.72/gcc 15 default to C23 which gawk 5.3.0 doesn't compile as).
- **ppc64: duplicate DWARF file-table entries under prefix maps.**
  gcc keys its file table on the path AS PASSED IN but emits the
  REMAPPED name: a main file whose path matches a -fdebug-prefix-map
  enters the table under two spellings (the second via the synthesized
  static-init function's end-of-parsing location) → duplicate `.file`
  → +1 entry in the gas-built DWARF-v3 line tables (ppc64 is the only
  target whose C++ line tables come out as v3; the v5 targets show the
  doubled entry on BOTH sides). Upstream HAS the duplicates for src/
  CUs (their own $DISTSRC/src=. map) but NOT for cmake-build-dir
  (mpgen-generated) CUs — they build at the REAL /distsrc-base path and
  never remap those, while our /build tree map did. Unconditional
  dedup therefore REGRESSES matching CUs (tried, reverted). Fix:
  patches/gcc-debug-canon-prefix-map.patch — a TRANSPARENT canonical
  rewrite (env NIX_DEBUG_CANON_PREFIX_MAP=/build/bitcoin-31.0=$DISTSRC,
  applied before the maps AND to the file-table keys) makes the compile
  behave byte-for-byte as if it ran at GUIX's real path, and
  bitcoind-cross.nix (debugCanonMap) then uses GUIX's literal map set
  (-fdebug-prefix-map=$DISTSRC/src=.). ppc64-only.
- **gcc's .debug_loclists are GGC-allocation-order sensitive** (the
  big lesson, and the cause of the remaining residue). Var-tracking
  picks ONE representative among equivalent location expressions (e.g.
  `r6-56` vs `r5-16`, same value), and the choice flips with GGC arena
  layout: the first canon patch allocated its rewritten strings with
  ggc_alloc_atomic and that ALONE flipped loclists entries in
  previously-byte-identical CUs; reallocating with plain malloc
  (XNEWVEC) un-flipped them all. The 7 still-diverging .dbg are single
  flips of this kind in each target's biggest CUs (armhf: variable `it`
  in net_processing.cpp — shared by exactly the 5 failing binaries;
  ppc64: inlined QScopedPointerDeleter<QDataStreamPrivate> in a qt/*.cpp
  CU), stable across our builds, with identical producers and identical
  .text — caused by some residual allocation-stream difference vs
  GUIX's compile environment (path string lengths/content in early
  allocations are the chief suspects; ggc params are equal — both
  machines cap at ggc-min-expand=100/heapsize=128M). Follow-up options:
  length/shape-matched build paths, or a determinism fix in
  var-tracking/cselib itself (upstreamable).

Methodology additions for the playbook: per-table walks of
.debug_line/.debug_loclists headers localize a divergence to ONE CU
cheaply; `nix develop` + a binary-patched mpgen (equal-length store
path baked over /build) replays single-CU compiles outside the sandbox
in seconds; validating a gcc patch needs BOTH directions — the
trigger case fixed AND a non-trigger compile byte-identical against the
unpatched compiler (with the SAME wrapper flavor — NoFp vs regular
wrappers differ by injected flags).

## Status (2026-06-11, evening): riscv64 release reproduced — ROUND 1, all 22 artifacts

The third target. `nix build .#bitcoindRiscv64` byte-matches all 10
binaries AND all 10 `.dbg` of the upstream
`bitcoin-31.0-riscv64-linux-gnu` release on the FIRST build, and
`.#tarballRiscv64` / `.#debugTarballRiscv64` assemble both archives
byte-identically (`7ece4ea3…` / `acd0e38f…`). A 20-hash gate in
`bitcoind-riscv64.nix` + the two tarball gates assert this every build;
CI got a `build-riscv64` job (analog of `build-aarch64`). 66 artifacts
across three targets now reproduce.

The riscv64 pipeline is a 1:1 mirror of the aarch64 one (trio
`crossBinutils241Riscv64`/`crossGlibc231Riscv64`/`crossGuixGccRiscv64` +
NoFp wrappers in default.nix; `bitcoind-riscv64.nix`). That round 1
matched validates the recipe — every divergence class found on
x86_64/aarch64 was pre-checked against the upstream riscv64 `.dbg`
before building. The riscv64-only deltas:

- **No `--with-arch` issue (the aarch64 trap inverted)**: every upstream
  CU's producer records driver-injected `-mabi=lp64d -misa-spec=20191213
  -mtls-dialect=trad -march=rv64imafdc_zicsr_zifencei` — but these come
  from gcc's OWN config.gcc defaults for riscv64-linux (rv64gc/lp64d
  canonicalized), and nixpkgs passes NO --with-arch/--with-abi for riscv
  (riscv-multiplatform defines no gcc.arch — checked in nixpkgs source),
  so nixpkgs' and GUIX's gcc inject identical strings with zero
  intervention. Also no cc-wrapper -march injection (same reason).
- **glibc needs GUIX's `glibc-riscv-jumptarget.patch`** (riscv sysdeps
  asm HIDDEN_JUMPTARGET fixes; part of GUIX's glibc-2.31 origin patches;
  copied into `patches/`). The other GUIX glibc patch
  (glibc-guix-prefix) remains unapplied on all targets (never affected
  shipped members).
- **Frame pointers**: riscv -O2 omits the FP with NO leaf/non-leaf split
  (`-momit-leaf-frame-pointer` is not a riscv option) → depends gets
  plain `-fomit-frame-pointer` (new three-way arch conditional in
  depends.nix), and the NoFp wrappers strip only
  `-fno-omit-frame-pointer` (the cc-wrapper injects no leaf variant for
  riscv+gcc14 — that arm of the wrapper is gcc>=15.1-gated).
- **No CET (x86-only) / no standard-branch-protection (aarch64-only)**
  in any riscv gcc configure; interpreter is
  `/lib/ld-linux-riscv64-lp64d.so.1`; GUIX drv-0/DISTSRC paths follow
  the exact aarch64 pattern with the riscv64 triple (verified in
  upstream comp_dirs before building).
- depends' Qt posix-ipc preseed gate widened to riscv64 (same
  sandbox-vs-container divergence); hosts/linux.mk needs nothing (its
  special case is x86-host-only).

Method note: this is what "pre-verify before building" buys — the
upstream reference (tarball hashes from SHA256SUMS, producers/comp_dirs
from the `.dbg` via arch-agnostic GNU readelf, wrapper/gcc flag
behavior from nixpkgs+GUIX sources) was fully diffed against the plan
BEFORE the multi-hour cold build, and the build then passed first try.

## Status (2026-06-11): arm CI first run — x86_64-from-aarch64 PROVEN; aarch64-on-aarch64 POSTPONED

The two `ubuntu-24.04-arm` CI jobs (the outstanding "cross everywhere"
byte-proof) ran for the first time:

- **`build-x86-target-on-aarch64-host` PASSED**: the x86_64 release
  cross-compiled FROM an aarch64 host gates the same upstream hashes
  (`d3e4c58a…` tarball). The cross-everywhere bet — same toolchain
  config + target ⇒ same bytes, regardless of build host — is now
  byte-proven in both directions for the x86_64 target.
- **`build-on-aarch64-host` (aarch64-on-aarch64 trivial cross) FAILS
  structurally and is POSTPONED.** Root cause: config.sub canonicalizes
  the vendor-less target `aarch64-linux-gnu` → `aarch64-unknown-linux-gnu`
  (aarch64's default vendor is "unknown"; x86_64's is "pc", which is why
  the x86_64 cross-to-self never hit this) — which EQUALS the build
  triple on an aarch64 host. nixpkgs still treats it as cross (the
  config strings differ), but gcc's own build system sees build ==
  target → NATIVE build → fixincludes runs against
  BUILD_SYSTEM_HEADER_DIR=/usr/include, absent in the Nix sandbox →
  `stmp-fixinc` fails in the BOOTSTRAP `aarch64-linux-gnu-nolibc-gcc`
  (nixpkgs' cross-stage-static gcc 15.2.0, built long before our pinned
  toolchain). A fix means overriding that bootstrap gcc (e.g.
  `--disable-fixincludes`) gated to aarch64 build hosts — bootstrap
  override plumbing with every test iteration a multi-hour cold arm CI
  run, since this machine has no aarch64 builder or qemu binfmt.
  **Decision: tackle it in the future ON an aarch64 runner/machine for
  fast iteration.** Until then the CI job is `continue-on-error: true`
  (kept visible as a reminder, non-blocking).

## Status (2026-06-11, later): aarch64 .dbg ALSO byte-identical — NO byte patches left ANYWHERE

The x86_64 `.dbg` recipe (next section) was mirrored onto the aarch64
cross toolchain the same day, and after three build rounds all ten
aarch64 `.dbg` files byte-match upstream's; the aarch64 `.gnu_debuglink`
CRC patch — the last byte patch in the whole project — is removed, and
`nix build .#debugTarballAarch64` assembles
`bitcoin-31.0-aarch64-linux-gnu-debug.tar.gz` byte-identical to upstream
(`91917647…`). bitcoind-aarch64.nix's gate now asserts all 20 aarch64
artifacts. Every published artifact of BOTH releases (44 files: 2×10
binaries, 2×10 .dbg, 4 tarballs) now reproduces exactly.

The mirror was 1:1 (binutils compressed-debug-sections + bundled zlib,
kernel headers 6.1.119, NoFp wrappers, glibc --disable-static-pie +
default-PIE forced CC + pic-hardening-off + unsplit static libs + drv-0
debug-prefix-map, libgcc -g multiplicity + GUIX maps, /usr header maps,
DISTSRC=/distsrc-base/distsrc-31.0-aarch64-linux-gnu, RelWithDebInfo,
frandom-seed strip, Qt posix ipc preseeds aarch64-gated in depends.nix)
with three aarch64-only deltas:

- **glibc's forced CC bakes `--enable-standard-branch-protection=yes`**
  (verified in manifest.scm: GUIX's linux-base-gcc — the
  base-gcc-for-libc — has it), replacing the previously EXPLICIT
  `-mbranch-protection=standard` which was recorded in DW_AT_producer.
  Same PAC/BTI codegen, clean producer. Frame pointers likewise: the
  explicit `-momit-leaf-frame-pointer` died with the NoFp wrappers (the
  aarch64 -O2 default = keep non-leaf, omit leaf = upstream).
- **`--with-arch=armv8-a` FILTERED OUT of both gcc configures** (the
  decisive aarch64-only find, round 3): nixpkgs configures the cross gcc
  with it, and a configured --with-arch makes the gcc DRIVER self-inject
  `-march=armv8-a` into every cc1 line via OPTION_DEFAULT_SPECS —
  recorded in EVERY CU's DW_AT_producer (glibc, libgcc, bitcoind alike).
  Upstream's GUIX gcc has no --with-arch. Stripping the wrapper's
  cc-cflags-before `-march` injection (round 2) was necessary but not
  sufficient — the producer-string position shift (-march moving after
  -mbranch-protection) was the tell that a second injection source
  existed. armv8-a is the aarch64 baseline default → codegen identical.
- **kernel-headers map for libgcc's unwind-dw2.c** (`-ffile-prefix-map=
  ${linuxHeaders61Aarch64}/include=/usr/include` in crossGuixGcc's
  GUIXMAPS): its <asm/…>/<asm-generic/…> includes resolve through
  glibc-dev's include SYMLINKS, which gcc canonicalizes to the
  linux-headers store path — escaping the glibc-dev map that sufficed on
  x86 (unwind-dw2-fde-dip.c there only needed <elf.h>, a real file).

Methodology note: round 1 (the plain mirror) already got within ~5 KB /
102 MB on bitcoind.dbg; the residue was localized by per-section size
diff → .debug_line_str string diff (the unmapped kernel-header dirs in
ONE line table at 0x136ce5b → DW_AT_stmt_list lookup → unwind-dw2.c) +
unique-producer-set diff (the -march flag). After round 2, decompressed
sections were size-identical except .debug_str at exactly +150 bytes =
10 producer variants × " -march=armv8-a" — pointing straight at the
configured --with-arch.

## Status (2026-06-11): .dbg BYTE-IDENTICAL — CRC patch GONE, -debug.tar.gz reproduces

All ten `.dbg` debug files are now byte-identical to upstream's, so the
LAST byte-patch (the `.gnu_debuglink` CRC32 overwrite) is removed —
`objcopy --add-gnu-debuglink` computes upstream's CRC naturally — and
`nix build .#debugTarball` assembles `bitcoin-31.0-x86_64-linux-gnu-
debug.tar.gz` byte-identical to upstream (`96e35061…`). bitcoind.nix's
gate now asserts ALL 20 artifacts (10 binaries + 10 .dbg) every build.
EVERY published artifact of the x86_64 release now reproduces exactly.

What it took (each fix verified by re-diffing bitcoind.dbg vs upstream;
the old "Task #2 finding" was largely obsolete — its #2 came free with
cross-to-self, its #3 needed only three header maps, and several real
divergences weren't in that list at all):

- **bitcoind.nix flags**: comp_dir map to GUIX's real
  `/distsrc-base/distsrc-31.0-x86_64-linux-gnu` (DISTSRC; NOT /bitcoin —
  only depends lives there), `-fdebug-prefix-map=…/src=.` like build.sh,
  `cmakeBuildType=RelWithDebInfo` (bitcoin's default; nixpkgs' hook forced
  Release — visible as `-g -g -O2 -O2 -O2` vs `-g -O2 -O2` in
  DW_AT_producer), NO explicit frame-pointer flags (a NoFp cc-wrapper
  variant stops nixpkgs' -fno-omit-frame-pointer injection; every explicit
  flag is recorded in DW_AT_producer and upstream compiles bare `-O2 -g`),
  drop nixpkgs' `-frandom-seed=<outhash>` (reproducible-builds hook),
  store→/usr header maps (gcc c++ headers map VERSION-LESS to
  /usr/include/c++ — GUIX's --with-gxx-include-dir layout; sys-include →
  /usr/include; lib/gcc → /usr/lib/gcc; linux-headers → /usr/include).
- **kernel headers pinned to GUIX's 6.1.119** (`linuxHeaders61`): header
  VERSION leaks into DWARF — 6.18 has rtnetlink enumerators (RTM_NEW
  MULTICAST, RTA_FLOWLABEL, …) 6.1 lacks. Used for glibc --with-headers →
  gcc sys-include → bitcoind compiles.
- **glibc 2.31 with debug info**: `separateDebugInfo=false` (its hook
  added `-ggdb` — recorded; its fixup stripped the members) + dontStrip;
  `-fdebug-prefix-map=/build/glibc-2.31=/tmp/guix-build-glibc-cross-
  x86_64-linux-gnu-2.31.drv-0/source` (glibc compiles with CWD in source
  subdirs, so ONE map covers all comp_dirs); `--disable-static-pie`
  (nixpkgs passes --enable-static-pie → glibc adds a recorded `-fpie` to
  csu objects; upstream has none) with the forced CC rebuilt
  `--enable-default-pie` (same PIE codegen, no flag — GUIX's
  linux-base-gcc builds their glibc, see manifest.scm base-gcc-for-libc)
  + `--with-as/--with-ld` = cross binutils 2.41 (gas GENERATES
  .debug_line; 2.46's encoding diverges); hardeningDisable += "pic" (the
  wrapper's default -fPIC injection broke glibc's pie-default detection →
  non-PIE crt selection vs default-PIE driver → iconvconfig link failure,
  and would be recorded where glibc passes no own pic/pie flag); static
  libs kept in $out/lib next to the shared ones like GUIX (no $static
  split — `-static` links must find -lc/-lm, e.g. Qt's feature checks).
- **gcc target libs with debug info**: dontStrip + `-g` in
  CFLAGS_FOR_TARGET only (libgcc CUs; producer `-g -g -g -O2 -O2 -O2`
  reproduced exactly: the compile line is FLAGS_FOR_TARGET +
  CFLAGS_FOR_TARGET + [literal -O2 + GCC_CFLAGS(=CFLAGS_FOR_TARGET) +
  LIBGCC2_DEBUG_CFLAGS(-g)], so -g lands 3× and FLAGS_FOR_TARGET gets
  EXTRA's -O2 stripped → 3×); `-fdebug-prefix-map=/build/build=/tmp/
  guix-build-gcc-cross-x86_64-linux-gnu-14.3.0.drv-0/build` (same source
  shape, one map covers comp_dir + relative names); glibc-dev →
  /usr/include map for unwind-dw2-fde-dip's <elf.h>; libstdc++/libsupc++
  archives strip-debug'd in postFixup (upstream has no CUs from them —
  libsupc++'s C members would otherwise leak cp-demangle.c).
- **compressed debug sections**: crossBinutils241X86 configured
  `--enable-compressed-debug-sections=all` like GUIX (that's why
  split-debug.sh needs no explicit flag) and WITHOUT nixpkgs'
  `--with-system-zlib` (GUIX uses binutils' bundled zlib; same 2.41
  tarball ⇒ identical deflate bytes).
- **Qt posix ipc features preseeded** (depends.nix qt.mk sed:
  HAVE_GETTIME, HAVE_SHM_OPEN_SHM_UNLINK, TEST_posix_shm,
  TEST_posix_sem): in the sandbox Qt's configure-time link checks fail
  where GUIX's container passes them, leaving QT_FEATURE_posix_shm/
  posix_sem OFF; upstream compiles qsharedmemory_posix.cpp /
  qsystemsemaphore_posix.cpp to feature-gated EMPTY objects whose two
  STT_FILE symtab entries were the final 96 bytes of
  bitcoin-qt.dbg/bitcoin-gui.dbg.

(The aarch64 `.dbg` were byte-matched with the same recipe later the
same day — see the status section above.)

## Status (2026-06-10): "cross everywhere" — generalized over build hosts

default.nix now derives `localSystem` for both cross package sets from the
incoming `pkgs` (`buildSystem = pkgs.stdenv.hostPlatform.system`), and
flake.nix exposes the same pipeline per build host
(`packages.{x86_64-linux,aarch64-linux}.*`, attr names = TARGET). On an
aarch64 host, `.#bitcoindAarch64` becomes a cross-to-self (the trivial
cross) and `.#bitcoind` a real aarch64→x86_64 cross — with ZERO definition
changes; the target triples and toolchain configs are host-independent.
x86_64-hosted drvs verified byte-identical to before the change (pure
refactor for the existing host); aarch64-hosted drvs evaluate. Actual
byte-verification on an aarch64 host runs in CI: two new
`ubuntu-24.04-arm` jobs build `.#tarballAarch64` (aarch64-on-aarch64) and
`.#tarball` (x86_64-from-aarch64), each gating the same upstream hashes —
green arm jobs prove build-host-independence (this machine has no qemu
binfmt, so CI is where the proof runs; expect the first arm runs to be
long cold builds with no Cachix overlap with the x86-hosted paths).

## Status (2026-06-10): x86_64 cross-to-self IS the canonical path — native removed

The cross-to-self build replaced the native one: `.#bitcoind` /
`.#depends` / `.#tarball` now ARE the cross builds (same attr names, so CI
needed no changes; `bitcoind-x86-cross.nix` became `bitcoind.nix`,
replacing the native original). Removed: the whole native toolchain chain
in default.nix (`binutilsForGuix` → `bintoolsWithGlibc231` →
`stdenvForGccRebuild` → `gcc14RebuiltWithGlibc231` →
`gcc14Glibc231Stdenv`) and flake.nix's native `glibc231` override — see
git history (pre-2026-06-10) for those. Two native-only workarounds died
with them (cross gcc bakes `--with-as`, so no PATH `as`-shadow or
depsBuildTarget juggling). The aarch64 derivations were verified
drv-identical throughout; the renamed x86 ones re-assert the same hashes.

### How the cross-to-self build got proven (earlier 2026-06-10)

`nix build .#bitcoindX86Cross` (now `.#bitcoind`) built the full x86_64
release **through the cross-to-self toolchain** and all 10 binaries
byte-matched the same upstream hashes as the native path (`dae69848…`
etc.; gate asserted), and `.#tarballX86Cross` (now `.#tarball`) assembled
the release archive byte-identical to upstream (`d3e4c58a…`). This proved
the cross-everywhere bet on x86_64: same compiler config + target ⇒ same
bytes, native stdenv vs cross-to-self.

Wiring (was additive at the time; the X86Cross attrs are now the canonical
`depends`/`bitcoind`/`tarball`):
- `dependsX86Cross` — depends.nix with `crossInputs = x86CrossInputs`
  (hostTriple already defaulted to x86_64-linux-gnu). **One new
  cross-to-self-only gotcha**: `depends/hosts/linux.mk` special-cases an
  x86 build machine (`ifeq (86,$(findstring 86,$(build_arch)))`) and
  forces ALL x86_64 host tools native+unprefixed (`CC=gcc -m64`, `AR=ar`,
  `RANLIB=ranlib`, …) — in GUIX's container that native gcc IS the pinned
  toolchain, but here it's the 2.42-glibc stdenv, so host packages picked
  up glibc-2.38+ symbols (`__isoc23_strtoul` in capnp's libkj → mptest
  link failure). Fixed by a cross-only `postPatch` (via `optionalAttrs`,
  so the other depends drvs don't change) that disables the conditional —
  the `else` branch then gives `CC=$(default_host_CC) -m64` =
  `x86_64-linux-gnu-gcc -m64` + prefixed binutils, exactly what depends
  does for this host on any non-x86 build machine. aarch64 never hit this
  (the special-case is x86-host-only).
- `bitcoind-x86-cross.nix` — bitcoind.nix's x86 values (frame pointers,
  interpreter, CRCs, hashes) in bitcoind-aarch64.nix's cross structure
  (CC=x86_64-linux-gnu-gcc export, prefixed cross binutils 2.41 for
  split-debug). Intended to eventually replace bitcoind.nix.

Step 1 (the toolchain itself) below; next: the `.dbg` divergence work
(`-gz`, header prefix-maps, `-fdebug-prefix-map`) which this cross build
unblocks, then unify/replace the native path and generalize over build
hosts ("cross everywhere").

### Step 1 (2026-06-10): the x86_64 cross-to-self toolchain

First step of the cross-everywhere / `.dbg`-fix plan: build the GUIX-style
**`x86_64-linux-gnu` cross-to-self toolchain** (GUIX builds the x86_64
release as a cross build to that vendor-less triple even on x86_64 hosts).
`default.nix` now has `pkgsCrossX86` (`localSystem = x86_64-linux`,
`crossSystem.config = x86_64-linux-gnu` — nixpkgs treats the differing
config string as a real cross build) and the cross trio mirroring the
aarch64 one: `crossBinutils241X86`, `crossGlibc231X86`, `crossGuixGccX86`
(exposed as `.#crossGuixGccX86` / `.#crossGlibc231X86`). x86 deltas vs the
aarch64 trio:

- glibc: `--enable-cet` (x86-only), `-fomit-frame-pointer
  -momit-leaf-frame-pointer` (omit BOTH; aarch64 keeps non-leaf), no
  `-mbranch-protection`.
- gcc: `--enable-cet=yes`; **`--with-as`/`--with-ld` re-pointed at cross
  binutils 2.41** (nixpkgs bakes a 2.46 `--with-as` into cross gcc; a
  second `--with-as` appended later wins. 2.46 gas would hit the
  NOP-fill-order divergence the native build PATH-shadows around; aarch64
  never had this — fixed-width instructions); and the same
  `-Wa,-mrelax-relocations=no` target-lib preBuild as the native rebuild
  (GOTPCRELX is x86-only).

**Verified** (build succeeded, `nix build .#crossGuixGccX86`):
`-dumpmachine` = `x86_64-linux-gnu`, gcc 14.3.0, `-print-prog-name=as/ld`
→ binutils 2.41, all GUIX configure flags present; test binary is PIE,
needs ≤ GLIBC_2.4, `.comment` = gcc 14.3.0; libstdc++.a has **0**
`R_X86_64_GOTPCRELX` (4952 plain GOTPCREL), no `gettext` undef; cross
glibc CRTs carry IBT/SHSTK notes natively, `atexit.oS` has the gcc-14
`sub` canary + no FP prologue + no register-zeroing. **Decisive check:
all 16 `libc_nonshared.a` members (incl. `elf-init.oS` /
`__libc_csu_init`) and all 4 CRTs are byte-identical to the proven
native glibc231's.**

Next: wire depends/bitcoind through `crossGuixGccX86` (mirror
`bitcoind-aarch64.nix` / `dependsAarch64` plumbing for
`hostTriple = x86_64-linux-gnu`), assert the same 10 hashes, then the
`.dbg` work (`-gz`, header prefix-maps, `-fdebug-prefix-map` for the
GUIX `.drv-0` dirs — see Task #2 finding).

## Status (2026-06-06): migrated to nixos-26.05 — all 21 artifacts reproduce

The flake is pinned to `nixos-26.05` (was `nixos-25.11`, now deprecated).
All 10 x86_64 binaries + the `.tar.gz` (`dae69848…` / `d3e4c58a…`) AND all 10
aarch64 binaries + its `.tar.gz` (`4de1d568…`) still byte-match upstream; both
`postFixup` gates pass. The fixes are summarized below; the aarch64 specifics
are at the end of this status block.

26.05's default toolchain is gcc 15.2.0 + binutils 2.46 (25.11 was gcc 14 +
binutils 2.44). Only `gcc14` stays 14.3.0. Three regressions had to be
fixed, all in code that ends up statically linked into the binaries:

1. **GOT relax-relocations** — 26.05's gcc14 assembles libstdc++ with
   relaxable `R_X86_64_GOTPCRELX`; the link then relaxes 2 `_S_timezones`
   GOT accesses, rippling `.text`/`.eh_frame`. Fixed by re-appending
   `-Wa,-mrelax-relocations=no` to `CXXFLAGS_FOR_TARGET` in
   `gcc14RebuiltWithGlibc231`'s `preBuild` (default.nix).
2. **gas NOP-fill order** — binutils 2.46 pads alignment gaps short-first;
   2.41 (GUIX) pads long-first (diverged `btree_release_tree_recursively`
   at 0x181633). `depsBuildTarget` alone didn't fix it — native gcc has no
   `--with-as`, so xgcc resolves `as` from PATH at build time, and a 2.46
   `as` leaks in via `depsBuildBuild` (the gcc-wrapper-15.2.0 build
   compiler). Fixed by `preConfigure` shadowing `as` with binutils 2.41 at
   the front of PATH for the whole gcc build (default.nix).
3. **glibc `__libc_csu_init`** — the function that walks `__init_array`
   (csu, ~0xba4060). gcc15 emits r12/rbp register allocation; **gcc14 emits
   r15/r14 == upstream** (verified by compiling `csu/elf-init.c` with both).
   glibc is a stdenv *bootstrap* component, so `glibc.override { stdenv }`
   is silently ignored — it's always built by the bootstrap compiler (gcc14
   on 25.11, gcc15 on 26.05, which is exactly why 25.11 matched). Fixed by
   forcing `CC=${pkgs.gcc14}/bin/gcc` (CC only — forcing CXX breaks glibc's
   cstdlib/cmath generation; shipped glibc is all C) via `preConfigure`
   export + `makeFlags` in flake.nix's glibc231.

**aarch64 on 26.05 also fully reproduces** (all 10 + tarball `4de1d568…`).
Two cross-specific fixes, both from the same 26.05 splicing change where
`pkgsCrossAarch64.gcc14.cc` resolves to the aarch64-**native** gcc (an ARM
binary) instead of the build→target cross gcc:

- **`crossGlibc231`** (default.nix): same bootstrap-glibc issue as x86 — the
  cross glibc was built by the bootstrap cross gcc15. Force
  `CC=${pkgsCrossAarch64.buildPackages.gcc14}/bin/aarch64-linux-gnu-gcc`
  (the build→target cross gcc14) via `preConfigure` + `makeFlags`.
- **`crossGuixGcc`** (default.nix): was wrapping `pkgsCrossAarch64.gcc14.cc`,
  which on 26.05 is the aarch64-native gcc. The cc-wrapper setup-hook then
  put that native gcc's bin (with UNPREFIXED `gcc`/`g++`) on the depends
  build PATH, shadowing the native compiler and breaking `native_qt`'s CMake
  compiler check. Switched to `pkgsCrossAarch64.buildPackages.gcc14.cc` (the
  x86-runnable cross gcc, prefix-only binaries). The gas-NOP issue does NOT
  affect aarch64 (cross gcc bakes `--with-as` = cross binutils 2.41).

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

**This is NOT a toolchain-version issue.** A common misconception: "now
that we pin GUIX's exact gcc/glibc/binutils versions, can we drop the CRC
patch?" No. The patch has nothing to do with versions — we've matched
GUIX's gcc 14.3.0 / glibc 2.31 / binutils 2.41 since the nixos-25.11 days
and the `.dbg` still diverged then. The blockers are **recorded paths and
the target triple**, which version-matching does not change.

The CRC in a stripped binary is CRC32 of its `.dbg`. To drop the patch,
our `.dbg` would have to be byte-identical to upstream's. It is not. The
*stripped runtime binary* is already byte-equal (`dae69848…`); the entire
divergence is debug-only. Decompressed, the two `.dbg` are 292,886,544
(upstream) vs 292,713,176 (ours) — ~172 KB / 0.06 % apart, spread
proportionally across every debug section. That 0.06 % is entirely
**recorded paths** (`.debug_line_str` + the cascade of
`.debug_str`/`.debug_info` offset shifts).

#### The four structural divergences (and the fix each needs)

To make the `.dbg` byte-identical, ALL four must be matched:

1. **Debug sections not compressed.** Upstream's are `SHF_COMPRESSED`
   (GUIX's binutils compresses by default); ours aren't.
   *Fix:* add `-gz` to the debug build. **Effort: trivial.**

2. **Target triple.** Ours is `x86_64-unknown-linux-gnu` (nixpkgs
   default), GUIX's is `x86_64-linux-gnu`. Pervasive in include/lib paths
   in the debug info and baked into the gcc build itself.
   *Fix:* build x86_64 as a **cross-to-self** to `x86_64-linux-gnu` —
   exactly the "cross everywhere" change we want anyway, and exactly what
   the aarch64 path already does (`aarch64-linux-gnu`). **Effort: medium —
   a real toolchain restructure, but mirrors the existing aarch64 setup.**

3. **Toolchain header paths.** Ours `/nix/store/…gcc-14.3.0/include/c++/
   14.3.0`; upstream `/usr/include/c++` (GUIX maps `/gnu/store/*`→`/usr`
   *and* lays the c++ headers out without the version subdir).
   *Fix:* `-ffile-prefix-map` to rewrite our store paths to GUIX's `/usr`
   layout, including the version-less c++ header dir. **Effort: medium,
   fiddly — has to match GUIX's exact layout, not just any /usr mapping.**

4. **GUIX ephemeral build dirs baked into libgcc/glibc debug info.**
   `/tmp/guix-build-gcc-cross-x86_64-linux-gnu-14.3.0.drv-0/…` and
   `/tmp/guix-build-glibc-cross-…/source/csu`. These come from the
   *compiler's own* debug info in the statically-linked csu/libgcc
   members — they're already baked into the precompiled toolchain, not
   into our per-file compiles.
   *Fix:* rebuild **our** gcc and glibc with `-fdebug-prefix-map` pointing
   at GUIX's *exact* `.drv-0` ephemeral paths. **Effort: large and
   fragile — deep toolchain surgery to reproduce throwaway build-dir names
   purely for debugger metadata.** This is the real blocker.

#### Verdict

Dropping the patch is **days of high-risk work for a 4-byte debugger
hint** that doesn't affect the runtime binary or the shipped release
`.tar.gz` (which contains no `.dbg`; we don't even assemble the separate
`-debug.tar.gz`). So the CRC patch stays for all 10 binaries.

**When we do the cross-to-self change** (planned regardless — see the
"cross everywhere" goal), fix #2 falls out for free and fix #4 becomes
reachable in the same toolchain rebuild (we'll already be rebuilding gcc/
glibc as `x86_64-linux-gnu`, so adding the `-fdebug-prefix-map` flags
there is incremental). At that point revisit dropping the CRC patch:
do #1 + #3 alongside, and byte-identical `.dbg` (hence no CRC patch, and
a reproducible `-debug.tar.gz`) becomes plausible. Until then, keep it.

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
   `cmake --toolchain ${depends}/toolchain.cmake` and
   `CC=x86_64-linux-gnu-gcc` (the cross-to-self compiler; as of
   2026-06-10 this file is the former bitcoind-x86-cross.nix — the
   original native version is in git history). CMake (replaced autotools
   as of v29). Leaves `BUILD_TESTS` ON (GUIX does), so the tools +
   test_bitcoin build; the depends toolchain auto-enables `BUILD_GUI` +
   `WITH_QRENCODE` (Qt present). Skips bench/fuzz. Mirrors GUIX release
   flags (`REDUCE_EXPORTS=ON`, `CMAKE_SKIP_RPATH=TRUE`, `-O2 -g`). After
   install, split-debug via the prefixed cross binutils 2.41 (the GUIX
   objcopy/strip sequence), `.comment` rewrite, `.gnu_debuglink` CRC32
   patch, and the 10-hash gate.

3. **`default.nix`** — entry point. Constructs the two GUIX-exact cross
   toolchains — cross-to-self `x86_64-linux-gnu` (`crossGuixGccX86`) and
   cross `aarch64-linux-gnu` (`crossGuixGcc`) — each: cross binutils
   downgraded to 2.41, cross glibc overridden to GUIX's 2.31 git source
   (commit `7b27c450`, CC forced to the build→target cross gcc 14.3.0 —
   glibc is a bootstrap component, stdenv overrides are ignored), and the
   cross gcc 14.3.0 rebuilt against glibc 2.31 via `libcCross` with
   `gcc-ssa-generation.patch` + GUIX's `linux-base-gcc` configure flags
   (`--enable-default-pie`, `--enable-default-ssp=yes`,
   `--enable-host-bind-now`, `--enable-standard-branch-protection`,
   `--enable-initfini-array`, `--disable-nls`, x86-only `--enable-cet`,
   …). On x86 additionally: `--with-as`/`--with-ld` re-pointed at the
   2.41 cross binutils (gas NOP-fill order) and
   `-Wa,-mrelax-relocations=no` for the target libs (GOTPCRELX).

4. **`flake.nix`** — pins `nixpkgs` to `nixos-26.05` and exposes the
   outputs (all toolchain work lives in default.nix):
   - `nix build .#depends` — just the depends tree
   - `nix build .#bitcoind` (or `.#default`) — all 10 binaries
   - `nix build .#tarball` — the full release archive
   - `…Aarch64` variants of all three for the aarch64 release

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

### Glibc 2.31 build — replaced the old byte patches

(Historical note: this build originally lived in `flake.nix` as a native
glibc override; since 2026-06-10 it lives in `default.nix` as the CROSS
glibcs `crossGlibc231X86` / `crossGlibc231`, with the same override set
described here — the reasoning below is unchanged and still canonical.)

We build glibc 2.31 with gcc 14.3.0 (GUIX's gcc version) from GUIX's
exact git source. This produces CRTs and
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
