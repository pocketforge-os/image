#!/usr/bin/env python3
"""Validate the immutable PocketForge Xcursor payload."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import struct
import sys

THEMES = ("pocketforge-light", "pocketforge-dark")
SIZES = {32, 48, 64, 96, 128}
ALIASES = {
    "default": ("arrow", "left_ptr", "top_left_arrow"),
    "context-menu": (), "help": ("question_arrow", "whats_this", "left_ptr_help", "dnd-help"),
    "pointer": ("hand2", "pointing_hand", "hand"),
    "progress": ("left_ptr_watch", "half-busy", "08e8e1c95fe2fc01f976f1e063a24ccd"),
    "wait": ("watch",), "cell": ("plus",),
    "crosshair": ("cross", "cross_reverse", "diamond_cross", "tcross", "target"),
    "text": ("xterm", "ibeam"), "vertical-text": (), "alias": ("link", "dnd-link"),
    "copy": ("dnd-copy",), "move": ("fleur", "size_all", "dnd-move"),
    "no-drop": ("dnd-no-drop", "forbidden"), "not-allowed": ("crossed_circle", "circle"),
    "grab": ("hand1", "openhand"), "grabbing": ("dnd-none", "closedhand"),
    "e-resize": ("right_side",), "n-resize": ("top_side",),
    "ne-resize": ("top_right_corner",), "nw-resize": ("top_left_corner",),
    "s-resize": ("bottom_side",), "se-resize": ("bottom_right_corner",),
    "sw-resize": ("bottom_left_corner",), "w-resize": ("left_side",),
    "ew-resize": ("sb_h_double_arrow", "size_hor", "h_double_arrow"),
    "ns-resize": ("sb_v_double_arrow", "size_ver", "v_double_arrow"),
    "nesw-resize": ("fd_double_arrow", "size_bdiag"),
    "nwse-resize": ("bd_double_arrow", "size_fdiag"),
    "col-resize": ("split_h", "sb_h_double_arrow_split"), "row-resize": ("split_v",),
    "all-scroll": (), "zoom-in": (), "zoom-out": (), "dnd-ask": (), "all-resize": (),
}


def fail(message: str) -> None:
    raise ValueError(message)


def sizes(path: Path) -> set[int]:
    data = path.read_bytes()
    if len(data) < 16 or data[:4] != b"Xcur":
        fail(f"invalid Xcursor header: {path}")
    header, _version, count = struct.unpack_from("<III", data, 4)
    if header < 16 or header + count * 12 > len(data):
        fail(f"invalid Xcursor table: {path}")
    found = set()
    for index in range(count):
        kind, subtype, offset = struct.unpack_from("<III", data, header + index * 12)
        if kind == 0xFFFD0002:
            if offset + 36 > len(data):
                fail(f"truncated Xcursor image: {path}")
            found.add(subtype)
    return found


def readonly(path: Path) -> None:
    if path.lstat().st_mode & 0o222:
        fail(f"writable payload path: {path}")


def verify(root: Path, require_env: bool) -> None:
    expected_names = set(ALIASES)
    expected_names.update(alias for aliases in ALIASES.values() for alias in aliases)
    for theme in THEMES:
        theme_dir = root / "usr/share/icons" / theme
        cursor_dir = theme_dir / "cursors"
        if not cursor_dir.is_dir() or cursor_dir.is_symlink():
            fail(f"missing theme directory: {theme}")
        actual = {path.name for path in cursor_dir.iterdir()}
        if actual != expected_names:
            fail(f"cursor name set differs for {theme}: missing={sorted(expected_names-actual)} extra={sorted(actual-expected_names)}")
        for canonical, aliases in ALIASES.items():
            cursor = cursor_dir / canonical
            if not cursor.is_file() or cursor.is_symlink():
                fail(f"canonical cursor is not a regular file: {cursor}")
            if sizes(cursor) != SIZES:
                fail(f"cursor sizes differ for {cursor}: {sorted(sizes(cursor))}")
            readonly(cursor)
            for alias in aliases:
                link = cursor_dir / alias
                if not link.is_symlink() or os.readlink(link) != canonical:
                    fail(f"alias differs: {link} -> {os.readlink(link) if link.is_symlink() else '<not-link>'}")
        for path in (theme_dir, cursor_dir, theme_dir / "index.theme", theme_dir / "cursor.theme"):
            if not path.exists():
                fail(f"missing theme metadata: {path}")
            readonly(path)
        for path in theme_dir.rglob("*"):
            if not path.is_symlink():
                readonly(path)
    license_dir = root / "usr/share/licenses/pocketforge-cursor-theme"
    for name in ("LICENSE", "ATTRIBUTION.md"):
        path = license_dir / name
        if not path.is_file() or path.is_symlink():
            fail(f"missing licensing file: {path}")
        readonly(path)
    attribution = (license_dir / "ATTRIBUTION.md").read_text()
    if "phinger-cursors" not in attribution or "d8196cd" not in attribution:
        fail("attribution does not identify the upstream snapshot")
    provenance = root / "usr/share/pocketforge/cursor-theme.provenance"
    if not provenance.is_file():
        fail("cursor provenance is missing")
    readonly(provenance)
    if require_env:
        env = (root / "etc/environment").read_text().splitlines()
        if "XCURSOR_THEME=pocketforge-light" not in env or "XCURSOR_SIZE=48" not in env:
            fail("Xcursor session environment is missing")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--require-env", action="store_true")
    args = parser.parse_args()
    try:
        verify(args.root, args.require_env)
    except (OSError, ValueError, struct.error) as error:
        print(f"cursor-theme verify: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
