#!/usr/bin/env python3
"""Hermetic CLI tests for scripts/spl_8k_copy.py (bead tsp-mc9m.60.29.63.20.2).

Exercises the ``apply`` and ``verify`` subcommands end-to-end on a synthetic
4 MiB image with a valid eGON SPL at 128 KiB, mirroring the build-sd-image.sh
invocation.
"""
from __future__ import annotations

import os
import random
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "scripts" / "spl_8k_copy.py"
STAMP = 0x5F0A6C39
LOW, HIGH = 0x2000, 0x20000


def make_egon(length: int, total: int, rng: random.Random) -> bytes:
    blob = bytearray(rng.randbytes(total))
    blob[0:4] = b"\x00\x00\x00\xea"
    blob[4:12] = b"eGON.BT0"
    struct.pack_into("<II", blob, 12, STAMP, length)
    s = sum(struct.unpack_from(f"<{length // 4}I", blob, 0)) & 0xFFFFFFFF
    struct.pack_into("<I", blob, 12, s)
    return bytes(blob)


def make_image(spl: bytes, size: int = 4 << 20) -> bytearray:
    img = bytearray(size)
    img[HIGH : HIGH + len(spl)] = spl
    return img


class Spl8kCli(unittest.TestCase):
    def setUp(self) -> None:
        self.rng = random.Random(20250924)
        self.spl = make_egon(40960, 0xD8400, self.rng)
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _path(self, name: str) -> str:
        return os.path.join(self.tmp.name, name)

    def test_apply_then_verify_cli(self) -> None:
        img_path = self._path("img.raw")
        spl_path = self._path("spl.bin")
        with open(spl_path, "wb") as f:
            f.write(self.spl)
        with open(img_path, "wb") as f:
            f.write(make_image(self.spl))
        # apply
        r = subprocess.run(
            [sys.executable, str(CLI), "apply", img_path, spl_path],
            capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)
        # verify
        r = subprocess.run(
            [sys.executable, str(CLI), "verify", img_path],
            capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 0, msg=r.stderr)
        self.assertIn("OK", r.stdout)

    def test_verify_fails_without_apply(self) -> None:
        img_path = self._path("img.raw")
        with open(img_path, "wb") as f:
            f.write(make_image(self.spl))
        r = subprocess.run(
            [sys.executable, str(CLI), "verify", img_path],
            capture_output=True, text=True,
        )
        self.assertNotEqual(r.returncode, 0)

    def test_unknown_command(self) -> None:
        r = subprocess.run(
            [sys.executable, str(CLI), "frobnicate"],
            capture_output=True, text=True,
        )
        self.assertEqual(r.returncode, 2)


class BuildSdImageWiring(unittest.TestCase):
    """Static checks that build-sd-image.sh knows about --spl-8k-copy."""

    def setUp(self) -> None:
        self.script = (REPO / "scripts" / "build-sd-image.sh").read_text()

    def test_flag_recognised(self) -> None:
        self.assertIn("--spl-8k-copy", self.script)

    def test_default_off(self) -> None:
        self.assertIn("SPL_8K_COPY=0", self.script)

    def test_requires_owned_spl(self) -> None:
        self.assertIn("--spl-8k-copy requires --boot-chain owned-spl", self.script)

    def test_invokes_spl_8k_copy(self) -> None:
        self.assertIn("spl_8k_copy.py", self.script)
        self.assertIn("apply", self.script)


if __name__ == "__main__":
    unittest.main()
