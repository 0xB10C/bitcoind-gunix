# bitcoind-gunix

A Nix flake that reproduces the **entire official Bitcoin Core v31.0 GUIX
release** byte-for-byte: every binary, release archive, debug-symbols
archive, codesigning tarball and signed artifact, for all 8 GUIX release
targets. Everything is built the way GUIX builds it — through **cross
toolchains for the vendor-less target triples** (gcc 14.3.0 / glibc 2.31 /
binutils 2.41 for the Linux targets, clang/lld 19.1.4 for darwin, gcc
14.3.0 + mingw-w64 12.0.0 for win64) — **cross-compiled from a single
Linux host** (x86_64 or aarch64, no qemu).

The build only requires upstream sources (`fetchurl`/`fetchgit`) — nothing
is taken from a pre-existing GUIX build or binary.

Project history: https://github.com/0xB10C/bitcoind-gunix/issues/1 ·
multi-arch/darwin/win64/signing follow-ups:
https://github.com/0xB10C/bitcoind-gunix/issues/6 (complete)

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
diff SHA256SUMS "$(nix path-info .#sha256sums)"
```

This builds (or fetches from cache) all 26 build artifacts plus the two
`git archive` source tarballs (`bitcoin-31.0.tar.gz` re-exported via
`fetchurl`, `bitcoin-31.0-codesignatures-31.0.tar.gz` generated from
`bitcoin-detached-sigs` — both byte-identical to upstream's) and produces
`all.SHA256SUMS` / `noncodesigned.SHA256SUMS` with bare filenames
(`<sha256>  <name>`), in the same order as upstream's published files — the
`diff` above should be empty.

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

## License

See [LICENSE](LICENSE).
