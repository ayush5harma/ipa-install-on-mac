#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB load command to an arm64 Mach-O.

ipa-install-on-mac uses this to link everything it embeds -- the keychain
shim, the OpenGL ES redirect, PlayTools, a --dylib library -- into a
sideloaded app's main binary, which is how PlayCover links PlayTools (its
`inject` library does the same edit). Apple ships no tool for it:
install_name_tool can change or add rpaths but not add a dylib dependency.

The command is appended after the existing load commands, in the zero
padding the linker leaves before the first section's file offset; the header's
ncmds/sizeofcmds are bumped. Idempotent: an existing command for the same path
leaves the file untouched (exit 0, prints "already"). A fat binary is refused
(the caller thins to arm64 first); a binary with no room is refused.

Usage: ipa-inject-dylib.py <mach-o> <dylib path as the app should load it>
"""
import struct
import sys

FAT_MAGICS = (0xCAFEBABE, 0xBEBAFECA)    # a fat header, either byte order
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
DYLIB_COMMANDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB)
# Sizes of the structures this walks, from <mach-o/loader.h>.
HEADER_SIZE = 32          # mach_header_64, after which the load commands start
NCMDS_OFFSET = 16         # ncmds and sizeofcmds within that header
SEGMENT_SIZE = 72         # segment_command_64, before the first of its sections
SECTION_SIZE = 80         # section_64
DYLIB_COMMAND_SIZE = 24   # dylib_command, before the name it carries


def dylib_name(image, off, size):
    """The path the dylib load command at OFF names."""
    name_off = struct.unpack_from("<I", image, off + 8)[0]
    return image[off + name_off:off + size].split(b"\0", 1)[0].decode("utf-8", "replace")


def text_section_offset(image, off):
    """The lowest file offset among the __TEXT sections of the segment command
    at OFF, or None. The load commands may grow up to there and no further.

    The section table is walked for every segment, not only __TEXT: a segment
    whose section count runs past the end of the image raises here, which is
    how a malformed binary is refused before anything is written."""
    is_text = image[off + 8:off + 24].split(b"\0", 1)[0] == b"__TEXT"
    offsets = []
    nsects = struct.unpack_from("<I", image, off + 64)[0]
    sect = off + SEGMENT_SIZE
    for _ in range(nsects):
        sect_size = struct.unpack_from("<Q", image, sect + 40)[0]
        sect_off = struct.unpack_from("<I", image, sect + 48)[0]
        if is_text and sect_size and sect_off:
            offsets.append(sect_off)
        sect += SECTION_SIZE
    return min(offsets) if offsets else None


def main(path, dylib):
    with open(path, "rb") as f:
        image = bytearray(f.read())
    magic = struct.unpack_from("<I", image, 0)[0]
    if magic in FAT_MAGICS:
        sys.exit("fat binary: thin it to arm64 first")
    if magic != MH_MAGIC_64:
        sys.exit("not a 64-bit little-endian Mach-O")

    ncmds, sizeofcmds = struct.unpack_from("<II", image, NCMDS_OFFSET)
    limit = None                      # where the first section starts
    off = HEADER_SIZE
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", image, off)
        if cmd in DYLIB_COMMANDS and dylib_name(image, off, size) == dylib:
            print("already")
            return
        if cmd == LC_SEGMENT_64:
            start = text_section_offset(image, off)
            if start is not None:
                limit = start if limit is None else min(limit, start)
        off += size

    end = HEADER_SIZE + sizeofcmds
    name = dylib.encode() + b"\0"
    cmdsize = (DYLIB_COMMAND_SIZE + len(name) + 7) & ~7
    if limit is not None and end + cmdsize > limit:
        sys.exit(f"no room for a load command ({limit - end} bytes of padding, {cmdsize} needed)")
    if any(image[end:end + cmdsize]):
        sys.exit("the bytes after the load commands are not padding; refusing")
    # dylib_command: cmd, cmdsize, name offset, timestamp, current version, compatibility version
    command = struct.pack("<IIIIII", LC_LOAD_DYLIB, cmdsize, DYLIB_COMMAND_SIZE, 2, 0x10000, 0x10000)
    image[end:end + cmdsize] = command + name.ljust(cmdsize - DYLIB_COMMAND_SIZE, b"\0")
    struct.pack_into("<II", image, NCMDS_OFFSET, ncmds + 1, sizeofcmds + cmdsize)
    with open(path, "wb") as f:
        f.write(image)
    print(f"added LC_LOAD_DYLIB {dylib}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
