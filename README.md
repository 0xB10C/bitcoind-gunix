# bitcoind-gunix

A Nix flake that reproduces the **entire official Bitcoin Core v31.0 GUIX
release** byte-for-byte: every binary, release archive, debug-symbols
archive, codesigning tarball and signed artifact, for all 8 GUIX release
targets. Everything is built the way GUIX builds it — through **cross
toolchains for the vendor-less target triples** (gcc 14.3.0 / glibc 2.31 /
binutils 2.41 for the Linux targets, clang/lld 19.1.4 for darwin, gcc
14.3.0 + mingw-w64 12.0.0 for win64) — **cross-compiled from a single
Linux host** (x86_64 or aarch64, no qemu).

There is **no binary patching anywhere** in this project: every byte-level
divergence that was ever found was root-caused to a build-configuration or
toolchain difference and fixed at that level.

Project history: https://github.com/0xB10C/bitcoind-gunix/issues/1 ·
multi-arch/darwin/win64/signing follow-ups:
https://github.com/0xB10C/bitcoind-gunix/issues/6 (complete)

## Status: COMPLETE

All **26 published artifacts** of the `bitcoin-core-31.0` GUIX release
reproduce byte-identically. Each derivation's `postFixup` asserts the
expected upstream sha256 and **fails the build on mismatch** — a
successful build *is* the reproducibility test. Headline hashes:

| Target | Release archive | sha256 |
|---|---|---|
| `x86_64-linux-gnu` | `.tar.gz` | `d3e4c58a…` |
| `aarch64-linux-gnu` | `.tar.gz` | `4de1d568…` |
| `riscv64-linux-gnu` | `.tar.gz` | `7ece4ea3…` |
| `arm-linux-gnueabihf` | `.tar.gz` | `8c19d007…` |
| `powerpc64-linux-gnu` | `.tar.gz` | `1d9c865a…` |
| `x86_64-apple-darwin` | `-unsigned.tar.gz` | `d1d0174f…` |
| `arm64-apple-darwin` | `-unsigned.tar.gz` | `48d34a14…` |
| `x86_64-w64-mingw32` (win64) | `-unsigned.zip` | `5ecd365b…` |

For each of the 5 Linux targets the `-debug.tar.gz` also reproduces (all
50 `.dbg` files byte-identical); for darwin and win64 the
`-codesigning.tar.gz` and the osslsigncode/signapple-**signed** artifacts
also reproduce. The full 26-line list — in upstream's own `SHA256SUMS`
format — is built directly with Nix (see below).

The build uses only upstream sources (`fetchurl`/`fetchgit`); nothing is
taken from a pre-existing GUIX build.

## Build

Requires Nix with flakes enabled. The flake exposes the same pipeline for
**both `x86_64-linux` and `aarch64-linux` build hosts** ("cross
everywhere"); package names refer to the *target*, not the build host. On
an x86_64 machine `.#bitcoind` is a cross-to-self build and
`.#bitcoindAarch64` a cross build; on an aarch64 machine it's exactly
mirrored — every derivation gates the same upstream hashes either way.

### Verify everything against upstream's SHA256SUMS

```sh
nix build .#sha256sums .#noncodesignedSha256sums --print-build-logs

# diff against the real thing
curl -sLO https://bitcoincore.org/bin/bitcoin-core-31.0/SHA256SUMS
grep -v -e bitcoin-31.0.tar.gz -e codesignatures SHA256SUMS \
  | diff - "$(nix path-info .#sha256sums)"
```

This builds (or fetches from cache) all 26 artifacts and produces
`all.SHA256SUMS` / `noncodesigned.SHA256SUMS` with bare filenames
(`<sha256>  <name>`), in the same order as upstream's published files —
the `diff` above should be empty.

### Per-target builds

```sh
# x86_64-linux-gnu (cross-to-self)
nix build .#bitcoind .#tarball .#debugTarball

# aarch64 / riscv64 / armhf / powerpc64 — same shape, suffixed
nix build .#bitcoindAarch64 .#tarballAarch64 .#debugTarballAarch64
nix build .#bitcoindRiscv64 .#tarballRiscv64 .#debugTarballRiscv64
nix build .#bitcoindArmhf   .#tarballArmhf   .#debugTarballArmhf
nix build .#bitcoindPpc64   .#tarballPpc64   .#debugTarballPpc64

# darwin x86_64 / arm64: unsigned tar+zip, codesigning tarball, signed tar+zip
nix build .#bitcoindDarwinX86   .#tarballDarwinX86   .#zipDarwinX86
nix build .#codesigningDarwinX86 .#signedDarwinX86
nix build .#bitcoindDarwinArm64 .#tarballDarwinArm64 .#zipDarwinArm64
nix build .#codesigningDarwinArm64 .#signedDarwinArm64

# win64: unsigned+debug zip, NSIS setup.exe, codesigning tarball, signed setup+zip
nix build .#bitcoindMingw .#unsignedZipMingw .#debugZipMingw
nix build .#setupExeMingw .#codesigningMingw .#signedMingw

# just a target's depends tree, e.g.:
nix build .#depends            # x86_64-linux-gnu
nix build .#dependsDarwinArm64
nix build .#dependsMingw
```

The first build is long — it rebuilds every target's GUIX-exact toolchain
and the full Qt6 depends tree. A binary cache makes repeat builds fast.

If a build fails and you want to inspect intermediate state, add
`--keep-failed`. The gates print `OK:`/`FAIL:` lines with the hashes.

## Layout

- `flake.nix` — entry point. Pins `nixpkgs` to `nixos-26.05` (plus
  `nixpkgs2405`, used only for the win64 NSIS gcc-11 toolchain) and exposes
  outputs per build host (`packages.{x86_64,aarch64}-linux`); all toolchain
  construction lives under `nix/`, assembled by `default.nix`.
- `default.nix` — orchestrator: shared `version`/`url`/`sha256`/
  `buildSystem` and the cross-target `detachedSigs` (used by both darwin
  and win64 signing), imports each `nix/<target>/toolchain.nix`, re-exports
  their outputs, and builds the `sha256sums` / `noncodesignedSha256sums`
  aggregates.
- `nix/<target>/toolchain.nix` — one per target (`x86_64-linux-gnu`,
  `aarch64-linux-gnu`, `riscv64-linux-gnu`, `arm-linux-gnueabihf`,
  `powerpc64-linux-gnu`, `darwin`, `win64`): each builds its GUIX-exact
  cross toolchain plus its depends/release/tarball/signing outputs.
  - The 5 Linux targets share a cross gcc 14.3.0 (GUIX's `linux-base-gcc`
    flags + `gcc-ssa-generation` patch) + binutils 2.41 + glibc 2.31 from
    GUIX's git source, rebuilt against each other via `libcCross`.
    `x86_64-linux-gnu` is cross-to-self; `riscv64-linux-gnu`,
    `arm-linux-gnueabihf` and `powerpc64-linux-gnu` are thin wrappers around
    `nix/lib/linux-cross-target.nix`.
  - `nix/darwin/` — clang/lld 19.1.4 toolchain (`toolchain.nix`); the 10
    Mach-O binaries + app bundle (`release.nix`); `-codesigning.tar.gz`
    (`codesigning.nix`); signapple-signed artifacts (`signed.nix`,
    `signapple.nix`).
  - `nix/win64/` — mingw-w64 12.0.0 / gcc 14.3.0 toolchain
    (`toolchain.nix`); the 8 PE binaries (`release.nix`); unsigned/debug
    `.zip` (`zip.nix`); NSIS 3.10 installer (`nsis-toolchain.nix`,
    `setup.nix`); `-codesigning.tar.gz` (`codesigning.nix`);
    osslsigncode-signed artifacts (`signed.nix`).
- `nix/lib/` — shared building blocks:
  - `linux-cross-target.nix` — the `mkLinuxCrossTarget` generator (cross
    toolchain + depends/bitcoind/tarball + 20-artifact/2-archive gate),
    used by riscv64/armhf/powerpc64.
  - `depends.nix` — builds Bitcoin Core's `depends/` tree (incl. the full
    Qt6 GUI dependencies), parameterized by `hostTriple`; serves every
    target.
  - `release-cross.nix` — builds Bitcoin Core via CMake with the prefixed
    cross compiler, split-debug + `.comment` rewrite, and the per-target
    binary/`.dbg` hash gate (riscv64/armhf/powerpc64; x86_64/aarch64 have
    their own `release.nix` predating this generator).
  - `tarball.nix` — assembles `bitcoin-31.0-<arch>(.tar.gz|-unsigned.tar.gz|
    -debug.tar.gz)` byte-identical to upstream and asserts its hash.
  - `cross-binutils-241.nix`, `linux-headers-61.nix` — binutils 2.41 /
    Linux 6.1.119 headers pinned and shared across targets.
  - `sha256sums.nix` — aggregates every reproduced artifact into
    `all.SHA256SUMS` / `noncodesigned.SHA256SUMS`, upstream's own format.
- `nix/patches/` — patches applied by the derivations above (gcc SSA
  determinism, glibc riscv jumptarget fix, debug-prefix-map
  canonicalization, NSIS env passthrough, etc.)
- `CLAUDE.md` — design notes and the reproducibility methodology playbook.

## License

See [LICENSE](LICENSE).
