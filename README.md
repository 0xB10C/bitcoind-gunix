# bitcoind-gunix

A Nix flake that reproduces the official Bitcoin Core GUIX release with
**byte-identical sha256** — all ten binaries **and** the full release
archive — for `x86_64-linux-gnu`, `aarch64-linux-gnu`,
`riscv64-linux-gnu`, `arm-linux-gnueabihf` and `powerpc64-linux-gnu`.
All targets are built the way GUIX builds them: through a **cross
toolchain for the vendor-less target triple** — a "cross-to-self"
`x86_64-linux-gnu` toolchain for the x86_64 release, and per-target
cross toolchains for the others (**cross-compiled on an x86_64 host**,
no qemu).

## Status

**Bitcoin Core v31.0** — every binary in the upstream
`bitcoin-31.0-x86_64-linux-gnu` release reproduces byte-for-byte, and so
does the assembled `bitcoin-31.0-x86_64-linux-gnu.tar.gz`:

```
eb5670ae…  bin/bitcoin            ce3b159c…  bin/bitcoin-tx
3e92883f…  bin/bitcoin-cli        1d18ee4b…  bin/bitcoin-util
dae69848…  bin/bitcoind           7d8382b8…  bin/bitcoin-wallet
3480af8f…  bin/bitcoin-qt         01c212ee…  libexec/bitcoin-node
416e79bb…  libexec/bitcoin-gui    c7a2a906…  libexec/test_bitcoin

d3e4c58a…  bitcoin-31.0-x86_64-linux-gnu.tar.gz
```

The same holds for the `aarch64-linux-gnu` release, cross-compiled on
x86_64:

```
c793384c…  bin/bitcoin            b4128423…  bin/bitcoin-tx
25c2743e…  bin/bitcoin-cli        3a0daa1c…  bin/bitcoin-util
6f66822a…  bin/bitcoind           b7c2bb47…  bin/bitcoin-wallet
760c3de5…  bin/bitcoin-qt         f213271f…  libexec/bitcoin-node
f85193a8…  libexec/bitcoin-gui    940fd792…  libexec/test_bitcoin

4de1d568…  bitcoin-31.0-aarch64-linux-gnu.tar.gz
```

And for the `riscv64-linux-gnu` release, also cross-compiled on x86_64:

```
d28d634c…  bin/bitcoin            e4d682e5…  bin/bitcoin-tx
bb5ecc78…  bin/bitcoin-cli        a33638e2…  bin/bitcoin-util
2c868a6a…  bin/bitcoind           22d3c591…  bin/bitcoin-wallet
b348aa9d…  bin/bitcoin-qt         2d28a094…  libexec/bitcoin-node
213838af…  libexec/bitcoin-gui    6086d424…  libexec/test_bitcoin

7ece4ea3…  bitcoin-31.0-riscv64-linux-gnu.tar.gz
```

And the `arm-linux-gnueabihf` and `powerpc64-linux-gnu` **release
archives** also reproduce (all 10 runtime binaries of each byte-match):

```
8c19d007…  bitcoin-31.0-arm-linux-gnueabihf.tar.gz
1d9c865a…  bitcoin-31.0-powerpc64-linux-gnu.tar.gz
```

(Their separate `-debug.tar.gz` archives also reproduce — all 20 `.dbg`
of the two targets are byte-identical to upstream's, see below.)

Each derivation's `postFixup` asserts these hashes and fails the build on
mismatch — so a successful build *is* the reproducibility test. The build
uses only upstream sources (`fetchurl`/`fetchgit`); nothing is taken from a
pre-existing GUIX build.

Project history: https://github.com/0xB10C/bitcoind-gunix/issues/1 ·
follow-ups: https://github.com/0xB10C/bitcoind-gunix/issues/6

## Build

Requires Nix with flakes enabled.

The flake exposes the same pipeline for **both `x86_64-linux` and
`aarch64-linux` build hosts** ("cross everywhere"); package names refer to
the *target*. On an x86_64 machine `.#bitcoind` is a cross-to-self build
and `.#bitcoindAarch64` a cross build; on an aarch64 machine it's exactly
mirrored — every derivation gates the same upstream hashes either way.

```sh
# All ten binaries (result/bin/* and result/libexec/*):
nix build .#bitcoind --print-build-logs

# The full release archive (also builds .#bitcoind):
nix build .#tarball --print-build-logs
sha256sum result        # -> d3e4c58a…

# The debug-symbols archive (all ten .dbg byte-identical too):
nix build .#debugTarball --print-build-logs
sha256sum result        # -> 96e35061…

# The aarch64 release, cross-compiled on x86_64 (10 binaries + tarball):
nix build .#bitcoindAarch64 --print-build-logs
nix build .#tarballAarch64 --print-build-logs
sha256sum result        # -> 4de1d568…

# The aarch64 debug-symbols archive:
nix build .#debugTarballAarch64 --print-build-logs
sha256sum result        # -> 91917647…

# The riscv64 release, cross-compiled on x86_64 (10 binaries + tarball):
nix build .#bitcoindRiscv64 --print-build-logs
nix build .#tarballRiscv64 --print-build-logs
sha256sum result        # -> 7ece4ea3…

# The riscv64 debug-symbols archive:
nix build .#debugTarballRiscv64 --print-build-logs
sha256sum result        # -> acd0e38f…

# The armhf and powerpc64 releases (each: 10 binaries + both archives):
nix build .#tarballArmhf --print-build-logs        # -> 8c19d007…
nix build .#debugTarballArmhf --print-build-logs   # -> fc17562b…
nix build .#tarballPpc64 --print-build-logs        # -> 1d9c865a…
nix build .#debugTarballPpc64 --print-build-logs   # -> efe3e7d0…

# Just the depends tree:
nix build .#depends
```

The first build is long — it rebuilds the gcc 14 / glibc 2.31 toolchain
and the full Qt6 depends tree (the aarch64 outputs use their own cross
toolchain + cross depends). A binary cache makes repeat builds fast.

If a build fails and you want to inspect intermediate state, add
`--keep-failed`. The gates print `OK:`/`FAIL:` lines with the hashes.

## What's reproduced

All ten release binaries (`bin/{bitcoin,bitcoin-cli,bitcoind,bitcoin-qt,
bitcoin-tx,bitcoin-util,bitcoin-wallet}`, `libexec/{bitcoin-gui,
bitcoin-node,test_bitcoin}`) and the `bitcoin-31.0-x86_64-linux-gnu.tar.gz`
archive.

The separate debug-symbols archives are **also reproduced for all five
targets** (`nix build .#debugTarball` → `96e35061…`;
`.#debugTarballAarch64` → `91917647…`; `.#debugTarballRiscv64` →
`acd0e38f…`; `.#debugTarballArmhf` → `fc17562b…`; `.#debugTarballPpc64`
→ `efe3e7d0…`): all fifty `.dbg` debug files are byte-identical to
upstream's with no byte patching anywhere.

## Layout

- `flake.nix` — entry point. Pins `nixpkgs` to `nixos-26.05` and exposes
  the outputs per build host (`packages.{x86_64,aarch64}-linux`); all
  toolchain construction lives in `default.nix`.
- `default.nix` — assembles the five GUIX-exact **cross toolchains**
  (binutils 2.41, glibc 2.31 from GUIX's git source, gcc 14.3.0 with the
  `gcc-ssa-generation` patch and GUIX's `linux-base-gcc` flags, rebuilt
  against glibc 2.31 via `libcCross`): cross-to-self `x86_64-linux-gnu`
  and cross `aarch64-linux-gnu` / `riscv64-linux-gnu` /
  `arm-linux-gnueabihf` / `powerpc64-linux-gnu` (the last three via the
  `mkLinuxCrossTarget` generator). Exposes all targets' outputs.
- `nix/lib/depends.nix` — builds Bitcoin Core's `depends/` tree (incl. the
  full Qt6 GUI dependencies); parameterized by `hostTriple`, so it serves
  every target (`HOST=` puts depends in cross-compile mode, matching
  GUIX either way).
- `nix/x86_64-linux-gnu/release.nix` / `nix/aarch64-linux-gnu/release.nix` /
  `nix/lib/release-cross.nix` — build all of Bitcoin Core via CMake with the
  prefixed cross compiler, then split-debug (cross binutils 2.41) and
  `.comment` rewrite, and assert all twenty per-target hashes (10 binaries +
  10 `.dbg`). `nix/lib/release-cross.nix` is parameterized over the target and
  serves riscv64/armhf/ppc64 (via `mkLinuxCrossTarget` in `default.nix`); the
  x86_64 and aarch64 files predate it.
- `nix/lib/tarball.nix` — assembles `bitcoin-31.0-<arch>-linux-gnu.tar.gz`
  byte-identical to upstream and asserts its hash (parameterized by `arch`).
- `nix/darwin/` — `release.nix` (the 10 Mach-O binaries for x86_64/arm64),
  `codesigning.nix` / `signed.nix` (the `-codesigning.tar.gz` and
  signapple-signed artifacts), `signapple.nix` (the signing toolchain).
- `nix/win64/` — `release.nix` (the 8 PE binaries), `zip.nix`
  (unsigned/debug `.zip`), `nsis-toolchain.nix` + `setup.nix` (NSIS 3.10 and
  `setup-unsigned.exe`), `codesigning.nix` / `signed.nix` (the
  `-codesigning.tar.gz` and osslsigncode-signed artifacts).
- `nix/patches/` — patch files applied via the .nix derivations.
- `CLAUDE.md` — design notes and the reproducibility methodology playbook.

## License

See [LICENSE](LICENSE).
