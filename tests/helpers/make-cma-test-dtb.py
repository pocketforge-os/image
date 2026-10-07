#!/usr/bin/env python3
"""Write a minimal valid DTB for hermetic CMA guard tests."""

import argparse
from pathlib import Path
import struct


def align4(data: bytes) -> bytes:
    return data + b"\0" * (-len(data) % 4)


def begin_node(name: str) -> bytes:
    return struct.pack(">I", 1) + align4(name.encode("ascii") + b"\0")


def make_dtb(default_cma: bool) -> bytes:
    strings = b"linux,cma-default\0"
    structure = begin_node("") + begin_node("reserved-memory")
    if default_cma:
        structure += begin_node("vpu-cma@40000000")
        structure += struct.pack(">III", 3, 0, 0)
        structure += struct.pack(">I", 2)
    structure += struct.pack(">III", 2, 2, 9)

    reserve_map = b"\0" * 16
    structure_offset = 40 + len(reserve_map)
    strings_offset = structure_offset + len(structure)
    total_size = strings_offset + len(strings)
    header = struct.pack(
        ">10I",
        0xD00DFEED,
        total_size,
        structure_offset,
        strings_offset,
        40,
        17,
        16,
        0,
        len(strings),
        len(structure),
    )
    return header + reserve_map + structure + strings


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--default-cma", action="store_true")
    args = parser.parse_args()
    args.output.write_bytes(make_dtb(args.default_cma))


if __name__ == "__main__":
    main()
