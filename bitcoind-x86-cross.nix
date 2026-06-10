# Build the full Bitcoin Core v31.0 x86_64-linux-gnu release through the
# GUIX-style cross-to-self toolchain (default.nix's crossGuixGccX86 — the
# x86_64-linux-gnu-triple cross gcc/glibc/binutils), byte-for-byte identical
# to the upstream GUIX release. The cross-to-self analog of bitcoind.nix and
# the x86_64 sibling of bitcoind-aarch64.nix; intended to eventually REPLACE
# bitcoind.nix once proven (it is the prerequisite for fixing the .dbg
# target-triple divergence — see CLAUDE.md "Task #2 finding").
#
# Differences vs bitcoind.nix: compiles via the prefixed cross compiler
# (CC=x86_64-linux-gnu-gcc export, like the aarch64 file) instead of the
# native gcc14Glibc231Stdenv, and split-debug uses the explicit prefixed
# cross binutils 2.41 (the unprefixed objcopy/strip on PATH here belong to
# the plain build stdenv = binutils 2.46, whose behavior diverges).
# Differences vs bitcoind-aarch64.nix: x86_64 frame pointers (omit BOTH at
# -O2 — see the aarch64 file's note), the x86-64 ELF interpreter, and the
# x86_64 per-binary CRCs/hashes (same values as bitcoind.nix).
{ gcc14Stdenv # plain native build stdenv (native helper tools only)
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends # the cross-built x86_64-linux-gnu depends tree (Qt included)
, crossInputs # x86_64-linux-gnu cross cc/bintools (x86_64-linux-gnu-gcc/-objcopy/…)
}:

let
  # Same flags as bitcoind.nix: x86_64 gcc omits both frame pointers at -O2
  # (upstream relies on that default); the prefix-maps mirror GUIX's
  # HOST_CFLAGS path scheme.
  cflags = "-O2 -g -fomit-frame-pointer -momit-leaf-frame-pointer"
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/x86_64-linux-gnu"
    + " -ffile-prefix-map=/build/bitcoin-${version}=/bitcoin"
    + " -ffile-prefix-map=/build/bitcoin-${version}/src=.";
in
gcc14Stdenv.mkDerivation {
  pname = "bitcoind-x86-cross";
  name = "bitcoind-x86-cross";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  # Match GUIX's CONFIGFLAGS (contrib/guix/libexec/build.sh), same as
  # bitcoind.nix: leave BUILD_TESTS at its default ON, skip bench/fuzz/
  # gui-tests; the depends toolchain.cmake auto-enables BUILD_GUI +
  # WITH_QRENCODE because the Qt depends are present.
  cmakeBuildDir = "build";
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
    # override the depends toolchain.cmake. Point CC/CXX at the cross
    # compiler (the native build stdenv would otherwise leave CC=gcc →
    # the unprefixed native toolchain).
    export CC=x86_64-linux-gnu-gcc
    export CXX=x86_64-linux-gnu-g++

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/x86_64-linux-gnu.
    ln -s ${depends} depends/x86_64-linux-gnu

    # Mirror GUIX's HOST_LDFLAGS + static-libstdc++/libgcc (see
    # bitcoind.nix for the full reasoning). The dynamic-linker flag pins
    # the standard FHS x86-64 interpreter instead of the Nix glibc path.
    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 -Wl,-O2 -static-libstdc++ -static-libgcc"
    )
  '';

  env = {
    CFLAGS = cflags;
    CXXFLAGS = cflags;
    NIX_DONT_SET_RPATH = "1";
    NIX_NO_SELF_RPATH = "1";
  };

  # Same set as bitcoind.nix (see there for the per-flag reasoning).
  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  # Mirror GUIX build.sh's split-debug + .comment + .gnu_debuglink handling
  # (same as bitcoind.nix / bitcoind-aarch64.nix). Use the CROSS binutils
  # 2.41 (x86_64-linux-gnu-* from crossInputs) — the unprefixed objcopy on
  # PATH is the plain build stdenv's 2.46. The .gnu_debuglink CRC is CRC32
  # of each .dbg, which isn't byte-reproducible yet (DWARF path divergence,
  # see CLAUDE.md Task #2 — the triple part is fixed by this cross build,
  # the path part isn't yet), so we overwrite it with upstream's value.
  postInstall = ''
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet bin/bitcoin-qt \
      libexec/bitcoin-node libexec/bitcoin-gui libexec/test_bitcoin; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      x86_64-linux-gnu-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
      x86_64-linux-gnu-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
      x86_64-linux-gnu-strip --enable-deterministic-archives -p -s "$f"
      x86_64-linux-gnu-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
      x86_64-linux-gnu-objcopy --update-section .comment=comment.bin "$f"
      case "$(basename "$f")" in
        bitcoin)        crc='\x7b\x12\x2d\x4f' ;;  # 0x4f2d127b
        bitcoin-cli)    crc='\xc3\x5c\x13\x71' ;;  # 0x71135cc3
        bitcoind)       crc='\x29\x7e\xc7\x2c' ;;  # 0x2cc77e29
        bitcoin-tx)     crc='\x3c\x62\x09\x19' ;;  # 0x1909623c
        bitcoin-util)   crc='\xf6\x2f\x1d\xd5' ;;  # 0xd51d2ff6
        bitcoin-wallet) crc='\x67\x1c\xab\x2d' ;;  # 0x2dab1c67
        bitcoin-qt)     crc='\x4b\xf2\xfc\xfd' ;;  # 0xfdfcf24b
        bitcoin-node)   crc='\xe3\x80\xb4\xda' ;;  # 0xdab480e3
        bitcoin-gui)    crc='\x1f\x1d\x0f\x05' ;;  # 0x050f1d1f
        test_bitcoin)   crc='\x43\x9e\xed\x73' ;;  # 0x73ed9e43
        *)              crc="" ;;
      esac
      if [ -n "$crc" ]; then
        read -r doff dsize < <(x86_64-linux-gnu-readelf -SW "$f" | sed 's/\[[ 0-9]*\]//' \
          | awk '/\.gnu_debuglink/{print strtonum("0x"$4), strtonum("0x"$5)}')
        printf "$crc" | dd of="$f" bs=1 seek=$((doff + dsize - 4)) count=4 conv=notrunc status=none
      fi
    done
  '';

  # Reproducibility gate: assert every shipped binary byte-matches the
  # upstream GUIX v31.0 x86_64-linux-gnu release (same hashes as
  # bitcoind.nix — the cross-to-self build must reproduce the SAME release).
  postFixup = ''
    declare -A expected=(
      [bin/bitcoin]=eb5670aebd2b32c79215e578d2a7162fd1c98181bc558cfb8d29a4240e736521
      [bin/bitcoin-cli]=3e92883f97850bc445ac033d26d55902dcb035fdf64f78c2c03c83216f083c5d
      [bin/bitcoind]=dae69848ae9aaadcc3aa697d1c92b1283273a59c8d87b220b29ddc2813e25eb6
      [bin/bitcoin-tx]=ce3b159c9985eca941b3071c4dc573a4cf92ed9ee27fc1cf68a28d8afe893b6c
      [bin/bitcoin-util]=1d18ee4b1539110f784288462b8173d2d35d3b768ecbc3df83ebaa2781eb4306
      [bin/bitcoin-wallet]=7d8382b86cce7fde4214f295f7e134a873f176556ee98bc6dcbf9b347a25acaf
      [bin/bitcoin-qt]=3480af8fad820759a6299ea94bb3bb66f490b87c10ba44b1d0f671af382ff178
      [libexec/bitcoin-node]=01c212ee592f4ecc649b7a13c8fc0976f2d823900c66cd11460edaa59bba21ca
      [libexec/bitcoin-gui]=416e79bbebec5506ac786557519f3f5fc3fb1936a4a6074685d5f0aa24e01801
      [libexec/test_bitcoin]=c7a2a9062256920fa4b92e330857dc12e7f89882f8a3930ecdc3350acf922f8f
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more cross-to-self binaries diverged from upstream GUIX v31.0"; exit 1; }
    echo "OK: all 10 cross-to-self binaries match upstream GUIX v31.0"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
