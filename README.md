# bitcoind-gunix

A Nix package that reproduces the official Bitcoin Core GUIX release
`bitcoind` binary for `x86_64-pc-linux-gnu` with a **byte-identical
sha256**.

## Status

**Bitcoin Core v31.0** (branch `2025-05-claude`, off `v27.0`):

```
$ sha256sum result/bin/bitcoind /tmp/upstream-v31/bitcoin-31.0/bin/bitcoind
dae69848ae9aaadcc3aa697d1c92b1283273a59c8d87b220b29ddc2813e25eb6  result/bin/bitcoind
dae69848ae9aaadcc3aa697d1c92b1283273a59c8d87b220b29ddc2813e25eb6  /tmp/upstream-v31/bitcoin-31.0/bin/bitcoind
```

The `bitcoind.nix` derivation has a `postFixup` step that asserts
this hash and fails the build on mismatch — so the build itself is
the reproducibility test.

Project history: https://github.com/0xB10C/bitcoind-gunix/issues/1

## Build

Requires Nix with flakes enabled.

```sh
nix build .#bitcoind --print-build-logs
sha256sum result/bin/bitcoind
```

Just the depends tree:

```sh
nix build .#depends
```

If the build fails and you want to inspect intermediate state, add
`--keep-failed`. The `bitcoind.nix` reproducibility gate prints
either `OK: bitcoind sha256 matches upstream GUIX v31.0 (...)` or a
`FAIL:` line with the diverging hash.

## What's reproduced

Only `bin/bitcoind` is hashed against upstream. `bin/bitcoin`,
`bin/bitcoin-cli`, and `libexec/bitcoin-node` are produced but not
stripped — they'd need similar split-debug + `.gnu_debuglink` CRC
treatment to also match.

## Layout

- `flake.nix` — top-level entry point. Pins `nixpkgs` to `nixos-25.11`
  and a separate `nixpkgs-glibc231` to `nixos-20.09` (last release
  shipping glibc 2.31, matching GUIX). Rebuilds glibc 2.31 with GUIX
  configure flags and surgically patches its CRTs.
- `default.nix` — assembles the gcc 14 + glibc 2.31 toolchain.
  Downgrades binutils to 2.41 (matching GUIX). Applies the
  `gcc-ssa-generation` patch and GUIX `linux-base-gcc` configure flags.
- `depends.nix` — builds Bitcoin Core's `depends/` tree with
  `HOST=x86_64-linux-gnu` (cross-compile mode, matching GUIX).
- `bitcoind.nix` — builds `bitcoind` via CMake, then split-debug,
  `.comment` rewrite, `.gnu_debuglink` CRC patch, and the final hash
  assertion.
- `patches/` — patch files applied via the .nix derivations.
- `CLAUDE.md` — design notes and methodology playbook for the
  reproducibility work.

## License

See [LICENSE](LICENSE).
