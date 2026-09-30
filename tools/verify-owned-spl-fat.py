#!/usr/bin/env python3
"""Require every owned-SPL payload in the FAT p4 boot-resource image."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess
import sys


REQUIRED = ("Image", "dtb.bin", "initrd.gz", "boot/pocketforge-logo.bmp")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fat_image", type=Path)
    args = parser.parse_args()

    if not args.fat_image.is_file():
        print(
            f"verify-owned-spl-fat.py: FATAL: reason=fat_image_missing path={args.fat_image}",
            file=sys.stderr,
        )
        return 1
    if shutil.which("mdir") is None:
        print("verify-owned-spl-fat.py: FATAL: reason=mdir_missing", file=sys.stderr)
        return 1

    for path in REQUIRED:
        result = subprocess.run(
            ["mdir", "-b", "-i", str(args.fat_image), f"::/{path}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if result.returncode != 0:
            print(
                f"verify-owned-spl-fat.py: FATAL: reason=missing_file path={path}",
                file=sys.stderr,
            )
            return 1
    print("PASS: owned-SPL FAT p4 contains Image, dtb.bin, initrd.gz and boot/pocketforge-logo.bmp")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
