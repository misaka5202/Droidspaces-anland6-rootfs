#!/usr/bin/env python3
"""Print the DT_NEEDED entries of an ELF64 file, one per line.

Used by the x86vk probe build to prove that every library Turnip links against
is actually present in the x86_64 tree. A device run assembled by hand loaded
the driver and then died on missing symbols, so the check earns its place.

Kept as a file rather than inlined in the workflow: a heredoc inside a YAML
block scalar breaks the indentation rules.
"""
import struct
import sys


def main(path: str) -> int:
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != b"\x7fELF":
        print(f"{path}: not an ELF file", file=sys.stderr)
        return 1
    if data[4] != 2:
        print(f"{path}: not ELF64", file=sys.stderr)
        return 1

    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    shnum = struct.unpack_from("<H", data, 0x3C)[0]

    sections = []
    for i in range(shnum):
        off = shoff + i * shentsize
        _, sh_type, _, _, sh_offset, sh_size, sh_link, _, _, _ = struct.unpack_from(
            "<IIQQQQIIQQ", data, off
        )
        sections.append((sh_type, sh_offset, sh_size, sh_link))

    dynamic = [s for s in sections if s[0] == 6]  # SHT_DYNAMIC
    if not dynamic:
        return 0
    _, dyn_off, dyn_size, dyn_link = dynamic[0]
    str_off = sections[dyn_link][1]

    for off in range(dyn_off, dyn_off + dyn_size, 16):
        tag, val = struct.unpack_from("<qQ", data, off)
        if tag == 0:  # DT_NULL
            break
        if tag == 1:  # DT_NEEDED
            start = str_off + val
            end = data.index(b"\0", start)
            print(data[start:end].decode())
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: elf-needed.py <elf>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
