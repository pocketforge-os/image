#!/usr/bin/env python3
"""Check that every schema keyboard token is present in shipped XKB data."""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def fail(message: str) -> int:
    print(f"FAIL prefs-schema-xkb: {message}", file=sys.stderr)
    return 1


def evdev_tokens(path: Path) -> set[str]:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise ValueError(f"cannot parse {path}: {error}") from error

    tokens = set()
    for layout in root.iter("layout"):
        name_element = layout.find("configItem/name")
        if name_element is None or not (name_element.text or "").strip():
            continue
        name = name_element.text.split(",", 1)[0].strip()
        tokens.add(name)
        for variant in layout.iter("variant"):
            variant_element = variant.find("configItem/name")
            if variant_element is not None and (variant_element.text or "").strip():
                tokens.add(f"{name}({variant_element.text.strip()})")
    if not tokens:
        raise ValueError(f"{path} lists no XKB layouts")
    return tokens


def main() -> int:
    if len(sys.argv) != 3:
        return fail("usage: verify-prefs-schema-xkb.py EVDEV_XML SCHEMA_JSON")

    evdev_path = Path(sys.argv[1])
    schema_path = Path(sys.argv[2])
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        values = schema["properties"]["keyboardLayout"]["enum"]
        if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
            return fail("keyboardLayout.enum is not a string list")
        schema_values = set(values)
        if len(schema_values) != len(values):
            return fail("keyboardLayout.enum contains duplicates")
        shipped = evdev_tokens(evdev_path)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        return fail(str(error))

    unsupported = sorted(schema_values - shipped)
    if unsupported:
        return fail(
            "keyboardLayout contains values absent from "
            f"{evdev_path}: {', '.join(unsupported)}"
        )
    print(
        "PASS prefs-schema-xkb "
        f"schema_values={len(schema_values)} evdev_values={len(shipped)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
