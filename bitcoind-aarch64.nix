# Cross-build the full Bitcoin Core v31.0 aarch64-linux-gnu release (all 10
# binaries, incl. the Qt GUI) on an x86_64 machine, byte-for-byte identical
# to the upstream GUIX release. The aarch64 analog of bitcoind.nix; kept as a
# separate file because the cross build differs structurally (cross compiler
# via CC export, aarch64 ELF interpreter, cross binutils for split-debug,
# aarch64 frame-pointer handling, per-binary CRCs/hashes).
{ gcc14Stdenv
, fetchurl
, pkg-config
, cmake
, version
, url
, sha256
, depends # the aarch64 depends tree (Qt included)
, crossInputs # aarch64 cross cc/bintools (provides aarch64-linux-gnu-gcc/-objcopy/…)
}:

let
  # aarch64 frame pointers: upstream uses bare -O2, which on aarch64 KEEPS
  # the non-leaf frame pointer but OMITS the leaf one. nixpkgs' cross
  # cc-wrapper forces `-fno-omit-frame-pointer -mno-omit-leaf-frame-pointer`
  # (keep both). So we override only the leaf one back to omit — letting the
  # wrapper's -fno-omit-frame-pointer keep the non-leaf FP, matching upstream.
  # (On x86_64 the -O2 default omits both, hence bitcoind.nix uses
  # -fomit-frame-pointer there; here we must NOT, or every non-leaf function
  # loses its frame setup and the binary shrinks ~66 KB below upstream.)
  cflags = "-O2 -g -momit-leaf-frame-pointer"
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/aarch64-linux-gnu"
    + " -ffile-prefix-map=/build/bitcoin-${version}=/bitcoin"
    + " -ffile-prefix-map=/build/bitcoin-${version}/src=.";
in
gcc14Stdenv.mkDerivation {
  pname = "bitcoind-aarch64";
  name = "bitcoind-aarch64";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ] ++ crossInputs;

  # Match GUIX's CONFIGFLAGS (contrib/guix/libexec/build.sh), same as the
  # x86_64 bitcoind.nix: leave BUILD_TESTS at its default ON (builds
  # bitcoin-tx/-util/-wallet + test_bitcoin), skip bench/fuzz/gui-tests. The
  # depends toolchain.cmake auto-enables BUILD_GUI + WITH_QRENCODE because the
  # Qt depends are present, so bitcoin-qt / libexec/bitcoin-gui build too.
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
    # override the depends toolchain.cmake. Point CC/CXX at the aarch64
    # cross compiler so cmake cross-compiles (the native build stdenv would
    # otherwise leave CC=gcc → native x86_64).
    export CC=aarch64-linux-gnu-gcc
    export CXX=aarch64-linux-gnu-g++

    mkdir -p depends
    # mpgen's baked capnp_PREFIX is .../depends/aarch64-linux-gnu.
    ln -s ${depends} depends/aarch64-linux-gnu

    # aarch64 ELF interpreter is /lib/ld-linux-aarch64.so.1 (vs the x86-64
    # /lib64/ld-linux-x86-64.so.2). Mirrors GUIX's HOST_LDFLAGS.
    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=/lib/ld-linux-aarch64.so.1 -Wl,-O2 -static-libstdc++ -static-libgcc"
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

  # Mirror GUIX build.sh's split-debug + .gnu_debuglink handling (same as
  # x86_64 bitcoind.nix). Use the CROSS binutils 2.41 (aarch64-linux-gnu-*
  # from crossInputs) — not nixpkgs' native 2.44 — so strip/objcopy behave
  # like upstream's. The .gnu_debuglink CRC is CRC32 of each .dbg, which
  # isn't byte-reproducible (DWARF path/triple divergence, see CLAUDE.md
  # Task #2), so we overwrite it with upstream's per-binary value.
  postInstall = ''
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet bin/bitcoin-qt \
      libexec/bitcoin-node libexec/bitcoin-gui libexec/test_bitcoin; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --only-keep-debug "$f" "$f.dbg"
      aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --strip-debug "$f" "$f"
      aarch64-linux-gnu-strip --enable-deterministic-archives -p -s "$f"
      aarch64-linux-gnu-objcopy --enable-deterministic-archives -p --add-gnu-debuglink="$f.dbg" "$f"
      aarch64-linux-gnu-objcopy --update-section .comment=comment.bin "$f"
      case "$(basename "$f")" in
        bitcoin)        crc='\x95\x2c\x9d\xa9' ;;  # 0xa99d2c95
        bitcoin-cli)    crc='\x6b\x5e\xd3\x3e' ;;  # 0x3ed35e6b
        bitcoind)       crc='\x89\xe2\xe5\xe8' ;;  # 0xe8e5e289
        bitcoin-tx)     crc='\x7f\x25\x4b\xa5' ;;  # 0xa54b257f
        bitcoin-util)   crc='\x14\xdd\xda\xf5' ;;  # 0xf5dadd14
        bitcoin-wallet) crc='\x01\xe9\x5e\x3f' ;;  # 0x3f5ee901
        bitcoin-qt)     crc='\x64\xb1\xde\xe1' ;;  # 0xe1deb164
        bitcoin-node)   crc='\x13\x70\xf1\x8b' ;;  # 0x8bf17013
        bitcoin-gui)    crc='\xcf\x6b\xf1\xb3' ;;  # 0xb3f16bcf
        test_bitcoin)   crc='\x2c\x63\x14\xe1' ;;  # 0xe114632c
        *)              crc="" ;;
      esac
      if [ -n "$crc" ]; then
        read -r doff dsize < <(aarch64-linux-gnu-readelf -SW "$f" | sed 's/\[[ 0-9]*\]//' \
          | awk '/\.gnu_debuglink/{print strtonum("0x"$4), strtonum("0x"$5)}')
        printf "$crc" | dd of="$f" bs=1 seek=$((doff + dsize - 4)) count=4 conv=notrunc status=none
      fi
    done
  '';

  # Reproducibility gate: assert every shipped binary byte-matches the
  # upstream GUIX v31.0 aarch64-linux-gnu release.
  postFixup = ''
    declare -A expected=(
      [bin/bitcoin]=c793384c78c11b2125d0b68cc62b05fab7a96d6438f005f9e375f7d4a41bfe4c
      [bin/bitcoin-cli]=25c2743efb90ccaccbaea9f481e0a0357310af04b04f78b2320c0cc65ce12bf6
      [bin/bitcoind]=6f66822a44b4d4edd2a8ae1a11f63dd4db8d070e219c8eb54a3e2faa536409c2
      [bin/bitcoin-tx]=b41284232c62323a890bb8ba3befba1e1c4d197155461766a19618a0aaccda87
      [bin/bitcoin-util]=3a0daa1c1f840fc7f9ac18a29619aab071230ee5f9ef2690fd7f93f3b9003488
      [bin/bitcoin-wallet]=b7c2bb47030c7fb7e652c70a68c4c012cdd2e3562396423fc6c9ef01e0b589ac
      [bin/bitcoin-qt]=760c3de5ff9a54edfc6bf0c769df6dfe610aa9055d8ea0fa99edca4a62dc14d4
      [libexec/bitcoin-node]=f213271f7cec156be3d155c3c1012f4c226e2b9216a40215355a190105d1fad5
      [libexec/bitcoin-gui]=f85193a8b7f4323f612b92a5b7e19cda977f90bb9c26543d3f5277bf10c59291
      [libexec/test_bitcoin]=940fd792624130b36c1aef4fb4fc61723e622635478e7301bf37827caac9f1c5
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more aarch64 binaries diverged from upstream GUIX v31.0"; exit 1; }
    echo "OK: all 10 aarch64 binaries match upstream GUIX v31.0"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
