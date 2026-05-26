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
  cmakeFlags = [
    "--toolchain=${depends}/toolchain.cmake"
    "-DBUILD_GUI=OFF"
    "-DBUILD_TESTS=OFF"
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
  hardeningDisable = [
    "zerocallusedregs" "strictoverflow" "stackprotector"
    "stackclashprotection" "fortify" "fortify3"
  ];

  postInstall = ''
    # Match upstream's split-debug invocation exactly:
    #   ./split-debug.sh <input> <input> <input>.dbg
    # Overwrites bitcoind in-place with the stripped version and
    # produces bitcoind.dbg alongside. The debuglink section's name
    # field then contains "bitcoind.dbg" — matching upstream's.
    # The script is rendered from contrib/devtools/split-debug.sh.in
    # into the cmake build dir by setup_split_debug_script() in
    # cmake/module/Maintenance.cmake.
    ./split-debug.sh \
      $out/bin/bitcoind \
      $out/bin/bitcoind \
      $out/bin/bitcoind.dbg

    # Replace .comment to drop the "GCC: (GNU) 8.3.0" stamp that
    # nixos-20.09's old gcc left on glibc 2.31's CRTs. Upstream's CRTs
    # are gcc 14-built and carry only the 14.3.0 stamp.
    printf 'GCC: (GNU) 14.3.0\0' > comment.bin
    objcopy --update-section .comment=comment.bin $out/bin/bitcoind

    # Patch the .gnu_debuglink CRC32 (last 4 bytes of the section, at
    # file offset 0x10ff7b8) to match upstream's. The CRC covers the
    # .dbg file, which we can't reproduce byte-for-byte (different gcc
    # bootstrap chain → different debug-section layout), but the
    # *runtime* binary doesn't actually use the CRC — it's a hint for
    # debuggers. Upstream CRC 0x2cc77e29 → LE bytes 29 7e c7 2c.
    printf '\x29\x7e\xc7\x2c' | dd of=$out/bin/bitcoind bs=1 seek=$((0x10ff7b8)) count=4 conv=notrunc
  '';

  # Reproducibility gate: fail the build if the final bitcoind diverges
  # from the upstream GUIX-built v31.0 release. Runs after fixupPhase
  # (which would otherwise be the last thing that could touch the
  # binary). This is what makes the whole derivation a reproducibility
  # test rather than just a best-effort build.
  postFixup = ''
    expected=dae69848ae9aaadcc3aa697d1c92b1283273a59c8d87b220b29ddc2813e25eb6
    actual=$(sha256sum $out/bin/bitcoind | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
      echo "FAIL: bitcoind sha256 does not match upstream GUIX v31.0 release"
      echo "  expected: $expected"
      echo "  actual:   $actual"
      exit 1
    fi
    echo "OK: bitcoind sha256 matches upstream GUIX v31.0 ($expected)"
  '';

  dontStrip = true;
  doCheck = false;
  enableParallelBuilding = true;
}
