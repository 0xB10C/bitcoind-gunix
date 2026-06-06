{
  gcc14Stdenv # GCC 14, ideally with glibc 2.31 wired in via default.nix
, fetchurl
# build-inputs
, pkg-config
, cmake
#
, version
, url
, sha256
, depends
}:

let
  # Both CFLAGS and CXXFLAGS need the same set of flags. Factoring out
  # the string avoids the maintenance hazard of editing one and not the
  # other.
  cflags = "-O2 -g -fomit-frame-pointer -momit-leaf-frame-pointer"
    + " -ffile-prefix-map=${depends}=/bitcoin/depends/x86_64-linux-gnu"
    + " -ffile-prefix-map=/build/bitcoin-${version}=/bitcoin"
    + " -ffile-prefix-map=/build/bitcoin-${version}/src=.";
in
gcc14Stdenv.mkDerivation rec {
  pname = "bitcoind";
  name = "bitcoind";
  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ pkg-config cmake ];

  # Match the GUIX cmake invocation: build out-of-tree under ./build/ with
  # the depends-provided toolchain. Skip the GUI, tests, bench, and fuzz
  # binary; mirror the upstream-release flags (REDUCE_EXPORTS, SKIP_RPATH).
  cmakeBuildDir = "build";
  # Match GUIX's CONFIGFLAGS (contrib/guix/libexec/build.sh):
  #   -DREDUCE_EXPORTS=ON -DBUILD_BENCH=OFF -DBUILD_GUI_TESTS=OFF
  #   -DBUILD_FUZZ_BINARY=OFF -DCMAKE_SKIP_RPATH=TRUE   (+ -DWITH_CCACHE=OFF)
  # Notably GUIX leaves BUILD_TESTS at its default ON, which is what builds
  # bitcoin-tx, bitcoin-util, bitcoin-wallet and test_bitcoin (BUILD_TX,
  # BUILD_UTIL, BUILD_WALLET_TOOL all default to BUILD_TESTS). We do NOT
  # pass -DBUILD_GUI: the depends toolchain.cmake sets BUILD_GUI=ON and
  # WITH_QRENCODE=ON automatically because the Qt depends are present
  # (qt_packages non-empty). BUILD_GUI_TESTS stays off (matches GUIX;
  # test_bitcoin-qt isn't in the release).
  cmakeFlags = [
    "--toolchain=${depends}/toolchain.cmake"
    "-DBUILD_GUI_TESTS=OFF"
    "-DBUILD_BENCH=OFF"
    "-DBUILD_FUZZ_BINARY=OFF"
    "-DWITH_CCACHE=OFF"
    "-DREDUCE_EXPORTS=ON"
    "-DCMAKE_SKIP_RPATH=TRUE"
  ];

  # preConfigure does two things:
  #
  # 1. Symlink the depends output into ./depends/x86_64-pc-linux-gnu so the
  #    absolute path baked into mpgen via the `capnp_PREFIX` macro resolves.
  #    libmultiprocess's mpgen execs `<capnp_PREFIX>/bin/capnp` at codegen
  #    time, where capnp_PREFIX is the depends-build-time absolute path
  #    (/build/bitcoin-<ver>/depends/x86_64-pc-linux-gnu, baked in via
  #    src/ipc/libmultiprocess/include/mp/config.h.in). The Nix sandbox
  #    places our source at /build/bitcoin-<ver>, so this symlink makes
  #    that path resolve through to ${depends}.
  #
  # 2. Append -DCMAKE_EXE_LINKER_FLAGS via cmakeFlagsArray (rather than
  #    cmakeFlags) so the space-separated linker-flag value survives the
  #    nixpkgs cmake hook's word splitting. Mirror GUIX's full
  #    HOST_LDFLAGS + static-libstdc++/libgcc — see
  #    contrib/guix/libexec/build.sh:
  #
  #      HOST_LDFLAGS="-Wl,--as-needed
  #                    -Wl,--dynamic-linker=$glibc_dynamic_linker
  #                    -Wl,-O2"
  #      CMAKE_EXE_LINKER_FLAGS="${HOST_LDFLAGS} -static-libstdc++ -static-libgcc"
  #
  #    The dynamic-linker path (`/lib64/ld-linux-x86-64.so.2`) makes the
  #    resulting binary use the standard FHS interpreter rather than
  #    Nix's glibc store path, matching upstream. The binary then won't
  #    run on NixOS without nix-ld/buildFHSEnv, which is fine — the goal
  #    is byte-for-byte parity with the GUIX release.
  preConfigure = ''
    mkdir -p depends
    # depends now builds with HOST=x86_64-linux-gnu (matches GUIX), so
    # capnp_PREFIX is baked as .../depends/x86_64-linux-gnu. Symlink at
    # that name to satisfy mpgen's exec lookup.
    ln -s ${depends} depends/x86_64-linux-gnu

    cmakeFlagsArray+=(
      "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--as-needed -Wl,--dynamic-linker=/lib64/ld-linux-x86-64.so.2 -Wl,-O2 -static-libstdc++ -static-libgcc"
    )
  '';

  # Match GUIX's HOST_CFLAGS / HOST_CXXFLAGS from
  # contrib/guix/libexec/build.sh.
  #
  # -ffile-prefix-map remaps embedded build paths so __FILE__ strings
  # match upstream's recorded paths. GCC applies maps in command-line
  # order with LAST matching wins, so the more specific src=. comes
  # AFTER the broader /build/...=/bitcoin fallback:
  #   ${depends}                   -> /bitcoin/depends/x86_64-linux-gnu
  #     (boost/etc. headers in dependency includes)
  #   /build/bitcoin-${version}    -> /bitcoin           (general fallback)
  #   /build/bitcoin-${version}/src -> .                 (./<file>.cpp)
  #
  # -fomit-frame-pointer + -momit-leaf-frame-pointer override nixpkgs
  # gcc-wrapper's hardcoded -fno-omit-frame-pointer (in cc-cflags-before).
  # At -O2 gcc defaults to omitting frame pointers; without the override
  # we'd add ~12 bytes per function (push %rbp;...;leave) → ~258 KiB
  # .text bloat across the binary.
  env.CFLAGS = cflags;
  env.CXXFLAGS = cflags;

  # Tell nixpkgs' gcc-wrapper not to inject -rpath flags into the link line.
  # Upstream GUIX-built bitcoind has no RUNPATH; the binary uses the
  # standard /lib64/ld-linux-x86-64.so.2 interpreter to find libc / libm in
  # the system's standard library search paths. Without this, the wrapper
  # adds RUNPATH entries pointing at /nix/store/<glibc>/lib (where it
  # actually links against), which fixupPhase then can't remove because the
  # binary genuinely references those libraries — they're just findable via
  # the dynamic linker without RUNPATH.
  env.NIX_DONT_SET_RPATH = "1";
  env.NIX_NO_SELF_RPATH = "1";

  # Disable nixpkgs hardenings that GUIX's toolchain doesn't enable.
  # bitcoin's CMake separately re-adds the hardenings it wants for
  # `core_interface` targets — but those don't include secp256k1, so
  # globally-applied nixpkgs hardenings diverge from upstream there.
  #
  # - zerocallusedregs: -fzero-call-used-regs=used-gpr. +4-8 bytes per
  #   function on return; GUIX doesn't apply.
  # - strictoverflow: -fno-strict-overflow. Disables loop/arith optims.
  # - stackprotector: nixpkgs adds `--param ssp-buffer-size=4`; our gcc
  #   has --enable-default-ssp=yes so SSP-strong is the default anyway.
  # - stackclashprotection: -fstack-clash-protection. Bitcoin applies
  #   to core_interface only; upstream's secp256k1 lacks it.
  # - fortify / fortify3: -D_FORTIFY_SOURCE=3. Bitcoin re-applies to
  #   core_interface only; secp256k1 was picking it up via the nixpkgs
  #   global and diverging in secp256k1_ellswift_xdh (FORTIFY __chk
  #   variants cause register-pressure differences).
  # - strictflexarrays1: -fstrict-flex-arrays=1. New nixos-26.05 cc-wrapper
  #   default; codegen-affecting (GUIX's gcc defaults to =0). Leaving it on
  #   shifted the bytes of every binary on the 26.05 bump.
  # - libcxxhardeningfast: -D_LIBCPP_HARDENING_MODE=…FAST. New 26.05 default,
  #   libc++-only (we use libstdc++) — a no-op for us, dropped for cleanliness.
  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
    "strictflexarrays1" "libcxxhardeningfast"
  ];

  postInstall = ''
    # Replace .comment with just the gcc-14 stamp. (Mostly cosmetic now
    # that glibc is gcc-14-built, but a few objects still carry extra
    # stamps; upstream's binaries carry only "GCC: (GNU) 14.3.0".)
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin

    # For every shipped binary: split out debug info, normalize .comment,
    # and overwrite the .gnu_debuglink CRC32 with upstream's value.
    #
    # split-debug.sh (rendered from contrib/devtools/split-debug.sh.in into
    # the cmake build dir) runs the exact upstream invocation
    #   ./split-debug.sh <input> <input> <input>.dbg
    # so the stripped binary gets a .gnu_debuglink naming "<binary>.dbg",
    # matching upstream.
    #
    # The CRC is CRC32 of the .dbg, which we can't reproduce byte-for-byte
    # (upstream's debug info records GUIX-internal paths / target triple —
    # see CLAUDE.md "Task #2 finding"). It's only a debugger hint and is
    # absent from the runtime code, so we overwrite our 4 bytes with
    # upstream's. The CRC sits in the last 4 bytes of the .gnu_debuglink
    # section; we locate it dynamically rather than hardcoding the offset.
    for rel in \
      bin/bitcoin bin/bitcoin-cli bin/bitcoind bin/bitcoin-tx \
      bin/bitcoin-util bin/bitcoin-wallet bin/bitcoin-qt \
      libexec/bitcoin-node libexec/bitcoin-gui libexec/test_bitcoin; do
      f="$out/$rel"
      if [ ! -f "$f" ]; then echo "WARN: $rel was not built"; continue; fi
      ./split-debug.sh "$f" "$f" "$f.dbg"
      objcopy --update-section .comment=comment.bin "$f"
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
        read -r doff dsize < <(readelf -SW "$f" | sed 's/\[[ 0-9]*\]//' \
          | awk '/\.gnu_debuglink/{print strtonum("0x"$4), strtonum("0x"$5)}')
        printf "$crc" | dd of="$f" bs=1 seek=$((doff + dsize - 4)) count=4 conv=notrunc status=none
      fi
    done
  '';

  # Reproducibility gate: assert every shipped binary byte-matches the
  # upstream GUIX-built v31.0 release. Any divergence (or a missing binary)
  # fails the build, which is what makes this derivation a reproducibility
  # test rather than a best-effort build.
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
    [ "$fail" = "0" ] || { echo "FAIL: one or more binaries diverged from upstream GUIX v31.0"; exit 1; }
    echo "OK: all 10 binaries match upstream GUIX v31.0"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
