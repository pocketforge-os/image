#!/usr/bin/env python3
"""Guard load-bearing gpu-um-toolchain lines against the pinned upstream recipe."""

from __future__ import annotations

import argparse
import itertools
import re
import sys
from pathlib import Path


ARM64_DESTINATION = "/etc/apt/sources.list.d/ubuntu-arm64.sources"


def stage(text: str, alias: str) -> str:
    match = re.search(
        rf"(?ms)^FROM [^\n]+ AS {re.escape(alias)}\n(.*?)(?=^FROM |\Z)", text
    )
    if not match:
        raise ValueError(f"stage {alias!r} not found")
    return match.group(0)


def base_image(text: str) -> str:
    match = re.search(r"(?m)^FROM\s+(\S+)\s+AS\s+\S+", text)
    if not match:
        raise ValueError("base image line not found")
    return match.group(1)


def logical_lines(text: str) -> list[str]:
    lines: list[str] = []
    current = ""
    for raw in text.splitlines():
        stripped = raw.strip()
        if not current and (not stripped or stripped.startswith("#")):
            continue
        current += (" " if current else "") + stripped.removesuffix("\\").rstrip()
        if not stripped.endswith("\\"):
            lines.append(current)
            current = ""
    if current:
        lines.append(current)
    return lines


def mesa_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in logical_lines(text):
        if not line.startswith("ENV "):
            continue
        for assignment in line.removeprefix("ENV ").split():
            if assignment.startswith("MESA_"):
                name, separator, value = assignment.partition("=")
                if not separator:
                    raise ValueError(f"unsupported ENV MESA_* form: {line}")
                values[name] = value
    return values


def sed_strip(text: str) -> str:
    matches = re.findall(
        r"sed -i\s+(['\"])(.*?)\1\s+/usr/local/src/install-mesa-buildenv\.sh", text
    )
    if len(matches) != 1:
        raise ValueError(f"expected one Mesa buildenv sed strip, found {len(matches)}")
    return matches[0][1]


def arm64_stanza(text: str) -> list[str]:
    blocks = [line for line in logical_lines(text) if ARM64_DESTINATION in line]
    if len(blocks) != 1:
        raise ValueError(f"expected one arm64 sources stanza, found {len(blocks)}")
    values = re.findall(r"'([^']+)'", blocks[0])
    try:
        first = values.index("Types: deb")
        last = next(i for i in range(first, len(values)) if values[i].startswith("Signed-By:"))
    except (ValueError, StopIteration) as error:
        raise ValueError("arm64 sources stanza boundaries not found") from error
    return values[first : last + 1]


def fail(name: str, expected: object, actual: object) -> None:
    print(f"FAIL: {name}: expected {expected!r}, got {actual!r}", file=sys.stderr)


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--dockerfile", type=Path, default=root / "build/Dockerfile.pf")
    parser.add_argument(
        "--fixture",
        type=Path,
        default=root / "build/tests/fixtures/gpu-um-toolchain-0dc9d15a.Dockerfile",
    )
    args = parser.parse_args()

    try:
        actual = stage(args.dockerfile.read_text(), "gpu-um-toolchain")
        expected = stage(args.fixture.read_text(), "toolchain")
        checks = [
            ("base image", base_image(expected), base_image(actual)),
            ("sed strip expression", sed_strip(expected), sed_strip(actual)),
        ]
        expected_env = mesa_env(expected)
        actual_env = mesa_env(actual)
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    failed = False
    for name, wanted, got in checks:
        if wanted != got:
            fail(name, wanted, got)
            failed = True

    for name in sorted(expected_env.keys() | actual_env.keys()):
        wanted = expected_env.get(name, "<missing>")
        got = actual_env.get(name, "<missing>")
        if wanted != got:
            fail(f"ENV {name}", wanted, got)
            failed = True

    expected_stanza = arm64_stanza(expected)
    actual_stanza = arm64_stanza(actual)
    for line_number, (wanted, got) in enumerate(
        itertools.zip_longest(expected_stanza, actual_stanza, fillvalue="<missing>"), 1
    ):
        if wanted != got:
            fail(f"arm64 stanza line {line_number}", wanted, got)
            failed = True

    if failed:
        return 1
    print("PASS: gpu-um-toolchain matches pinned gpu-um-tsp 0dc9d15a load-bearing lines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
