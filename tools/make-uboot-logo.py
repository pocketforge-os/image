#!/usr/bin/env python3
"""Create the pinned TG5040 U-Boot logo without external image libraries."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import struct
import sys
import tempfile
import zlib


SOURCE_SHA256 = "ed689555505f644a859f1b7082275935f145ced3d7093e82929ab3701109faed"
SOURCE_WIDTH = 1280
SOURCE_HEIGHT = 720
OUTPUT_WIDTH = 720
OUTPUT_HEIGHT = 1280
BMP_PIXEL_OFFSET = 54
BMP_ROW_STRIDE = (OUTPUT_WIDTH * 3 + 3) & ~3
BMP_IMAGE_SIZE = BMP_ROW_STRIDE * OUTPUT_HEIGHT


class LogoError(Exception):
    """A stable, user-facing conversion or verification failure."""


def fail(reason: str, detail: str) -> LogoError:
    return LogoError(f"reason={reason} {detail}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def paeth(left: int, up: int, upper_left: int) -> int:
    estimate = left + up - upper_left
    left_distance = abs(estimate - left)
    up_distance = abs(estimate - up)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= up_distance and left_distance <= upper_left_distance:
        return left
    if up_distance <= upper_left_distance:
        return up
    return upper_left


def decode_pinned_rgba(data: bytes) -> list[bytes]:
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise fail("png_signature", "source is not a PNG")

    offset = 8
    ihdr = None
    compressed = bytearray()
    saw_iend = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise fail("png_truncated", "chunk header is incomplete")
        length = struct.unpack_from(">I", data, offset)[0]
        chunk_type = data[offset + 4 : offset + 8]
        end = offset + 12 + length
        if end > len(data):
            raise fail("png_truncated", f"chunk {chunk_type!r} is incomplete")
        payload = data[offset + 8 : offset + 8 + length]
        recorded_crc = struct.unpack_from(">I", data, offset + 8 + length)[0]
        actual_crc = zlib.crc32(chunk_type + payload) & 0xFFFFFFFF
        if recorded_crc != actual_crc:
            raise fail("png_crc", f"chunk {chunk_type!r} has a bad CRC")
        if chunk_type == b"IHDR":
            if ihdr is not None or length != 13:
                raise fail("png_ihdr", "IHDR is duplicated or malformed")
            ihdr = struct.unpack(">IIBBBBB", payload)
        elif chunk_type == b"IDAT":
            compressed.extend(payload)
        elif chunk_type == b"IEND":
            saw_iend = True
            if end != len(data):
                raise fail("png_trailing_data", "bytes follow IEND")
            break
        offset = end

    expected_ihdr = (SOURCE_WIDTH, SOURCE_HEIGHT, 8, 6, 0, 0, 0)
    if ihdr != expected_ihdr:
        raise fail("png_format", f"expected RGBA8 {SOURCE_WIDTH}x{SOURCE_HEIGHT}, got {ihdr}")
    if not compressed or not saw_iend:
        raise fail("png_chunks", "IDAT or IEND is missing")

    try:
        filtered = zlib.decompress(bytes(compressed))
    except zlib.error as error:
        raise fail("png_deflate", str(error)) from error
    scanline_size = SOURCE_WIDTH * 4
    expected_size = SOURCE_HEIGHT * (scanline_size + 1)
    if len(filtered) != expected_size:
        raise fail("png_data_size", f"expected {expected_size} bytes, got {len(filtered)}")

    rows: list[bytes] = []
    previous = bytes(scanline_size)
    cursor = 0
    for row_number in range(SOURCE_HEIGHT):
        filter_type = filtered[cursor]
        cursor += 1
        encoded = filtered[cursor : cursor + scanline_size]
        cursor += scanline_size
        decoded = bytearray(scanline_size)
        for index, value in enumerate(encoded):
            left = decoded[index - 4] if index >= 4 else 0
            up = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = up
            elif filter_type == 3:
                predictor = (left + up) // 2
            elif filter_type == 4:
                predictor = paeth(left, up, upper_left)
            else:
                raise fail("png_filter", f"row {row_number} uses filter {filter_type}")
            decoded[index] = (value + predictor) & 0xFF
        current = bytes(decoded)
        rows.append(current)
        previous = current
    return rows


def rotate_clockwise_over_black(source_rows: list[bytes]) -> list[bytes]:
    """Return logical top-down RGB rows for a 90-degree clockwise rotation."""
    output_rows = []
    for output_y in range(OUTPUT_HEIGHT):
        row = bytearray()
        source_x = output_y
        for output_x in range(OUTPUT_WIDTH):
            source_y = SOURCE_HEIGHT - 1 - output_x
            source_offset = source_x * 4
            red, green, blue, alpha = source_rows[source_y][source_offset : source_offset + 4]
            row.extend(
                (
                    (red * alpha + 127) // 255,
                    (green * alpha + 127) // 255,
                    (blue * alpha + 127) // 255,
                )
            )
        output_rows.append(bytes(row))
    return output_rows


def encode_bmp(rows: list[bytes]) -> bytes:
    pixels = bytearray()
    for row in reversed(rows):
        for offset in range(0, len(row), 3):
            red, green, blue = row[offset : offset + 3]
            pixels.extend((blue, green, red))
        pixels.extend(b"\0" * (BMP_ROW_STRIDE - OUTPUT_WIDTH * 3))
    header = struct.pack(
        "<2sIHHI", b"BM", BMP_PIXEL_OFFSET + len(pixels), 0, 0, BMP_PIXEL_OFFSET
    )
    dib = struct.pack(
        "<IiiHHIIiiII",
        40,
        OUTPUT_WIDTH,
        OUTPUT_HEIGHT,
        1,
        24,
        0,
        len(pixels),
        2835,
        2835,
        0,
        0,
    )
    return header + dib + pixels


def parse_bmp_pixels(data: bytes) -> bytes:
    if len(data) < BMP_PIXEL_OFFSET or data[:2] != b"BM":
        raise fail("bmp_signature", "file is not a Windows BMP")
    file_size, pixel_offset = struct.unpack_from("<I4xI", data, 2)
    dib_size, width, height, planes, bpp, compression, image_size = struct.unpack_from(
        "<IiiHHII", data, 14
    )
    if file_size != len(data):
        raise fail("bmp_file_size", f"header={file_size} actual={len(data)}")
    if pixel_offset != BMP_PIXEL_OFFSET or dib_size != 40:
        raise fail("bmp_header", f"pixel_offset={pixel_offset} dib_size={dib_size}")
    if (width, height) != (OUTPUT_WIDTH, OUTPUT_HEIGHT):
        raise fail("bmp_dimensions", f"expected {OUTPUT_WIDTH}x{OUTPUT_HEIGHT}, got {width}x{height}")
    if planes != 1 or bpp != 24:
        raise fail("bmp_format", f"expected planes=1 bpp=24, got planes={planes} bpp={bpp}")
    if compression != 0:
        raise fail("bmp_compression", f"expected BI_RGB=0, got {compression}")
    if image_size != BMP_IMAGE_SIZE or len(data) != BMP_PIXEL_OFFSET + BMP_IMAGE_SIZE:
        raise fail("bmp_image_size", f"header={image_size} expected={BMP_IMAGE_SIZE}")

    logical = bytearray()
    for output_y in range(OUTPUT_HEIGHT):
        stored_y = OUTPUT_HEIGHT - 1 - output_y
        row_start = pixel_offset + stored_y * BMP_ROW_STRIDE
        row = data[row_start : row_start + OUTPUT_WIDTH * 3]
        for offset in range(0, len(row), 3):
            blue, green, red = row[offset : offset + 3]
            logical.extend((red, green, blue))
    return bytes(logical)


def pinned_output(source: Path) -> tuple[bytes, bytes]:
    source_data = source.read_bytes()
    actual_sha = sha256(source_data)
    if actual_sha != SOURCE_SHA256:
        raise fail("source_sha256", f"expected={SOURCE_SHA256} actual={actual_sha}")
    rows = rotate_clockwise_over_black(decode_pinned_rgba(source_data))
    return encode_bmp(rows), b"".join(rows)


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data)
    try:
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        description="create or verify the pinned 720x1280 TG5040 U-Boot BMP"
    )
    parser.add_argument("--verify", action="store_true", help="verify BMP instead of writing it")
    parser.add_argument("source", type=Path, help="pinned frame-000.png")
    parser.add_argument("bmp", type=Path, help="output or existing BMP")
    args = parser.parse_args()

    try:
        expected_bmp, expected_pixels = pinned_output(args.source)
        if args.verify:
            actual_bmp = args.bmp.read_bytes()
            actual_pixels = parse_bmp_pixels(actual_bmp)
            expected_pixel_sha = sha256(expected_pixels)
            actual_pixel_sha = sha256(actual_pixels)
            if actual_pixel_sha != expected_pixel_sha:
                raise fail(
                    "pixel_sha256",
                    f"expected={expected_pixel_sha} actual={actual_pixel_sha}",
                )
            if actual_bmp != expected_bmp:
                raise fail("bmp_bytes", "pixels match but deterministic BMP bytes differ")
            print(
                f"PASS: {args.bmp} is 720x1280 bottom-up 24-bpp BI_RGB "
                f"pixel_sha256={actual_pixel_sha}"
            )
        else:
            write_atomic(args.bmp, expected_bmp)
            print(
                f"wrote {args.bmp} ({len(expected_bmp)} bytes, "
                f"sha256={sha256(expected_bmp)}, pixel_sha256={sha256(expected_pixels)})"
            )
    except (LogoError, OSError) as error:
        print(f"make-uboot-logo.py: FATAL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
