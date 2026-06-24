{ pkgs, version, url, sha256, buildSystem, sourceDateEpoch }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version url sha256 buildSystem sourceDateEpoch; };

  # --- riscv64 cross-compile ---
  # The riscv64-linux-gnu release. riscv64-specific notes, all verified
  # against the upstream riscv64 .dbg/binaries before building (round-1
  # byte-match):
  # - NO --with-arch/-march handling anywhere: nixpkgs passes no
  #   --with-arch for riscv (riscv-multiplatform defines no gcc.arch), and
  #   gcc's own config.gcc default (rv64gc/lp64d) is what GUIX's gcc gets
  #   too — the driver-injected `-mabi=lp64d -misa-spec=20191213
  #   -mtls-dialect=trad -march=rv64imafdc_zicsr_zifencei` recorded in
  #   every upstream CU's DW_AT_producer comes from those shared defaults.
  # - glibc needs GUIX's glibc-riscv-jumptarget.patch (riscv sysdeps asm:
  #   HIDDEN_JUMPTARGET fixes; part of GUIX's glibc-2.31 source).
  # - frame pointers: riscv gcc at -O2 omits the frame pointer (like
  #   x86_64, no leaf/non-leaf split — -momit-leaf-frame-pointer does not
  #   exist on riscv).
  riscv64Cross = mkLinuxCrossTarget {
    triple = "riscv64-linux-gnu";
    glibcPatches = [ ../patches/glibc-riscv-jumptarget.patch ];
    dynamicLinker = "/lib/ld-linux-riscv64-lp64d.so.1";
    pnameSuffix = "riscv64";
    expectedHashes = {
      "bin/bitcoin" = "c4adbb9e0ea0f533c339ccbb5868133326042b57c475c618041b9bceef175bb9";
      "bin/bitcoin-cli" = "69429977982b4aead59a5d0bada4af95871356c54a97d142393ccc049f49a82d";
      "bin/bitcoind" = "ba897542f7cccc5a32db4061a64286afb90496469596e9aa866ffd4f3708e567";
      "bin/bitcoin-tx" = "e1cbe800a0d165c3058213541d23e66ef11552a83da393040b9eed411d8c4fad";
      "bin/bitcoin-util" = "004a1914df58f087f1e4ca015a8ba74aef4b901f6e299fe7d1281f6f1a947169";
      "bin/bitcoin-wallet" = "2a73242d858aa12b197290bdc4591930a31e37255648575229ed9524e1b4286b";
      "bin/bitcoin-qt" = "d56e6a0a78a51dd21bd76ab72169ab013cae1b9663acf6464069ab9739b8179d";
      "libexec/bitcoin-node" = "a39c3c13d7d48c67ca45358d41d835266de09f723be71a774aade6b781f4c4b0";
      "libexec/bitcoin-gui" = "969e06fc297ad11f6dcf66b00a63a0aa9cc0288a202b552c859819ba655aadeb";
      "libexec/test_bitcoin" = "33b1590eea803601b58b49209ce51166996f8c73d035bff995f2d78082e8cfb0";
      "bin/bitcoin.dbg" = "ca03e9558f31796c7297e5ae3d968252215d00f52ddef7558c7f3a47ece2431a";
      "bin/bitcoin-cli.dbg" = "2443e90e983adb8c84d647b8287c985f61cd8f74c4532a3bce7976eb5eb3df77";
      "bin/bitcoind.dbg" = "66aa8c367f7dfde59eda523ffd23b518330ed348babf619ca2ec652cffc07e37";
      "bin/bitcoin-tx.dbg" = "65e07a724965284c6c8f27d1c4a5bfc33d35d75972d62d5b51ae582d78f05498";
      "bin/bitcoin-util.dbg" = "4f0ece84c6ffa9ea247d5065d8dc69f629bb3daf39fdd882ec9a956b5197cbb9";
      "bin/bitcoin-wallet.dbg" = "2fdeab0ddd6b6741d197e4b2fc5a0d08fdf1a519ff50d315f69d7334fe89438f";
      "bin/bitcoin-qt.dbg" = "faa2fe842841f68cd9cb366b2c0468670db9f33e0393f3087d179691b6bdbcb4";
      "libexec/bitcoin-node.dbg" = "3ac64e6f79fd86beb6946cca44ca5bfdfea013ae2457adff8d2e043afbbbe8a7";
      "libexec/bitcoin-gui.dbg" = "eb0eb9174c0990f633d03b4f5428f46f8b6a9cd66b9b63e9f1b50dbe5d91e743";
      "libexec/test_bitcoin.dbg" = "7e7c972ba248a0d6a759b27ebc83469fa34bb1f5c408e07018fb5c6a98588518";
    };
    tarballSha256 = "727ae87288b171ba748106217e5d57bc18dd1dbc2bab53b8a9aaebb94d9f4d7d";
    debugTarballSha256 = "8658a8e46906c6750df767677aa8121f457d0d5e749abbd662d22dabbba1df20";
  };
  dependsRiscv64 = riscv64Cross.depends;
  bitcoindRiscv64 = riscv64Cross.bitcoind;
  tarballRiscv64 = riscv64Cross.tarball;
  debugTarballRiscv64 = riscv64Cross.debugTarball;

in {
  inherit riscv64Cross dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64;
}
