# bitcoind-gunix

A Nix flake that reproduces the official Bitcoin Core GUIX release for
`x86_64-linux-gnu` with **byte-identical sha256**: all ten binaries **and**
the full release archive.

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

# Just the depends tree:
nix build .#depends
```

The first build is long — it rebuilds the gcc 14 / glibc 2.31 toolchain
and the full Qt6 depends tree. A binary cache makes repeat builds fast.

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

- `flake.nix` — entry point. Pins `nixpkgs` to `nixos-25.11` and builds
  glibc 2.31 by overriding 25.11's glibc down to 2.31 (GUIX's exact git
  source), compiled with 25.11's **gcc 14.3.0** — the same gcc version
  GUIX uses, so no post-install byte patching of glibc is needed.
- `default.nix` — assembles the gcc 14 + glibc 2.31 toolchain. Downgrades
  binutils to 2.41 (matching GUIX), applies the `gcc-ssa-generation` patch
  and GUIX's `linux-base-gcc` configure flags.
- `depends.nix` — builds Bitcoin Core's `depends/` tree (incl. the full
  Qt6 GUI dependencies) with `HOST=x86_64-linux-gnu` (cross-compile mode,
  matching GUIX).
- `bitcoind.nix` — builds all of Bitcoin Core via CMake, then split-debug,
  `.comment` rewrite, `.gnu_debuglink` CRC patch, and asserts all ten
  binary hashes.
- `tarball.nix` — assembles `bitcoin-31.0-x86_64-linux-gnu.tar.gz`
  byte-identical to upstream and asserts its hash.
- `patches/` — patch files applied via the .nix derivations.
- `CLAUDE.md` — design notes and the reproducibility methodology playbook.

## License

See [LICENSE](LICENSE).
