#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB load command to an arm64 Mach-O executable.

ipa-install-on-mac uses this to link libipakeychain.dylib into a sideloaded
app's main binary, which is how PlayCover links PlayTools (its `inject`
library does the same edit). Apple ships no tool for it: install_name_tool
can change or add rpaths but not add a dylib dependency.

The command is appended after the existing load commands, in the zero
padding the linker leaves before the first section's file offset; the header's
ncmds/sizeofcmds are bumped. Idempotent: an existing command for the same path
leaves the file untouched (exit 0, prints "already"). A fat binary is refused
(the caller thins to arm64 first); a binary with no room is refused.

Usage: ipa-inject-dylib.py <mach-o> <dylib path as the app should load it>
"""
import struct
import sys

LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
MH_MAGIC_64 = 0xFEEDFACF


def main(path, dylib):
    with open(path, "rb") as f:
        b = bytearray(f.read())
    magic = struct.unpack_from("<I", b, 0)[0]
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        sys.exit("fat binary: thin it to arm64 first")
    if magic != MH_MAGIC_64:
        sys.exit("not a 64-bit little-endian Mach-O")
    ncmds, sizeofcmds = struct.unpack_from("<II", b, 16)
    off = 32
    first_section = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", b, off)
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB):
            name_off = struct.unpack_from("<I", b, off + 8)[0]
            name = b[off + name_off:off + size].split(b"\0", 1)[0].decode("utf-8", "replace")
            if name == dylib:
                print("already")
                return
        if cmd == LC_SEGMENT_64:
            segname = b[off + 8:off + 24].split(b"\0", 1)[0]
            nsects = struct.unpack_from("<I", b, off + 64)[0]
            soff = off + 72
            for _s in range(nsects):
                sect_size = struct.unpack_from("<Q", b, soff + 40)[0]
                sect_off = struct.unpack_from("<I", b, soff + 48)[0]
                if segname == b"__TEXT" and sect_size and sect_off:
                    first_section = sect_off if first_section is None else min(first_section, sect_off)
                soff += 80
        off += size
    end = 32 + sizeofcmds
    name_bytes = dylib.encode() + b"\0"
    cmdsize = (24 + len(name_bytes) + 7) & ~7
    if first_section is not None and end + cmdsize > first_section:
        sys.exit(f"no room for a load command ({first_section - end} bytes of padding, {cmdsize} needed)")
    if any(b[end:end + cmdsize]):
        sys.exit("the bytes after the load commands are not padding; refusing")
    # dylib_command: cmd, cmdsize, name offset, timestamp, current version, compatibility version
    new = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + name_bytes.ljust(cmdsize - 24, b"\0")
    b[end:end + cmdsize] = new
    struct.pack_into("<II", b, 16, ncmds + 1, sizeofcmds + cmdsize)
    with open(path, "wb") as f:
        f.write(b)
    print(f"added LC_LOAD_DYLIB {dylib}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
