# Cross-build the full Bitcoin Core v31.0 riscv64-linux-gnu release (all 10
# binaries, incl. the Qt GUI), byte-for-byte identical to the upstream GUIX
# release. The riscv64 analog of bitcoind-aarch64.nix (same structure; the
# files differ in the target triple, the ELF interpreter, the frame-pointer
# story and the per-binary hashes).
{ gcc14Stdenv
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends # the riscv64 depends tree (Qt included)
, crossInputs # riscv64 cross cc/bintools (provides riscv64-linux-gnu-gcc/-objcopy/…)
, guixGcc # the unwrapped cross gcc (crossGuixGccRiscv64.cc) — for header prefix-maps
, linuxHeaders # kernel headers — gcc canonicalizes the sys-include symlinks to this store path
}:

let
  # Match GUIX's HOST_CFLAGS/HOST_CXXFLAGS: bare `-O2 -g` plus prefix maps,
  # exactly like bitcoind.nix (see its comment for the full map reasoning).
  # NO explicit frame-pointer flags: crossInputs is the NoFp wrapper
  # variant, so the riscv64 -O2 default applies (omit the frame pointer —
  # riscv has no leaf/non-leaf split), and DW_AT_producer stays flag-free
  # like upstream's (the riscv -march/-mabi/-misa-spec/-mtls-dialect
  # recorded there are DRIVER-injected from gcc's configured defaults,
  # identical between nixpkgs' and GUIX's gcc — both rv64gc/lp64d).
  cflags = "-O2 -g"
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/riscv64-linux-gnu"
    + " -ffile-prefix-map=${guixGcc}/include/c++/14.3.0=/usr/include/c++"
    + " -ffile-prefix-map=${guixGcc}/riscv64-linux-gnu/sys-include=/usr/include"
    + " -ffile-prefix-map=${guixGcc}/lib/gcc=/usr/lib/gcc"
    + " -ffile-prefix-map=${linuxHeaders}/include=/usr/include"
    + " -fdebug-prefix-map=/build/bitcoin-${version}=/distsrc-base/distsrc-${version}-riscv64-linux-gnu"
    + " -fdebug-prefix-map=/build/bitcoin-${version}/src=.";
in
gcc14Stdenv.mkDerivation {
  pname = "bitcoind-riscv64";
  name = "bitcoind-riscv64";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  # Match GUIX's CONFIGFLAGS (contrib/guix/libexec/build.sh), same as the
  # x86_64 bitcoind.nix: leave BUILD_TESTS at its default ON (builds
  # bitcoin-tx/-util/-wallet + test_bitcoin), skip bench/fuzz/gui-tests. The
  # depends toolchain.cmake auto-enables BUILD_GUI + WITH_QRENCODE because the
  # Qt depends are present, so bitcoin-qt / libexec/bitcoin-gui build too.
  cmakeBuildDir = "build";
  # GUIX doesn't pass a build type, so bitcoin's CMakeLists defaults to
  # RelWithDebInfo; nixpkgs' cmake hook would force Release. Visible in
  # DW_AT_producer (see bitcoind.nix); same effective codegen (-O2).
  cmakeBuildType = "RelWithDebInfo";
  cmakeFlags = [
    "--toolchain=${depends}/toolchain.cmake"
    "-DBUILD_GUI_TESTS=OFF"
    "-DBUILD_BENCH=OFF"
    "-DBUILD_FUZZ_BINARY=OFF"
    "-DWITH_CCACHE=OFF"
    "-DREDUCE_EXPORTS=ON"
    "-DCMAKE_SKIP_RPATH=TRUE"
  ];

  preConfigure = ''
    # nixpkgs' cmake setup-hook passes -DCMAKE_C_COMPILER=$CC etc., which
    # override the depends toolchain.cmake. Point CC/CXX at the riscv64
    # cross compiler so cmake cross-compiles.
    export CC=riscv64-linux-gnu-gcc
    export CXX=riscv64-linux-gnu-g++

    # Drop the -frandom-seed=<out-hash> appended by nixpkgs'
    # reproducible-builds hook — recorded in DW_AT_producer (see
    # bitcoind.nix).
    export NIX_CFLAGS_COMPILE=$(echo "$NIX_CFLAGS_COMPILE" | sed 's/-frandom-seed=[^ ]*//')

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/riscv64-linux-gnu.
    ln -s ${depends} depends/riscv64-linux-gnu

    # riscv64 ELF interpreter is /lib/ld-linux-riscv64-lp64d.so.1 (vs the
    # x86-64 /lib64/ld-linux-x86-64.so.2). Mirrors GUIX's HOST_LDFLAGS.
    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=/lib/ld-linux-riscv64-lp64d.so.1 -Wl,-O2 -static-libstdc++ -static-libgcc"
    )
  '';

  env = {
    CFLAGS = cflags;
    CXXFLAGS = cflags;
    NIX_DONT_SET_RPATH = "1";
    NIX_NO_SELF_RPATH = "1";
  };

  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    # New nixos-26.05 cc-wrapper defaults GUIX doesn't apply (see bitcoind.nix):
    # strictflexarrays1 is codegen-affecting; libcxxhardeningfast is libc++-only.
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Mirror GUIX build.sh's split-debug + .comment handling (same as
  # x86_64 bitcoind.nix). Use the CROSS binutils 2.41 (riscv64-linux-gnu-*
  # from crossInputs) — not nixpkgs' native one — so strip/objcopy behave
  # like upstream's. No .gnu_debuglink CRC patching: like x86_64/aarch64,
  # the .dbg files are expected byte-identical, so objcopy
  # --add-gnu-debuglink computes upstream's CRC naturally (the postFixup
  # gate asserts the .dbg hashes).
  postInstall = ''
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet bin/bitcoin-qt \
      libexec/bitcoin-node libexec/bitcoin-gui libexec/test_bitcoin; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      riscv64-linux-gnu-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
      riscv64-linux-gnu-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
      riscv64-linux-gnu-strip --enable-deterministic-archives -p -s "$f"
      riscv64-linux-gnu-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
      riscv64-linux-gnu-objcopy --update-section .comment=comment.bin "$f"
    done
  '';

  # Reproducibility gate: assert every shipped binary AND every .dbg debug
  # file byte-matches the upstream GUIX v31.0 riscv64-linux-gnu release
  # (the .dbg are what ship in the separate -debug.tar.gz).
  postFixup = ''
    declare -A expected=(
      [bin/bitcoin]=d28d634c82878263fc4878072fa132b1b518381e768081d7639da664b1b5da07
      [bin/bitcoin-cli]=bb5ecc78581cd0f2361f25884520af76c40cde505444a8670f933d3492ea811e
      [bin/bitcoind]=2c868a6a4d401269432a92f542bf833ce3622cd5caf7828016a7b61de64d0cc3
      [bin/bitcoin-tx]=e4d682e57827e1299e52a104341c66484adbd16fc5600c26a5aa3e8a562385e7
      [bin/bitcoin-util]=a33638e29496f0aec56aa53f930687919c24c87d1e49378d23512c14c125d9b1
      [bin/bitcoin-wallet]=22d3c59167c3686a011b6ec5a9c85a0fd0515b6db3e570beee8141437f83dfd3
      [bin/bitcoin-qt]=b348aa9d4fb2ccc5c0271a9ef072d196b85721de252e1cf65af6aca4f1eaaaec
      [libexec/bitcoin-node]=2d28a094263960c361cf901e1a43cf44d26ec99c0ea6f9005ef88137591c79fd
      [libexec/bitcoin-gui]=213838af6f99da64c635219505a635fbeac616c24691f64190457bfc97fa74c8
      [libexec/test_bitcoin]=6086d424a21967d8e8bf6e2e5f9f74de4b9c5495cbf3d5f0c6d80c42ae1f83bf
      [bin/bitcoin.dbg]=cfd2e64494d370734862c640d5358fc6aed812dc8466ed930cd0603d90edc14d
      [bin/bitcoin-cli.dbg]=66ad80b9584dc926cf3872d487085011e0dd1a3dc4c927376fb9d2ec7d34d6cd
      [bin/bitcoind.dbg]=881245c2c5f46c7834c99b9a06b03296fcc7349f5a261480cc426590ff650895
      [bin/bitcoin-tx.dbg]=5f853f178c6ce45a3b3cfd1564aeb7fb461cd22c1b2b09cf4d04d2b0a0c4b2bc
      [bin/bitcoin-util.dbg]=fa52baceb687b465846ac6dddefdb5ca852fa806b05890d053e43b727d195dbc
      [bin/bitcoin-wallet.dbg]=096273e898d962939ce359968d08b847d950abdc9bcdeca3825a5c426cbbd621
      [bin/bitcoin-qt.dbg]=ceb874159d794b01f016c5c72891d34b81a49d7b4f3d69fbbc3e6828656deeb3
      [libexec/bitcoin-node.dbg]=e120294b37da3ee878e6765609a1ca87a17b9d74b6749f5344e6683dbf33c13d
      [libexec/bitcoin-gui.dbg]=aa2f11addf9ff938e03939281f70dc0b340e05b629d68cf6cdb37c3b0d17021e
      [libexec/test_bitcoin.dbg]=d01cd44763909a640db92b491f03218609c16ec34eef189506bc225348833288
    )
    fail=0
    for rel in "''${!expected[@]}"; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "FAIL: $rel was not built"; fail=1; continue; fi
      actual=$(sha256sum "$f" | cut -d' ' -f1)
      if [ "$actual" = "''${expected[$rel]}" ]; then
        echo "OK:   $rel matches upstream"
      else
        echo "FAIL: $rel  expected ''${expected[$rel]}  actual $actual"
        fail=1
      fi
    done
    [ "$fail" = "0" ] || { echo "FAIL: one or more riscv64 binaries/.dbg diverged from upstream GUIX v31.0"; exit 1; }
    echo "OK: all 10 riscv64 binaries and all 10 .dbg files match upstream GUIX v31.0"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
