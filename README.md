# bitcoind-gunix

A nix package of bitcoind with the goal of matching the `x86_64-pc-linux-gnu` GUIX releases build bitcoind binary: Can we build a binary with an equal hash in Nix?

Build this Nix derivation (with Nix installed) with `nix-build`. If your build
fails, it can be helpful to use `nix-build --keep-failed`. This will keep the
build dir and display something like
`note: keeping build directory '/tmp/nix-build-bitcoind.drv'`.

Project status: https://github.com/0xB10C/bitcoind-gunix/issues/1
