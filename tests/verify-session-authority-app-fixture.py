#!/usr/bin/env python3
"""Require the real-systemd harness to provide every hard pf-app@ dependency."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
APP_UNIT = ROOT / "rootfs-overlay/etc/systemd/system/pf-app@.service"
CONTAINERFILE = ROOT / "tests/session-authority-systemd/Containerfile"
HARD_DEPENDENCY_KEYS = ("Requires", "BindsTo")
UNIT_NAME = re.compile(r"^[A-Za-z0-9:_.@\-]+\.(?:service|target|socket|path|mount)$")


def fail(message: str) -> None:
    raise SystemExit(f"session-authority app-fixture closure: FAIL: {message}")


def hard_dependencies(path: Path) -> set[str]:
    dependencies: set[str] = set()
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() in HARD_DEPENDENCY_KEYS:
            dependencies.update(word for word in value.split() if UNIT_NAME.fullmatch(word))
    return dependencies


def copied_units(path: Path) -> set[str]:
    units: set[str] = set()
    for match in re.finditer(
        r"^COPY\s+\S+\s+/etc/systemd/system/(\S+)$", path.read_text(), flags=re.MULTILINE
    ):
        name = match.group(1).split("/")[0]
        units.add(name[:-2] if name.endswith(".d") else name)
    return units


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app-unit", type=Path, default=APP_UNIT)
    parser.add_argument("--containerfile", type=Path, default=CONTAINERFILE)
    args = parser.parse_args()

    dependencies = hard_dependencies(args.app_unit)
    provided = copied_units(args.containerfile)
    missing = sorted(dependencies - provided)
    if missing:
        fail(f"hard dependencies absent from {args.containerfile}: {missing}")
    print(
        "session-authority app-fixture closure: PASS "
        f"hard_dependencies={len(dependencies)} provided={len(provided)}"
    )


if __name__ == "__main__":
    main()
