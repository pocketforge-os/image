#!/usr/bin/env python3
"""Remove vendor-era CMA variables from a CRC-protected U-Boot environment."""

import argparse
from pathlib import Path
import re
import struct
import sys
import zlib


def fail(message: str) -> None:
    print(f"A133 env CMA transform FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def env_size(value: str) -> int:
    try:
        parsed = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be an integer such as 0x20000") from exc
    if parsed < 8:
        raise argparse.ArgumentTypeError("must leave room for the environment header and terminator")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--env-size", type=env_size, required=True)
    layout = parser.add_mutually_exclusive_group(required=True)
    layout.add_argument("--env-redundant", dest="redundant", action="store_true")
    layout.add_argument("--env-plain", dest="redundant", action="store_false")
    args = parser.parse_args()

    try:
        image = args.input.read_bytes()
    except OSError as exc:
        fail(f"cannot read {args.input}: {exc}")
    header_size = 5 if args.redundant else 4
    if args.env_size <= header_size + 1:
        fail("environment size leaves no room for a double-NUL terminator")
    if len(image) < args.env_size:
        fail(
            f"input is shorter than the configured environment size "
            f"({len(image)} < {args.env_size})"
        )

    # U-Boot's redundant layout is crc32 + flags + data. Only the configured
    # environment region participates; a partition image may have trailing
    # padding which is outside CONFIG_ENV_SIZE and must remain byte-identical.
    payload = image[header_size : args.env_size]
    calculated = zlib.crc32(payload) & 0xFFFFFFFF
    if image[:4] == struct.pack("<I", calculated):
        byte_order = "<"
    elif image[:4] == struct.pack(">I", calculated):
        byte_order = ">"
    else:
        fail("input CRC is invalid")

    end = payload.find(b"\0\0")
    if end < 0:
        fail("input has no double-NUL environment terminator")
    records = payload[:end].split(b"\0")
    if any(b"=" not in record for record in records):
        fail("input contains a malformed environment record")

    changed = 0
    output_records: list[bytes] = []
    cma_token = re.compile(rb"(?<!\S)cma=[^\s;]*(?:\s+|(?=;|$))")
    for record in records:
        key, value = record.split(b"=", 1)
        if key == b"cma":
            changed += 1
            continue
        cleaned, count = cma_token.subn(b"", value)
        changed += count
        output_records.append(key + b"=" + cleaned)

    if changed == 0:
        fail("input contains no cma= source to remove")
    active = b"\0".join(output_records) + b"\0\0"
    if b"cma=" in active:
        fail("transform left a cma= source in the environment")
    if len(active) > len(payload):
        fail("transformed environment exceeds the input payload size")

    output_payload = active.ljust(len(payload), b"\0")
    output = bytearray(image)
    output[:4] = struct.pack(f"{byte_order}I", zlib.crc32(output_payload) & 0xFFFFFFFF)
    output[header_size : args.env_size] = output_payload
    try:
        args.output.write_bytes(output)
    except OSError as exc:
        fail(f"cannot write {args.output}: {exc}")
    print(f"A133 env CMA transform PASS: removed {changed} cma= sources")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
