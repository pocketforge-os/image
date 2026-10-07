#!/usr/bin/env python3
"""Reject cmdline CMA overrides when an A133 DTB owns the default CMA pool."""

import argparse
from pathlib import Path
import re
import struct
import subprocess
import sys
import zlib


class GuardError(Exception):
    pass


def read_required(path: Path) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise GuardError(f"cannot read {path}: {exc}") from exc
    if not data:
        raise GuardError(f"{path} is empty")
    return data


def dtb_has_default_cma(path: Path) -> bool:
    read_required(path)
    try:
        result = subprocess.run(
            ["dtc", "-I", "dtb", "-O", "dts", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as exc:
        raise GuardError("dtc is required to inspect the shipped DTB") from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or f"exit {exc.returncode}"
        raise GuardError(f"cannot decode {path}: {detail}") from exc

    stack: list[str] = []
    for raw_line in result.stdout.splitlines():
        line = raw_line.strip()
        node = re.match(r"^([^/][^=;{]*)\s*\{$", line)
        if node:
            stack.append(node.group(1).strip())
            continue
        if line == "};":
            if stack:
                stack.pop()
            continue
        if line == "linux,cma-default;" and any(
            name.split("@", 1)[0] == "reserved-memory" for name in stack
        ):
            return True
    return False


def read_cmdline(path: Path) -> str:
    try:
        text = read_required(path).decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise GuardError(f"{path} is not UTF-8 text") from exc
    if not text.startswith("cmdline="):
        raise GuardError(f"{path} must contain one abootimg cmdline= record")
    if "\n" in text:
        raise GuardError(f"{path} must contain exactly one cmdline= record")
    return text.removeprefix("cmdline=")


def read_uboot_bootargs(path: Path) -> str:
    try:
        text = read_required(path).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise GuardError(f"{path} is not UTF-8 text") from exc
    matches = re.findall(r'^CONFIG_BOOTARGS="([^"]*)"$', text, re.MULTILINE)
    if len(matches) != 1:
        raise GuardError(f"{path} must contain exactly one CONFIG_BOOTARGS value")
    return matches[0]


def env_contains_cma(path: Path) -> bool:
    image = read_required(path)
    if len(image) < 8:
        raise GuardError(f"{path} is too short to be a CRC-protected U-Boot environment")
    payload = image[4:]
    stored = image[:4]
    calculated = zlib.crc32(payload) & 0xFFFFFFFF
    if stored not in (struct.pack("<I", calculated), struct.pack(">I", calculated)):
        raise GuardError(f"{path} has an invalid U-Boot environment CRC")
    end = payload.find(b"\0\0")
    if end < 0:
        raise GuardError(f"{path} has no double-NUL environment terminator")
    active = payload[: end + 1]
    for entry in active.split(b"\0"):
        if entry and b"=" not in entry:
            raise GuardError(f"{path} contains a malformed environment record")
    return b"cma=" in active


def contains_cma(bootargs: str) -> bool:
    return re.search(r"(?:^|\s)cma=", bootargs) is not None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dtb", type=Path, required=True)
    parser.add_argument("--cmdline", type=Path, required=True)
    parser.add_argument("--env-img", type=Path, required=True)
    parser.add_argument("--uboot-config", type=Path)
    args = parser.parse_args()

    try:
        has_default_cma = dtb_has_default_cma(args.dtb)
        sources = [(str(args.cmdline), contains_cma(read_cmdline(args.cmdline)))]
        if args.uboot_config is not None:
            sources.append(
                (
                    str(args.uboot_config),
                    contains_cma(read_uboot_bootargs(args.uboot_config)),
                )
            )
        sources.append((str(args.env_img), env_contains_cma(args.env_img)))
    except GuardError as exc:
        print(f"A133 CMA guard ERROR: {exc}", file=sys.stderr)
        return 2

    offenders = [name for name, present in sources if present]
    if has_default_cma and offenders:
        print(
            "A133 CMA guard FAIL: shipped DTB declares linux,cma-default but "
            f"cma= is present in {', '.join(offenders)}",
            file=sys.stderr,
        )
        return 1
    print(
        "A133 CMA guard PASS: "
        + ("DT-owned default CMA has no cmdline override" if has_default_cma else "DTB has no linux,cma-default constraint")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
