#!/usr/bin/env python3
"""Reject cmdline CMA overrides when an A133 DTB owns the default CMA pool."""

import argparse
from pathlib import Path
import re
import struct
import sys
import zlib


class GuardError(Exception):
    pass


def env_size(value: str) -> int:
    try:
        parsed = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer such as 0x20000") from exc
    if parsed < 8:
        raise argparse.ArgumentTypeError("must leave room for the environment header and terminator")
    return parsed


def read_required(path: Path) -> bytes:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise GuardError(f"cannot read {path}: {exc}") from exc
    if not data:
        raise GuardError(f"{path} is empty")
    return data


def dtb_has_default_cma(path: Path) -> bool:
    image = read_required(path)
    if len(image) < 40:
        raise GuardError(f"{path} is too short to be a flattened device tree")
    header = struct.unpack_from(">10I", image)
    magic, total_size, struct_offset, strings_offset = header[:4]
    strings_size, struct_size = header[8:10]
    if magic != 0xD00DFEED:
        raise GuardError(f"{path} has an invalid flattened device tree magic")
    if total_size > len(image) or total_size < 40:
        raise GuardError(f"{path} has an invalid flattened device tree size")
    if (
        struct_offset > total_size
        or struct_size > total_size - struct_offset
        or strings_offset > total_size
        or strings_size > total_size - strings_offset
    ):
        raise GuardError(f"{path} has an out-of-bounds flattened device tree block")

    structure = image[struct_offset : struct_offset + struct_size]
    strings = image[strings_offset : strings_offset + strings_size]
    stack: list[str] = []
    offset = 0
    saw_end = False
    has_default_cma = False
    while offset + 4 <= len(structure):
        token = struct.unpack_from(">I", structure, offset)[0]
        offset += 4
        if token == 1:  # FDT_BEGIN_NODE
            end = structure.find(b"\0", offset)
            if end < 0:
                raise GuardError(f"{path} has an unterminated node name")
            try:
                stack.append(structure[offset:end].decode("ascii"))
            except UnicodeDecodeError as exc:
                raise GuardError(f"{path} has a non-ASCII node name") from exc
            offset = (end + 4) & ~3
            continue
        if token == 2:  # FDT_END_NODE
            if not stack:
                raise GuardError(f"{path} has an unmatched end-node token")
            stack.pop()
            continue
        if token == 3:  # FDT_PROP
            if offset + 8 > len(structure):
                raise GuardError(f"{path} has a truncated property header")
            value_size, name_offset = struct.unpack_from(">II", structure, offset)
            offset += 8
            if value_size > len(structure) - offset:
                raise GuardError(f"{path} has a truncated property value")
            if name_offset >= len(strings):
                raise GuardError(f"{path} has an invalid property-name offset")
            name_end = strings.find(b"\0", name_offset)
            if name_end < 0:
                raise GuardError(f"{path} has an unterminated property name")
            try:
                name = strings[name_offset:name_end].decode("ascii")
            except UnicodeDecodeError as exc:
                raise GuardError(f"{path} has a non-ASCII property name") from exc
            offset = (offset + value_size + 3) & ~3
            if name == "linux,cma-default" and any(
                node.split("@", 1)[0] == "reserved-memory" for node in stack
            ):
                has_default_cma = True
            continue
        if token == 4:  # FDT_NOP
            continue
        if token == 9:  # FDT_END
            if stack:
                raise GuardError(f"{path} ends with unclosed nodes")
            saw_end = True
            break
        raise GuardError(f"{path} has unknown flattened device tree token {token}")
    if not saw_end:
        raise GuardError(f"{path} has no flattened device tree end token")
    return has_default_cma


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


def env_contains_cma(path: Path, configured_size: int, redundant: bool) -> bool:
    image = read_required(path)
    header_size = 5 if redundant else 4
    if configured_size <= header_size + 1:
        raise GuardError(
            f"configured environment size {configured_size} leaves no room for a double-NUL terminator"
        )
    if len(image) < configured_size:
        raise GuardError(
            f"{path} is shorter than the configured U-Boot environment size "
            f"({len(image)} < {configured_size})"
        )
    payload = image[header_size:configured_size]
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
    parser.add_argument("--env-size", type=env_size, required=True)
    layout = parser.add_mutually_exclusive_group(required=True)
    layout.add_argument("--env-redundant", dest="redundant", action="store_true")
    layout.add_argument("--env-plain", dest="redundant", action="store_false")
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
        sources.append(
            (
                str(args.env_img),
                env_contains_cma(args.env_img, args.env_size, args.redundant),
            )
        )
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
