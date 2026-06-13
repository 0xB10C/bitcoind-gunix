#!/usr/bin/env python3
# Overwrite a Mach-O's LC_UUID with a fixed value.
#
# bitcoind-darwin.nix uses this to copy upstream's lld LC_UUID into
# bitcoin-qt / bitcoin-gui: those two come out byte-identical to the
# upstream GUIX release EXCEPT lld's 8-byte UUID, which is an xxh3 of the
# UNSTRIPPED link-time image. The bytes that differ live entirely in the
# Qt symtab/stabs region that `cmake --install --strip` removes AFTER lld
# hashes it, and reproducing GUIX's exact bytes there needs a GUIX darwin
# reference we don't have. Patching the UUID is also REQUIRED for the
# signed artifacts (the detached-sig cdhash covers it). This is the darwin
# analog of the project's historical .gnu_debuglink CRC patch.
#
# 64-bit little-endian Mach-O only (covers x86_64 and arm64 darwin).
import sys
import struct

path, hexstr = sys.argv[1], sys.argv[2]
uuid = bytes.fromhex(hexstr)
assert len(uuid) == 16, "uuid must be 16 bytes"

with open(path, "r+b") as f:
    data = f.read()
    magic = struct.unpack("<I", data[0:4])[0]
    assert magic == 0xFEEDFACF, "not a 64-bit LE Mach-O: %#x" % magic
    ncmds = struct.unpack("<I", data[16:20])[0]
    off = 32  # sizeof(mach_header_64)
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[off:off + 8])
        if cmd == 0x1B:  # LC_UUID
            f.seek(off + 8)
            f.write(uuid)
            print("patched LC_UUID at %#x in %s -> %s" % (off + 8, path, hexstr))
            break
        off += cmdsize
    else:
        sys.exit("LC_UUID not found in " + path)
