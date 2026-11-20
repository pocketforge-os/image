#!/usr/bin/env python3
"""Hermetic tests for scripts/spl_8k_copy.py (bead tsp-mc9m.60.29.63.20.2).

The owned-spl SD image carries the eGON.BT0 SPL at 128 KiB only; the stock eMMC carries it at 8 KiB and 128 KiB.
spl_8k_copy adds a byte-identical copy of the eGON blob (its own length field) at 0x2000 without touching anything
else, and verifies it. API under test (all pure, no genimage):

  egon_length(spl: bytes) -> int                  ValueError unless magic, checksum and length are sane
  low_copy(spl: bytes) -> bytes                   spl[:egon_length(spl)]
  apply(image: bytearray, spl: bytes) -> None     writes low_copy at LOW_OFF; ValueError on any overlap/refusal
  verify(image: bytes) -> list[str]               [] when LOW and HIGH eGON blobs are identical and checksummed
  LOW_OFF == 0x2000, HIGH_OFF == 0x20000
"""
from __future__ import annotations

import importlib.util
import random
import struct
import sys
import unittest
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MOD = REPO / "scripts" / "spl_8k_copy.py"
STAMP = 0x5F0A6C39
LOW, HIGH = 0x2000, 0x20000


def load():
    spec = importlib.util.spec_from_file_location("spl_8k_copy", MOD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def egon(length: int, total: int, rng: random.Random, *, valid: bool = True) -> bytes:
    blob = bytearray(rng.randbytes(total))
    blob[0:4] = b"\x00\x00\x00\xea"
    blob[4:12] = b"eGON.BT0"
    struct.pack_into("<II", blob, 12, STAMP, length)
    s = sum(struct.unpack_from(f"<{length // 4}I", blob, 0)) & 0xFFFFFFFF
    struct.pack_into("<I", blob, 12, s if valid else (s ^ 1))
    return bytes(blob)


def gpt_image(size: int, spl: bytes, *, entries_lba: int = 160, n: int = 128, esz: int = 128,
              first_usable: int = 1024) -> bytearray:
    """Image with the SPL at HIGH and a primary GPT whose entry array starts at entries_lba."""
    img = bytearray(size)
    img[HIGH:HIGH + len(spl)] = spl
    entries = bytearray(n * esz)
    hdr = bytearray(92)
    hdr[0:8] = b"EFI PART"
    struct.pack_into("<IIII", hdr, 8, 0x00010000, 92, 0, 0)
    struct.pack_into("<QQQQ", hdr, 24, 1, size // 512 - 1, first_usable, size // 512 - 34)
    struct.pack_into("<QIII", hdr, 72, entries_lba, n, esz, zlib.crc32(bytes(entries)) & 0xFFFFFFFF)
    struct.pack_into("<I", hdr, 16, zlib.crc32(bytes(hdr)) & 0xFFFFFFFF)
    img[512:512 + 92] = hdr
    img[entries_lba * 512:entries_lba * 512 + len(entries)] = entries
    return img


class Spl8kCopy(unittest.TestCase):
    def setUp(self) -> None:
        self.m = load()
        self.rng = random.Random(8192)
        self.spl = egon(40960, 0xD8400 - 0x20000 + 0x20000, self.rng)  # eGON blob + FIT-like tail

    def test_offsets(self) -> None:
        self.assertEqual((self.m.LOW_OFF, self.m.HIGH_OFF), (LOW, HIGH))

    def test_low_copy_is_the_egon_blob_only(self) -> None:
        self.assertEqual(self.m.egon_length(self.spl), 40960)
        self.assertEqual(self.m.low_copy(self.spl), self.spl[:40960])

    def test_apply_then_verify_roundtrip_changes_only_the_low_range(self) -> None:
        img = gpt_image(4 << 20, self.spl)
        before = bytes(img)
        self.m.apply(img, self.spl)
        self.assertEqual(bytes(img[LOW:LOW + 40960]), self.spl[:40960])
        self.assertEqual(bytes(img[:LOW]) + bytes(img[LOW + 40960:]),
                         before[:LOW] + before[LOW + 40960:])
        self.assertEqual(self.m.verify(bytes(img)), [])

    def test_verify_negative_control_flipped_byte_in_low_copy(self) -> None:
        img = gpt_image(4 << 20, self.spl)
        self.m.apply(img, self.spl)
        img[LOW + 100] ^= 0xFF
        problems = self.m.verify(bytes(img))
        self.assertTrue(problems, "verify must fail when the 8 KiB copy differs")

    def test_verify_fails_when_low_copy_absent(self) -> None:
        img = gpt_image(4 << 20, self.spl)
        self.assertTrue(self.m.verify(bytes(img)))

    def test_refuses_bad_spl(self) -> None:
        img = gpt_image(4 << 20, self.spl)
        cases = {
            "bad checksum": egon(40960, 60000, self.rng, valid=False),
            "length too big": egon(0x1F000, 0x1F000 + 64, self.rng),
            "length too small": egon(16, 64, self.rng),
            "length not multiple of 4": self.spl[:16] + struct.pack("<I", 40958) + self.spl[20:],
            "bad magic": self.spl[:4] + b"XGON.BT0" + self.spl[12:],
        }
        for name, spl in cases.items():
            with self.subTest(name), self.assertRaises(ValueError):
                self.m.apply(bytearray(img), spl)

    def test_refuses_gpt_entry_array_overlap(self) -> None:
        # entry array at LBA 16 (0x2000) sits inside the copy range
        img = gpt_image(4 << 20, self.spl, entries_lba=16)
        with self.assertRaises(ValueError):
            self.m.apply(img, self.spl)
        # header-adjacent array at LBA 2 (0x400..0x4400) does not overlap 0x2000+ only if n*esz stops short
        img = gpt_image(4 << 20, self.spl, entries_lba=2)
        with self.assertRaises(ValueError):  # 128*128 = 16 KiB array runs 0x400..0x4400 across 0x2000
            self.m.apply(img, self.spl)

    def test_refuses_nonzero_target(self) -> None:
        img = gpt_image(4 << 20, self.spl)
        img[LOW + 5000] = 1
        with self.assertRaises(ValueError):
            self.m.apply(img, self.spl)

    def test_refuses_first_usable_lba_inside_copy(self) -> None:
        img = gpt_image(4 << 20, self.spl, first_usable=40)  # LBA 40 = 0x5000, inside 0x2000..0xC000
        with self.assertRaises(ValueError):
            self.m.apply(img, self.spl)

    def test_apply_is_idempotent_refused(self) -> None:
        img = gpt_image(4 << 20, self.spl)
        self.m.apply(img, self.spl)
        with self.assertRaises(ValueError):  # target no longer zero
            self.m.apply(img, self.spl)


if __name__ == "__main__":
    unittest.main()
