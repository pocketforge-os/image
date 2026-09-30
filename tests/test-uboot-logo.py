#!/usr/bin/env python3
"""Hermetic positive and negative controls for the owned-SPL U-Boot logo."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "apps/pocketforge-boot-animator/frames/frame-000.png"
CONVERTER = ROOT / "tools/make-uboot-logo.py"
FAT_VERIFY = ROOT / "tools/verify-owned-spl-fat.py"
BUILD_SCRIPT = ROOT / "scripts/build-sd-image.sh"

EXPECTED_SOURCE_SHA256 = "ed689555505f644a859f1b7082275935f145ced3d7093e82929ab3701109faed"
# Fixed by the converter contract. These are deliberately literals rather than
# values imported from the implementation, so output drift makes this test red.
EXPECTED_BMP_SHA256 = "5e7ff600d20967fcf0bbb80a5479dcabca48ca18ee3e05b1feaa9df9870978e7"
EXPECTED_PIXEL_SHA256 = "f63de5a9350b01f33ac130b0afa4eb2fdb7751cc5210b31e22e92b77aa8d5c99"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(*args: os.PathLike[str] | str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [os.fspath(arg) for arg in args],
        check=False,
        capture_output=True,
        text=True,
    )


def parse_bmp(data: bytes) -> tuple[dict[str, int], list[bytes]]:
    if len(data) < 54 or data[:2] != b"BM":
        raise AssertionError("not a Windows BMP")
    file_size, pixel_offset = struct.unpack_from("<I4xI", data, 2)
    (dib_size, width, height, planes, bpp, compression, image_size) = struct.unpack_from(
        "<IiiHHII", data, 14
    )
    row_stride = (width * 3 + 3) & ~3
    if width <= 0 or height <= 0:
        raise AssertionError("test parser expects a bottom-up BMP")
    rows = []
    for output_y in range(height):
        stored_y = height - 1 - output_y
        row = data[
            pixel_offset + stored_y * row_stride : pixel_offset + stored_y * row_stride + width * 3
        ]
        rows.append(b"".join(row[x + 2 : x + 3] + row[x + 1 : x + 2] + row[x : x + 1]
                             for x in range(0, len(row), 3)))
    return {
        "file_size": file_size,
        "pixel_offset": pixel_offset,
        "dib_size": dib_size,
        "width": width,
        "height": height,
        "planes": planes,
        "bpp": bpp,
        "compression": compression,
        "image_size": image_size,
        "row_stride": row_stride,
    }, rows


def encode_bmp(rows: list[bytes]) -> bytes:
    height = len(rows)
    width = len(rows[0]) // 3
    row_stride = (width * 3 + 3) & ~3
    pixels = bytearray()
    for row in reversed(rows):
        for offset in range(0, len(row), 3):
            red, green, blue = row[offset : offset + 3]
            pixels.extend((blue, green, red))
        pixels.extend(b"\0" * (row_stride - width * 3))
    header = struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
    dib = struct.pack(
        "<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(pixels), 2835, 2835, 0, 0
    )
    return header + dib + pixels


class UBootLogoTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="pf-uboot-logo-")
        self.work = Path(self.tempdir.name)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def convert(self, source: Path, output: Path) -> subprocess.CompletedProcess[str]:
        return run(sys.executable, "-B", CONVERTER, source, output)

    def verify(self, source: Path, bmp: Path) -> subprocess.CompletedProcess[str]:
        return run(sys.executable, "-B", CONVERTER, "--verify", source, bmp)

    def test_positive_is_deterministic_pinned_bottom_up_bi_rgb(self) -> None:
        self.assertEqual(sha256(SOURCE.read_bytes()), EXPECTED_SOURCE_SHA256)
        first = self.work / "first.bmp"
        second = self.work / "second.bmp"
        for output in (first, second):
            result = self.convert(SOURCE, output)
            self.assertEqual(result.returncode, 0, result.stderr)

        data = first.read_bytes()
        self.assertEqual(data, second.read_bytes())
        self.assertEqual(sha256(data), EXPECTED_BMP_SHA256)
        facts, rows = parse_bmp(data)
        self.assertEqual(
            facts,
            {
                "file_size": len(data),
                "pixel_offset": 54,
                "dib_size": 40,
                "width": 720,
                "height": 1280,
                "planes": 1,
                "bpp": 24,
                "compression": 0,
                "image_size": 720 * 1280 * 3,
                "row_stride": 720 * 3,
            },
        )
        self.assertEqual(sha256(b"".join(rows)), EXPECTED_PIXEL_SHA256)
        verified = self.verify(SOURCE, first)
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_negative_wrong_source_sha_is_refused(self) -> None:
        wrong = self.work / "wrong.png"
        damaged = bytearray(SOURCE.read_bytes())
        damaged[-1] ^= 1
        wrong.write_bytes(damaged)
        result = self.convert(wrong, self.work / "must-not-exist.bmp")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("reason=source_sha256", result.stderr)

    def test_negative_wrong_orientation_and_compression_are_refused(self) -> None:
        good = self.work / "good.bmp"
        result = self.convert(SOURCE, good)
        self.assertEqual(result.returncode, 0, result.stderr)
        _, rows = parse_bmp(good.read_bytes())

        # A 180-degree turn of the clockwise native image is the same source
        # transformed counter-clockwise. Its dimensions/format stay valid, so
        # rejection proves the pixel-orientation digest is load-bearing.
        wrong_orientation = self.work / "counter-clockwise.bmp"
        wrong_orientation.write_bytes(
            encode_bmp([b"".join(reversed([row[x : x + 3] for x in range(0, len(row), 3)]))
                        for row in reversed(rows)])
        )
        rejected = self.verify(SOURCE, wrong_orientation)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("reason=pixel_sha256", rejected.stderr)

        compressed = self.work / "compressed.bmp"
        bad_header = bytearray(good.read_bytes())
        struct.pack_into("<I", bad_header, 30, 1)
        compressed.write_bytes(bad_header)
        rejected = self.verify(SOURCE, compressed)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("reason=bmp_compression", rejected.stderr)

    @unittest.skipUnless(
        all(shutil.which(tool) for tool in ("mkdosfs", "mlabel", "mmd", "mcopy", "mdir")),
        "dosfstools or mtools not installed",
    )
    def test_missing_fat_logo_fails_and_present_logo_passes(self) -> None:
        fat = self.work / "boot-resource.vfat"
        formatted = subprocess.run(
            [
                "bash",
                str(ROOT / "scripts/make-reproducible-vfat.sh"),
                str(fat),
                "64",
                "POCKETFORGE",
                "50464F52",
            ],
            check=False,
            capture_output=True,
            text=True,
            env=dict(os.environ, SOURCE_DATE_EPOCH="1700000000"),
        )
        self.assertEqual(formatted.returncode, 0, formatted.stderr)
        self.assertEqual(run("mmd", "-i", fat, "::/boot").returncode, 0)
        for name in ("Image", "dtb.bin", "initrd.gz"):
            fixture = self.work / name
            fixture.write_bytes(name.encode("ascii"))
            copied = run("mcopy", "-i", fat, fixture, f"::/{name}")
            self.assertEqual(copied.returncode, 0, copied.stderr)

        missing = run(sys.executable, "-B", FAT_VERIFY, fat)
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("reason=missing_file path=boot/pocketforge-logo.bmp", missing.stderr)

        logo = self.work / "pocketforge-logo.bmp"
        converted = self.convert(SOURCE, logo)
        self.assertEqual(converted.returncode, 0, converted.stderr)
        copied = run("mcopy", "-i", fat, logo, "::/boot/pocketforge-logo.bmp")
        self.assertEqual(copied.returncode, 0, copied.stderr)
        present = run(sys.executable, "-B", FAT_VERIFY, fat)
        self.assertEqual(present.returncode, 0, present.stderr)

    def test_owned_spl_builder_wires_conversion_staging_and_verification(self) -> None:
        script = BUILD_SCRIPT.read_text(encoding="utf-8")
        owned = script[script.index('if [ "${BOOT_CHAIN}" = "owned-spl" ]; then',
                                    script.index("# Owned-SPL boot payload")) :]
        converter = 'python3 "${TOOLS_DIR}/make-uboot-logo.py"'
        stage = '"::/boot/pocketforge-logo.bmp"'
        verifier = 'python3 "${TOOLS_DIR}/verify-owned-spl-fat.py"'
        self.assertIn(converter, owned)
        self.assertIn(stage, owned)
        self.assertIn(verifier, owned)
        self.assertLess(owned.index(converter), owned.index(stage))
        self.assertLess(owned.index(stage), owned.index(verifier))


if __name__ == "__main__":
    unittest.main(verbosity=2)
