#!/usr/bin/python3
"""Fail when an image policy names a /run path without an installed producer."""

import argparse
import json
from pathlib import Path
import sys


def load(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"producer-audit: cannot read {path}: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"producer-audit: {path} is not an object")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, action="append", default=[])
    parser.add_argument("--producers", type=Path, required=True)
    args = parser.parse_args()
    manifest = load(args.producers)
    if manifest.get("schema") != "pocketforge.runtime-path-producers/v1":
        raise SystemExit("producer-audit: unsupported producer schema")
    producers = manifest.get("producers", {})
    optional = set(manifest.get("optional", []))
    inventories = list(args.inventory)
    installed = args.root / "usr/share/pocketforge/app-policy"
    if installed.is_dir():
        inventories.extend(sorted(installed.glob("*.resources.json")))
    if not inventories:
        raise SystemExit("producer-audit: no resource inventories were supplied or installed")
    required_set = set()
    for inventory_path in dict.fromkeys(inventories):
        resources = load(inventory_path).get("resources", {})
        required_set.update(
            path for paths in resources.values() for path in paths if path.startswith("/run/")
        )
    required = sorted(required_set)
    errors = []
    for path in required:
        if path in optional:
            continue
        record = producers.get(path)
        if not isinstance(record, dict):
            errors.append(f"missing producer: {path}")
            continue
        unit = record.get("unit")
        if not isinstance(unit, str) or not (args.root / "etc/systemd/system" / unit).is_file():
            errors.append(f"producer unit missing: {path}: {unit}")
    for path, record in producers.items():
        if not path.startswith("/run/") or not isinstance(record, dict):
            errors.append(f"invalid producer record: {path}")
    if errors:
        print("\n".join(f"producer-audit: {error}" for error in errors), file=sys.stderr)
        raise SystemExit(1)
    print(f"runtime-path-producer-audit=PASS required={len(required)}")


if __name__ == "__main__":
    main()
