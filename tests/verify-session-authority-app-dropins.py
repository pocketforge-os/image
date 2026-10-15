#!/usr/bin/env python3
"""Allow only environment assignments in pf-app template drop-ins."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
SYSTEMD_ROOT = ROOT / "rootfs-overlay/etc/systemd/system"


class DropinError(ValueError):
    pass


def reject(path: Path, detail: str) -> None:
    raise DropinError(f"APP_DROPIN_NOT_ENV_ONLY {path}: {detail}")


def validate_file(path: Path, display_path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        reject(display_path, "drop-in is not a regular file")

    sections: list[str] = []
    current_section: str | None = None
    environment_lines = 0
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            current_section = line[1:-1]
            sections.append(current_section)
            continue
        if current_section != "Service" or not line.startswith("Environment="):
            reject(display_path, f"line {line_number} is not Environment=: {line}")
        environment_lines += 1

    if sections != ["Service"]:
        reject(display_path, f"sections must be exactly ['Service'], got {sections}")
    if environment_lines == 0:
        reject(display_path, "the Service section has no Environment= lines")


def validate(systemd_root: Path) -> int:
    if systemd_root.is_symlink() or not systemd_root.is_dir():
        reject(Path("."), f"systemd root is not a regular directory: {systemd_root}")
    files = 0
    for directory in sorted(systemd_root.glob("pf-app@*.service.d")):
        if directory.is_symlink() or not directory.is_dir():
            reject(directory.relative_to(systemd_root), "drop-in path is not a regular directory")
        for path in sorted(directory.rglob("*")):
            if path.is_dir() and not path.is_symlink():
                continue
            validate_file(path, path.relative_to(systemd_root))
            files += 1
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--systemd-root", type=Path, default=SYSTEMD_ROOT)
    args = parser.parse_args()
    try:
        count = validate(args.systemd_root)
    except (DropinError, OSError, UnicodeError) as error:
        print(f"session-authority app-dropins: FAIL: {error}", file=sys.stderr)
        return 1
    print(f"session-authority app-dropins: PASS files={count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
