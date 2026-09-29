#!/usr/bin/env python3
"""Build-time crop of the boot-animation frame set (bd tsp-3rd3.6).

Frames 001..047 differ from frame-000 only inside one small rectangle (the
ember sweep). This tool computes the union of every pixel that differs from
frame-000 across frames 001..047, crops each of those frames to that one
rectangle, and records the rectangle's scene position in a standard PNG
``oFFs`` chunk (unit 0 = pixel) so every cropped file says where it goes.
frame-000 is copied byte-for-byte: it is the full first frame and the u-boot
handoff frame (sha ed689555...), so its bytes must not change.

The animator paints frame-000 in full once and afterwards blits only the
cropped region. Outside the rectangle every frame equals frame-000, which is
what makes the region blit exact; the tool proves that before it writes the
manifest by recomposing every cropped frame over frame-000 and comparing the
result with the original pixels.

Deterministic: pure standard library (zlib, struct, hashlib). The same inputs
and the same zlib build give the same bytes and the same manifest. The image
build runs it inside the pinned build container, which pins zlib.

Usage:
    crop_frames.py --src FRAMES_DIR --out OUT_FRAMES_DIR --manifest FILE

The manifest is sha256sum(1)-compatible ("<sha256>  frames/frame-NNN.png");
its header lines start with '#', which ``sha256sum -c`` skips. It lists the
frame files only, never itself.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
import zlib
from itertools import accumulate

SCENE_W = 1280
SCENE_H = 720
TOTAL_FRAMES = 48
PNG_SIG = b"\x89PNG\r\n\x1a\n"
ZLIB_LEVEL = 9


class FrameError(Exception):
    pass


def _chunks(data: bytes):
    if data[:8] != PNG_SIG:
        raise FrameError("not a PNG")
    pos = 8
    while pos + 12 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if len(body) != length:
            raise FrameError("truncated chunk")
        yield ctype, body
        pos += 12 + length
        if ctype == b"IEND":
            return
    raise FrameError("missing IEND")


def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


# Byte-wise (mod 256, no carry between bytes) add/subtract of two equal-length
# byte strings, done on Python integers so the row loops run at C speed.
def _swar_masks(n: int):
    return int.from_bytes(b"\x7f" * n, "big"), int.from_bytes(b"\x80" * n, "big")


def _swar_add(a: bytes, b: bytes) -> bytes:
    lo, hi = _swar_masks(len(a))
    x, y = int.from_bytes(a, "big"), int.from_bytes(b, "big")
    return (((x & lo) + (y & lo)) ^ ((x ^ y) & hi)).to_bytes(len(a), "big")


def _swar_sub(a: bytes, b: bytes) -> bytes:
    lo, hi = _swar_masks(len(a))
    x, y = int.from_bytes(a, "big"), int.from_bytes(b, "big")
    return (((x | hi) - (y & lo)) ^ ((x ^ ~y) & hi)).to_bytes(len(a), "big")


def _unsub(line: bytes) -> bytes:
    """Invert the PNG Sub filter for 4-byte pixels (per-channel prefix sum)."""
    out = bytearray(len(line))
    for c in range(4):
        out[c::4] = bytes(map((255).__and__, accumulate(line[c::4])))
    return bytes(out)


def decode_png(data: bytes):
    """Decode an 8-bit RGBA, non-interlaced PNG. Returns (w, h, offs, rows).

    ``rows`` is a list of ``bytes`` (w*4 each). ``offs`` is (x, y) from an
    oFFs chunk in pixel units, or None. Anything else fails closed.
    """
    ihdr = None
    offs = None
    idat = bytearray()
    for ctype, body in _chunks(data):
        if ctype == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"oFFs":
            x, y, unit = struct.unpack(">iiB", body)
            if unit != 0 or x < 0 or y < 0:
                raise FrameError("unsupported oFFs")
            offs = (x, y)
        elif ctype == b"IDAT":
            idat += body
    if ihdr is None:
        raise FrameError("missing IHDR")
    w, h, depth, ctype_, comp, filt, interlace = ihdr
    if (depth, ctype_, comp, filt, interlace) != (8, 6, 0, 0, 0):
        raise FrameError(f"unsupported PNG format {ihdr}")
    raw = zlib.decompress(bytes(idat))
    stride = w * 4
    if len(raw) != h * (stride + 1):
        raise FrameError("bad IDAT length")
    rows = []
    prev = bytearray(stride)
    for y in range(h):
        base = y * (stride + 1)
        ftype = raw[base]
        line = bytearray(raw[base + 1:base + 1 + stride])
        if ftype == 1:
            line = bytearray(_unsub(bytes(line)))
        elif ftype == 2:
            line = bytearray(_swar_add(bytes(line), bytes(prev)))
        elif ftype == 3:
            for i in range(stride):
                left = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - 4] if i >= 4 else 0
                upleft = prev[i - 4] if i >= 4 else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 0xFF
        elif ftype != 0:
            raise FrameError(f"bad filter type {ftype}")
        rows.append(bytes(line))
        prev = line
    return w, h, offs, rows


def _chunk(ctype: bytes, body: bytes) -> bytes:
    crc = zlib.crc32(ctype + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + ctype + body + struct.pack(">I", crc)


def _filter_row(line: bytes) -> bytes:
    """PNG Sub filter on every row: deterministic, and on this frame set as
    small as a per-row adaptive choice (measured 85.2 KB vs 86.9 KB over three
    sample frames)."""
    return b"\x01" + _swar_sub(line, bytes(4) + line[:-4])


def encode_png(w: int, h: int, rows, offs=None, level: int = ZLIB_LEVEL) -> bytes:
    raw = bytearray()
    for line in rows:
        raw += _filter_row(line)
    out = PNG_SIG + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    if offs is not None:
        out += _chunk(b"oFFs", struct.pack(">iiB", offs[0], offs[1], 0))
    out += _chunk(b"IDAT", zlib.compress(bytes(raw), level))
    out += _chunk(b"IEND", b"")
    return out


def union_region(base_rows, frames_rows):
    """Bounding box (x, y, w, h) of every pixel differing from base."""
    x0, y0, x1, y1 = SCENE_W, SCENE_H, -1, -1
    for rows in frames_rows:
        for y in range(SCENE_H):
            a, b = rows[y], base_rows[y]
            if a == b:
                continue
            # first and last differing pixel in this row
            lo = next(i for i in range(0, SCENE_W * 4, 4) if a[i:i + 4] != b[i:i + 4]) // 4
            hi = next(i for i in range(SCENE_W * 4 - 4, -1, -4) if a[i:i + 4] != b[i:i + 4]) // 4
            x0, x1 = min(x0, lo), max(x1, hi)
            y0, y1 = min(y0, y), max(y1, y)
    if x1 < 0:
        raise FrameError("frames 001..047 are all identical to frame-000")
    return x0, y0, x1 - x0 + 1, y1 - y0 + 1


def crop(src_dir: str, out_dir: str, manifest: str) -> tuple:
    names = [f"frame-{i:03d}.png" for i in range(TOTAL_FRAMES)]
    raw_src = {}
    for n in names:
        with open(os.path.join(src_dir, n), "rb") as fh:
            raw_src[n] = fh.read()
    decoded = {}
    for n in names:
        w, h, offs, rows = decode_png(raw_src[n])
        if (w, h) != (SCENE_W, SCENE_H) or offs is not None:
            raise FrameError(f"{n}: expected a full {SCENE_W}x{SCENE_H} source frame")
        decoded[n] = rows
    base = decoded[names[0]]
    rx, ry, rw, rh = union_region(base, [decoded[n] for n in names[1:]])

    os.makedirs(out_dir, exist_ok=True)
    outputs = {names[0]: raw_src[names[0]]}
    for n in names[1:]:
        rows = [decoded[n][y][rx * 4:(rx + rw) * 4] for y in range(ry, ry + rh)]
        outputs[n] = encode_png(rw, rh, rows, offs=(rx, ry))

    # Self-check: recompose every cropped frame over frame-000 and require the
    # original pixels back. A crop that loses a changed pixel fails the build.
    for n in names[1:]:
        w, h, offs, rows = decode_png(outputs[n])
        if (w, h, offs) != (rw, rh, (rx, ry)):
            raise FrameError(f"{n}: cropped frame header mismatch")
        for y in range(SCENE_H):
            line = base[y]
            if ry <= y < ry + rh:
                line = line[:rx * 4] + rows[y - ry] + line[(rx + rw) * 4:]
            if line != decoded[n][y]:
                raise FrameError(f"{n}: recomposition differs from the source at row {y}")

    lines = [
        "# pf-boot-anim-frames v1 (bd tsp-3rd3.6; apps/pocketforge-boot-animator/tools/crop_frames.py)",
        f"# scene {SCENE_W}x{SCENE_H}; region x={rx} y={ry} w={rw} h={rh}"
        " = union of frames 001-047 differing from frame-000; frame-000 is full",
        f"# zlib {zlib.ZLIB_RUNTIME_VERSION} level {ZLIB_LEVEL}",
    ]
    for n in names:
        lines.append(f"# source {hashlib.sha256(raw_src[n]).hexdigest()}  {n}")
    for n in names:
        path = os.path.join(out_dir, n)
        with open(path, "wb") as fh:
            fh.write(outputs[n])
        lines.append(f"{hashlib.sha256(outputs[n]).hexdigest()}  frames/{n}")
    with open(manifest, "w", encoding="ascii") as fh:
        fh.write("\n".join(lines) + "\n")
    return rx, ry, rw, rh


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--src", required=True, help="directory with the 48 full frames")
    ap.add_argument("--out", required=True, help="output frames directory")
    ap.add_argument("--manifest", required=True, help="output sha256 manifest path")
    args = ap.parse_args(argv)
    if os.path.realpath(args.manifest).startswith(os.path.realpath(args.out) + os.sep):
        print("crop_frames: the manifest must live outside the frames directory", file=sys.stderr)
        return 2
    try:
        rx, ry, rw, rh = crop(args.src, args.out, args.manifest)
    except (OSError, FrameError, zlib.error) as exc:
        print(f"crop_frames: FAIL: {exc}", file=sys.stderr)
        return 1
    with open(args.manifest, "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()
    print(f"crop_frames: region x={rx} y={ry} w={rw} h={rh} "
          f"({100.0 * rw * rh / (SCENE_W * SCENE_H):.2f}% of the scene) manifest_sha256={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
