#!/usr/bin/env python3
"""Derive the live VM's non-production policy from the real image contract."""

import copy
import os
from pathlib import Path
import sys
import tempfile
import tomllib


def fail(message: str) -> "None":
    raise SystemExit(f"make-nonproduction-platform: FAIL: {message}")


if len(sys.argv) != 3:
    fail("usage: make-nonproduction-platform.py INPUT OUTPUT")

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
if source == destination:
    fail("input and output must differ")
if source.is_symlink() or not source.is_file():
    fail("input must be a regular non-symlink file")

text = source.read_text(encoding="utf-8")
try:
    production = tomllib.loads(text)
except tomllib.TOMLDecodeError as error:
    fail(f"input is not TOML: {error}")

required = {
    "schema_version": 2,
    "production": True,
    "landlock_mode": "required",
    "landlock_full_min_abi": 10,
    "landlock_browser_min_abi": 6,
}
for key, expected in required.items():
    if production.get(key) != expected:
        fail(f"production contract has {key}={production.get(key)!r}, expected {expected!r}")

production_line = "production = true"
landlock_line = 'landlock_mode = "required"'
if text.splitlines().count(production_line) != 1:
    fail("production declaration is not canonical")
if text.splitlines().count(landlock_line) != 1:
    fail("Landlock declaration is not canonical")

rendered = text.replace(production_line, "production = false").replace(
    landlock_line, 'landlock_mode = "best_effort"'
)
try:
    live = tomllib.loads(rendered)
except tomllib.TOMLDecodeError as error:
    fail(f"derived output is not TOML: {error}")

expected_live = copy.deepcopy(production)
expected_live["production"] = False
expected_live["landlock_mode"] = "best_effort"
if live != expected_live:
    fail("derived contract changed fields beyond the two test-only declarations")

destination.parent.mkdir(parents=True, exist_ok=True)
temporary_name = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=destination.parent,
        prefix=f".{destination.name}.",
        delete=False,
    ) as temporary:
        temporary_name = temporary.name
        temporary.write(rendered)
        temporary.flush()
        os.fsync(temporary.fileno())
    os.chmod(temporary_name, 0o644)
    os.replace(temporary_name, destination)
    temporary_name = None
finally:
    if temporary_name is not None:
        Path(temporary_name).unlink(missing_ok=True)

print("make-nonproduction-platform: PASS changed=production,landlock_mode")
