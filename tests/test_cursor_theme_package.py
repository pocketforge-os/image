#!/usr/bin/env python3
from __future__ import annotations

import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "scripts/verify-cursor-theme.py"
INSTALL = ROOT / "scripts/install-cursor-theme.sh"
THEMES = ("pocketforge-light", "pocketforge-dark")
SIZES = (32, 48, 64, 96, 128)
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


def xcursor() -> bytes:
    ntoc = len(SIZES)
    pos = 16 + 12 * ntoc
    tocs, chunks = [], []
    for size in SIZES:
        tocs.append(struct.pack("<III", 0xFFFD0002, size, pos))
        chunk = struct.pack("<IIIIIIIII", 36, 0xFFFD0002, size, 1, 1, 1, 0, 0, 0) + b"\0\0\0\xff"
        chunks.append(chunk)
        pos += len(chunk)
    return struct.pack("<4sIII", b"Xcur", 16, 0x10000, ntoc) + b"".join(tocs + chunks)


def fixture(root: Path) -> None:
    for theme in THEMES:
        cursor_dir = root / "usr/share/icons" / theme / "cursors"
        cursor_dir.mkdir(parents=True)
        (cursor_dir.parent / "index.theme").write_text("[Icon Theme]\nName=PocketForge\n")
        (cursor_dir.parent / "cursor.theme").write_text("[Icon Theme]\nInherits=default\n")
        for canonical, aliases in ALIASES.items():
            (cursor_dir / canonical).write_bytes(xcursor())
            for alias in aliases:
                (cursor_dir / alias).symlink_to(canonical)
    license_dir = root / "usr/share/licenses/pocketforge-cursor-theme"
    license_dir.mkdir(parents=True)
    (license_dir / "LICENSE").write_text("CC BY-SA 4.0\n")
    (license_dir / "ATTRIBUTION.md").write_text("phisch/phinger-cursors d8196cd\n")
    provenance = root / "usr/share/pocketforge/cursor-theme.provenance"
    provenance.parent.mkdir(parents=True)
    provenance.write_text("source_sha=dbeaa3c4ac5726e0dd81efd6846ca67a7c6a74d6\n")
    for path in sorted(root.rglob("*"), reverse=True):
        if path.is_symlink():
            continue
        path.chmod(0o555 if path.is_dir() else 0o444)


class CursorPackage(unittest.TestCase):
    def run_verify(self, root: Path, *extra: str, ok: bool = True) -> None:
        result = subprocess.run(["python3", str(VERIFY), str(root), *extra], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode == 0, ok, result.stdout)

    def test_docker_stage_is_pinned_offline_and_reproducible(self) -> None:
        text = (ROOT / "build/Dockerfile.pf").read_text()
        digest = "10.0.32.86:5555/pocketforge/ci-tools@sha256:2ff536627228c90e5c32b7d6345b21600a38a17481c075b41683db47ead3e862"
        self.assertIn(f"ARG PF_CURSOR_TOOLS_IMAGE={digest}", text)
        self.assertIn("ARG PF_CURSOR_TOOLS_RECIPE_SHA=22b8c9feb04565c9ee84858687ed30455da7ed58", text)
        start = text.index("FROM ${PF_CURSOR_TOOLS_IMAGE} AS cursor-theme")
        end = text.index("\nFROM ", start + 6)
        stage = text[start:end]
        self.assertIn("COPY --from=cursor-theme-src", stage)
        self.assertIn("RUN --network=none", stage)
        self.assertIn("build-a", stage)
        self.assertIn("build-b", stage)
        self.assertIn("diff -r", stage)
        for forbidden in ("apt-get", "pip install", "git clone", "curl ", "wget "):
            self.assertNotIn(forbidden, stage)
        unit = (ROOT / "rootfs-overlay/etc/systemd/system/pf-app@.service").read_text()
        self.assertIn("Environment=XCURSOR_THEME=pocketforge-light", unit)
        self.assertIn("Environment=XCURSOR_SIZE=48", unit)

    def test_install_and_failure_controls(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-cursor-test.") as td:
            base = Path(td)
            producer = base / "producer"
            rootfs = base / "rootfs"
            fixture(producer)
            subprocess.run([str(INSTALL), str(producer), str(rootfs)], check=True)
            self.run_verify(rootfs, "--require-env")
            env = (rootfs / "etc/environment").read_text().splitlines()
            self.assertIn("XCURSOR_THEME=pocketforge-light", env)
            self.assertIn("XCURSOR_SIZE=48", env)
            self.assertFalse(any(p.stat().st_mode & 0o222 for p in rootfs.glob("usr/share/icons/pocketforge-*/*") if not p.is_symlink()))

            missing = base / "missing"
            shutil.copytree(producer, missing, symlinks=True)
            victim = missing / "usr/share/icons/pocketforge-light/cursors/default"
            victim.parent.chmod(0o755); victim.unlink()
            self.run_verify(missing, ok=False)

            wrong_alias = base / "wrong-alias"
            shutil.copytree(producer, wrong_alias, symlinks=True)
            link = wrong_alias / "usr/share/icons/pocketforge-dark/cursors/left_ptr"
            link.parent.chmod(0o755)
            link.unlink(); link.symlink_to("pointer")
            self.run_verify(wrong_alias, ok=False)

            writable = base / "writable"
            shutil.copytree(producer, writable, symlinks=True)
            (writable / "usr/share/icons/pocketforge-light/cursors/default").chmod(0o644)
            self.run_verify(writable, ok=False)

            no_attribution = base / "no-attribution"
            shutil.copytree(producer, no_attribution, symlinks=True)
            docs = no_attribution / "usr/share/licenses/pocketforge-cursor-theme"
            docs.chmod(0o755); (docs / "ATTRIBUTION.md").unlink()
            self.run_verify(no_attribution, ok=False)

            wrong_sizes = base / "wrong-sizes"
            shutil.copytree(producer, wrong_sizes, symlinks=True)
            cursor = wrong_sizes / "usr/share/icons/pocketforge-dark/cursors/default"
            cursor.chmod(0o644); cursor.write_bytes(b"Xcur" + b"\0" * 12)
            cursor.chmod(0o444)
            self.run_verify(wrong_sizes, ok=False)


if __name__ == "__main__":
    unittest.main()
