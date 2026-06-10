# bitcoind-gunix

A Nix flake that reproduces the official Bitcoin Core GUIX release with
**byte-identical sha256** — all ten binaries **and** the full release
archive — for both `x86_64-linux-gnu` and `aarch64-linux-gnu`. Both
targets are built the way GUIX builds them: through a **cross toolchain
for the vendor-less target triple** — a "cross-to-self"
`x86_64-linux-gnu` toolchain for the x86_64 release, and an aarch64 cross
toolchain for the aarch64 release (**cross-compiled on an x86_64 host**,
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

Each derivation's `postFixup` asserts these hashes and fails the build on
mismatch — so a successful build *is* the reproducibility test. The build
uses only upstream sources (`fetchurl`/`fetchgit`); nothing is taken from a
pre-existing GUIX build.

Project history: https://github.com/0xB10C/bitcoind-gunix/issues/1 ·
follow-ups: https://github.com/0xB10C/bitcoind-gunix/issues/6

## Build

Requires Nix with flakes enabled.

```sh
# All ten binaries (result/bin/* and result/libexec/*):
nix build .#bitcoind --print-build-logs

# The full release archive (also builds .#bitcoind):
nix build .#tarball --print-build-logs
sha256sum result        # -> d3e4c58a…

# The aarch64 release, cross-compiled on x86_64 (10 binaries + tarball):
nix build .#bitcoindAarch64 --print-build-logs
nix build .#tarballAarch64 --print-build-logs
sha256sum result        # -> 4de1d568…

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

Not reproduced: the separate `-debug.tar.gz`. The `.dbg` debug files are
produced but aren't byte-reproducible (their DWARF records GUIX-internal
build paths and a different target triple), so each stripped binary's
4-byte `.gnu_debuglink` CRC is patched to upstream's value — the only
remaining byte patch. See `CLAUDE.md` for the full rationale.

## Layout

- `flake.nix` — entry point. Pins `nixpkgs` to `nixos-26.05` and exposes
  the outputs; all toolchain construction lives in `default.nix`.
- `default.nix` — assembles the two GUIX-exact **cross toolchains**
  (binutils 2.41, glibc 2.31 from GUIX's git source, gcc 14.3.0 with the
  `gcc-ssa-generation` patch and GUIX's `linux-base-gcc` flags, rebuilt
  against glibc 2.31 via `libcCross`): cross-to-self `x86_64-linux-gnu`
  and cross `aarch64-linux-gnu`. Exposes both targets' outputs.
- `depends.nix` — builds Bitcoin Core's `depends/` tree (incl. the full
  Qt6 GUI dependencies); parameterized by `hostTriple`, so it serves both
  `x86_64-linux-gnu` and the `aarch64-linux-gnu` cross build (`HOST=` puts
  depends in cross-compile mode, matching GUIX either way).
- `bitcoind.nix` / `bitcoind-aarch64.nix` — build all of Bitcoin Core via
  CMake with the prefixed cross compiler, then split-debug (cross binutils
  2.41), `.comment` rewrite, `.gnu_debuglink` CRC patch, and assert all
  ten binary hashes. The two differ in frame-pointer flags, ELF
  interpreter, and the per-binary CRC/hash tables.
- `tarball.nix` — assembles `bitcoin-31.0-<arch>-linux-gnu.tar.gz`
  byte-identical to upstream and asserts its hash (parameterized by `arch`).
- `patches/` — patch files applied via the .nix derivations.
- `CLAUDE.md` — design notes and the reproducibility methodology playbook.

## License

See [LICENSE](LICENSE).
