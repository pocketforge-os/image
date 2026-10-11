#!/usr/bin/env python3
"""Verify that an ldd/loader trace resolves the host platform ABI as designed."""

from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import re
from typing import NoReturn


RESOLUTION_RE = re.compile(r"^\s*(\S+)\s+=>\s+(\S+)(?:\s+\(.*\))?\s*$")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"loader-closure=FAIL {message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--platform-prefix", default="/run/pocketforge/platform-runtime")
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        trace = args.trace.read_text(encoding="utf-8")
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"invalid input: {error}")
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        fail("manifest schema_version must be 1")
    sonames = manifest.get("sonames")
    base = manifest.get("base_abi_sonames")
    if not isinstance(sonames, dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in sonames.items()
    ):
        fail("manifest sonames must map strings to strings")
    if not isinstance(base, list) or any(not isinstance(item, str) for item in base):
        fail("manifest base_abi_sonames must be a string array")
    if "not found" in trace:
        fail("trace contains not found")

    resolutions: dict[str, str] = {}
    for line in trace.splitlines():
        match = RESOLUTION_RE.match(line)
        if match:
            resolutions[match.group(1)] = match.group(2)

    prefix = args.platform_prefix.rstrip("/")
    for soname, relative in sorted(sonames.items()):
        path = resolutions.get(soname)
        if path is None:
            fail(f"platform SONAME absent from trace: {soname}")
        expected = f"{prefix}/{PurePosixPath(relative)}"
        if path != expected:
            fail(f"{soname} resolved outside platform runtime: got {path}, expected {expected}")
    for soname in base:
        path = resolutions.get(soname)
        if path is not None and (path == prefix or path.startswith(prefix + "/")):
            fail(f"root ABI SONAME resolved from platform runtime: {soname} => {path}")

    print(f"loader-closure=PASS platform_sonames={len(sonames)} root_abi_sonames={len(base)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
