# bitcoind-gunix

A Nix flake that reproduces the official Bitcoin Core GUIX release
byte-for-byte: every binary, release archive, debug-symbols archive,
codesigning tarball and signed artifact, for all 8 GUIX release
targets. Everything is built the way GUIX builds it — through **cross
toolchains for the vendor-less target triples** (gcc 14.3.0 / glibc 2.31 /
binutils 2.46.0 for the Linux targets, clang/lld 19.1.7 for darwin, gcc
14.3.0 + mingw-w64 13.0.0 for win64) — **cross-compiled from a single
Linux host** (x86_64 or aarch64, no qemu).

**Currently tracking v32.0 (final release).** All 28 published artifacts
ARE gated: each derivation asserts its own sha256 against a checked-in
guix.sigs attestation — `noncodesigned.SHA256SUMS` for the 21
non-codesigned artifacts, `all.SHA256SUMS` for those plus the 6 signed
darwin/win64 artifacts and the codesignatures archive — so a mismatch
fails the build.

The build only requires upstream sources (`fetchurl`/`fetchgit`) — nothing
is taken from a pre-existing GUIX build or binary.

Project history: https://github.com/0xB10C/bitcoind-gunix/issues/1 ·
multi-arch/darwin/win64/signing follow-ups:
https://github.com/0xB10C/bitcoind-gunix/issues/6 (complete for v31.0)

## Build

Requires Nix with flakes enabled. The flake exposes the same pipeline for
**both `x86_64-linux` and `aarch64-linux` build hosts** ("cross
everywhere"); package names refer to the *target*, not the build host. On
an x86_64 machine `.#bitcoind` is a cross-to-self build and
`.#bitcoindAarch64` a cross build; on an aarch64 machine it's exactly
mirrored — every derivation gates the same upstream hashes either way.

### Per-target builds

> **note**: the current target is the v32.0 final release. All 28
> artifacts are gated: the 21 non-codesigned ones against
> `noncodesigned.SHA256SUMS` (aggregated by `.#noncodesignedSha256sums`,
> the flake default), and the 6 signed darwin/win64 artifacts plus the
> codesignatures archive against `all.SHA256SUMS` (aggregated by
> `.#sha256sums`). The signed flows apply the bitcoin-detached-sigs
> `v32.0` tag, which carries both `osx/` and `win/`.

```sh
# x86_64-linux-gnu (cross-to-self)
nix build .#bitcoind .#tarball .#debugTarball

# aarch64 / riscv64 / armhf / powerpc64 — same shape, suffixed
nix build .#bitcoindAarch64 .#tarballAarch64 .#debugTarballAarch64
nix build .#bitcoindRiscv64 .#tarballRiscv64 .#debugTarballRiscv64
nix build .#bitcoindArmhf   .#tarballArmhf   .#debugTarballArmhf
nix build .#bitcoindPpc64   .#tarballPpc64   .#debugTarballPpc64

# darwin x86_64 / arm64: unsigned tar+zip
nix build .#bitcoindDarwinX86   .#tarballDarwinX86   .#zipDarwinX86
nix build .#bitcoindDarwinArm64 .#tarballDarwinArm64 .#zipDarwinArm64

# win64: unsigned+debug zip, NSIS setup.exe
nix build .#bitcoindMingw .#unsignedZipMingw .#debugZipMingw
nix build .#setupExeMingw

# just a target's depends tree, e.g.:
nix build .#depends            # x86_64-linux-gnu
nix build .#dependsDarwinArm64
nix build .#dependsMingw
```

The first build is long — it rebuilds every target's GUIX-exact toolchain
and the full Qt6 depends tree. A binary cache makes repeat builds fast.

If a build fails and you want to inspect intermediate state, add
`--keep-failed`. Gated artifacts print `OK:`/`FAIL:` lines with the
hashes; an artifact whose filename is not in the checked-in
SHA256SUMS builds ungated and prints `BUILT (no upstream gate)`.

## License

See [LICENSE](LICENSE).
