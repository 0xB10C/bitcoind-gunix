{ pkgs, version, url, sha256, buildSystem }:

let
  mkLinuxCrossTarget = import ../lib/linux-cross-target.nix { inherit pkgs version url sha256 buildSystem; };

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
      "bin/bitcoin" = "d28d634c82878263fc4878072fa132b1b518381e768081d7639da664b1b5da07";
      "bin/bitcoin-cli" = "bb5ecc78581cd0f2361f25884520af76c40cde505444a8670f933d3492ea811e";
      "bin/bitcoind" = "2c868a6a4d401269432a92f542bf833ce3622cd5caf7828016a7b61de64d0cc3";
      "bin/bitcoin-tx" = "e4d682e57827e1299e52a104341c66484adbd16fc5600c26a5aa3e8a562385e7";
      "bin/bitcoin-util" = "a33638e29496f0aec56aa53f930687919c24c87d1e49378d23512c14c125d9b1";
      "bin/bitcoin-wallet" = "22d3c59167c3686a011b6ec5a9c85a0fd0515b6db3e570beee8141437f83dfd3";
      "bin/bitcoin-qt" = "b348aa9d4fb2ccc5c0271a9ef072d196b85721de252e1cf65af6aca4f1eaaaec";
      "libexec/bitcoin-node" = "2d28a094263960c361cf901e1a43cf44d26ec99c0ea6f9005ef88137591c79fd";
      "libexec/bitcoin-gui" = "213838af6f99da64c635219505a635fbeac616c24691f64190457bfc97fa74c8";
      "libexec/test_bitcoin" = "6086d424a21967d8e8bf6e2e5f9f74de4b9c5495cbf3d5f0c6d80c42ae1f83bf";
      "bin/bitcoin.dbg" = "cfd2e64494d370734862c640d5358fc6aed812dc8466ed930cd0603d90edc14d";
      "bin/bitcoin-cli.dbg" = "66ad80b9584dc926cf3872d487085011e0dd1a3dc4c927376fb9d2ec7d34d6cd";
      "bin/bitcoind.dbg" = "881245c2c5f46c7834c99b9a06b03296fcc7349f5a261480cc426590ff650895";
      "bin/bitcoin-tx.dbg" = "5f853f178c6ce45a3b3cfd1564aeb7fb461cd22c1b2b09cf4d04d2b0a0c4b2bc";
      "bin/bitcoin-util.dbg" = "fa52baceb687b465846ac6dddefdb5ca852fa806b05890d053e43b727d195dbc";
      "bin/bitcoin-wallet.dbg" = "096273e898d962939ce359968d08b847d950abdc9bcdeca3825a5c426cbbd621";
      "bin/bitcoin-qt.dbg" = "ceb874159d794b01f016c5c72891d34b81a49d7b4f3d69fbbc3e6828656deeb3";
      "libexec/bitcoin-node.dbg" = "e120294b37da3ee878e6765609a1ca87a17b9d74b6749f5344e6683dbf33c13d";
      "libexec/bitcoin-gui.dbg" = "aa2f11addf9ff938e03939281f70dc0b340e05b629d68cf6cdb37c3b0d17021e";
      "libexec/test_bitcoin.dbg" = "d01cd44763909a640db92b491f03218609c16ec34eef189506bc225348833288";
    };
    tarballSha256 = "7ece4ea365bba9b2008b27f0717ef6a518598a572edaa2815e775faadc53c136";
    debugTarballSha256 = "acd0e38f4bb99c7c3024e494ca218d3ae67ec4a8b3b7ae556a8292353fe308b5";
  };
  dependsRiscv64 = riscv64Cross.depends;
  bitcoindRiscv64 = riscv64Cross.bitcoind;
  tarballRiscv64 = riscv64Cross.tarball;
  debugTarballRiscv64 = riscv64Cross.debugTarball;

in {
  inherit riscv64Cross dependsRiscv64 bitcoindRiscv64 tarballRiscv64 debugTarballRiscv64;
}
