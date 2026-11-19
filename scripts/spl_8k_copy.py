#!/usr/bin/env python3
"""spl_8k_copy — add a second eGON.BT0 SPL copy at 8 KiB (0x2000).

The stock Allwinner eMMC image carries the SPL at both 8 KiB and 128 KiB;
the owned-spl SD image only at 128 KiB.  This module copies the eGON blob
(self-describing length) from the 128 KiB slot down to 8 KiB after genimage,
and verifies the copy.  Pure stdlib; no genimage dependency.

API
---
LOW_OFF, HIGH_OFF : int
    Byte offsets of the low (8 KiB) and high (128 KiB) SPL slots.
egon_length(spl) -> int
    Length of the eGON blob; ValueError unless magic / checksum / length sane.
low_copy(spl) -> bytes
    The eGON blob: spl[:egon_length(spl)].
apply(image, spl) -> None
    Write low_copy(spl) at LOW_OFF; ValueError on any refusal.
verify(image) -> list[str]
    [] iff LOW and HIGH eGON blobs are byte-identical and checksummed.

Checksum convention (Allwinner eGON.BT0)
-----------------------------------------
The 4-byte field at offset 12 is initialised to the sentinel 0x5F0A6C39, then
the u32-LE sum over blob[:length] is computed and stored back at offset 12.
Verification replaces the stored checksum with the sentinel and re-sums.
"""
from __future__ import annotations

import struct
from typing import List

LOW_OFF: int = 0x2000
HIGH_OFF: int = 0x20000
_MAGIC = b"eGON.BT0"
_HEADER = 20  # bytes 0..19: branch(4) + magic(8) + checksum(4) + length(4)
_MAX_LEN = HIGH_OFF - LOW_OFF  # 0x1E000 — must fit between the two slots
_CHECKSUM_SENTINEL = 0x5F0A6C39


def _egon_sum_with_sentinel(blob: bytes, length: int) -> int:
    """Sum all u32 LE words in blob[:length] with offset 12 set to the sentinel."""
    scratch = bytearray(blob[:length])
    struct.pack_into("<I", scratch, 12, _CHECKSUM_SENTINEL)
    return sum(struct.unpack_from(f"<{length // 4}I", scratch, 0)) & 0xFFFFFFFF


def _gpt_first_usable_lba(image: bytes) -> int:
    """Return primary GPT first_usable_lba, or 0 if no valid GPT header."""
    if len(image) < 512 + 92:
        return 0
    if image[512:520] != b"EFI PART":
        return 0
    (first_usable,) = struct.unpack_from("<Q", image, 512 + 40)
    return first_usable


def _gpt_entry_array_range(image: bytes) -> tuple[int, int]:
    """Return (start_byte, end_byte) of the primary GPT entry array, or (0,0)."""
    if len(image) < 512 + 92:
        return (0, 0)
    if image[512:520] != b"EFI PART":
        return (0, 0)
    entries_lba, n_entries, entry_sz = struct.unpack_from("<QII", image, 512 + 72)
    start = entries_lba * 512
    end = start + n_entries * entry_sz
    return (start, end)


def egon_length(spl: bytes) -> int:
    """Return the eGON blob length, or raise ValueError on any sanity failure."""
    if len(spl) < _HEADER:
        raise ValueError("SPL shorter than eGON header")
    if spl[4:12] != _MAGIC:
        raise ValueError("bad eGON magic")
    checksum_stored, length = struct.unpack_from("<II", spl, 12)
    if length < _HEADER:
        raise ValueError(f"eGON length {length} below header size")
    if length > len(spl):
        raise ValueError(f"eGON length {length} exceeds SPL size {len(spl)}")
    if length % 4 != 0:
        raise ValueError(f"eGON length {length} not multiple of 4")
    computed = _egon_sum_with_sentinel(spl, length)
    if computed != checksum_stored:
        raise ValueError(
            f"eGON checksum mismatch: stored=0x{checksum_stored:08x} "
            f"computed=0x{computed:08x}"
        )
    return length


def low_copy(spl: bytes) -> bytes:
    """The eGON blob to copy down to LOW_OFF: spl[:egon_length(spl)]."""
    return spl[: egon_length(spl)]


def apply(image: bytearray, spl: bytes) -> None:
    """Write low_copy(spl) at LOW_OFF; ValueError on any refusal."""
    length = egon_length(spl)  # propagates ValueError for bad magic/checksum/length
    if length > _MAX_LEN:
        raise ValueError(
            f"eGON length 0x{length:x} exceeds max 0x{_MAX_LEN:x} "
            f"(must fit between LOW and HIGH)"
        )
    # GPT entry array must not overlap [LOW_OFF, LOW_OFF+length).
    ent_start, ent_end = _gpt_entry_array_range(image)
    if ent_end > ent_start:
        copy_start, copy_end = LOW_OFF, LOW_OFF + length
        if ent_start < copy_end and ent_end > copy_start:
            raise ValueError(
                f"GPT entry array [0x{ent_start:x},0x{ent_end:x}) overlaps "
                f"copy range [0x{copy_start:x},0x{copy_end:x})"
            )
    # first_usable_lba * 512 must be at or above the end of the copy.
    first_usable = _gpt_first_usable_lba(image)
    if first_usable:
        first_byte = first_usable * 512
        if first_byte < LOW_OFF + length:
            raise ValueError(
                f"first_usable_lba {first_usable} (byte 0x{first_byte:x}) "
                f"inside copy range [0x{LOW_OFF:x},0x{LOW_OFF + length:x})"
            )
    # Target region must be all zero.
    copy = low_copy(spl)
    target = image[LOW_OFF : LOW_OFF + length]
    if any(b != 0 for b in target):
        raise ValueError(
            f"target region [0x{LOW_OFF:x},0x{LOW_OFF + length:x}) not all zero"
        )
    image[LOW_OFF : LOW_OFF + length] = copy


def verify(image: bytes) -> List[str]:
    """Return [] iff LOW and HIGH eGON blobs are byte-identical and checksummed."""
    problems: List[str] = []
    if len(image) < HIGH_OFF + _HEADER:
        return ["image too small for HIGH slot"]
    try:
        hi_len = egon_length(image[HIGH_OFF:])
    except ValueError as e:
        return [f"HIGH eGON invalid: {e}"]
    if len(image) < LOW_OFF + hi_len:
        return ["image too small for LOW slot"]
    low_blob = image[LOW_OFF : LOW_OFF + hi_len]
    hi_blob = image[HIGH_OFF : HIGH_OFF + hi_len]
    if low_blob != hi_blob:
        problems.append("LOW and HIGH eGON blobs differ")
    # Also ensure the low blob individually parses as a valid eGON blob.
    try:
        egon_length(bytes(low_blob))
    except ValueError as e:
        problems.append(f"LOW eGON invalid: {e}")
    return problems


def _cli() -> int:
    """CLI entry point.

    Usage:
        spl_8k_copy.py apply IMAGE_PATH SPL_PATH   # apply low copy + verify
        spl_8k_copy.py verify IMAGE_PATH           # verify only
    """
    import sys

    argv = sys.argv[1:]
    if len(argv) < 1:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[0]
    if cmd == "apply":
        if len(argv) != 3:
            print("usage: spl_8k_copy.py apply IMAGE_PATH SPL_PATH", file=sys.stderr)
            return 2
        image_path, spl_path = argv[1], argv[2]
        with open(image_path, "rb") as f:
            image = bytearray(f.read())
        with open(spl_path, "rb") as f:
            spl = f.read()
        apply(image, spl)
        problems = verify(bytes(image))
        if problems:
            print(
                "spl_8k_copy: verify FAILED after apply: " + "; ".join(problems),
                file=sys.stderr,
            )
            return 1
        with open(image_path, "wb") as f:
            f.write(image)
        return 0
    if cmd == "verify":
        if len(argv) != 2:
            print("usage: spl_8k_copy.py verify IMAGE_PATH", file=sys.stderr)
            return 2
        with open(argv[1], "rb") as f:
            image = f.read()
        problems = verify(image)
        if problems:
            print("verify: " + "; ".join(problems), file=sys.stderr)
            return 1
        print("verify: OK")
        return 0
    print(f"spl_8k_copy: unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
