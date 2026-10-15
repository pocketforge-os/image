#!/usr/bin/env python3
"""Evaluate one GTK keyboard-layout scenario transcript exactly."""

from __future__ import annotations

import json
import os
import sys


def evaluate_transcript(path: str, expected: str):
    if not os.path.isfile(path):
        return False, "layout_transcript_missing", ""
    actual = ""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for raw in handle:
                record = json.loads(raw)
                if record.get("event") == "widget_text":
                    actual = record.get("text", "")
    except (OSError, ValueError, TypeError):
        return False, "layout_transcript_invalid", actual
    if actual != expected:
        return False, "layout_widget_text_mismatch", actual
    return True, "ok", actual


def main(argv):
    if len(argv) != 4:
        print("usage: layout_scenario.py TRANSCRIPT EXPECTED LABEL", file=sys.stderr)
        return 2
    passed, reason, actual = evaluate_transcript(argv[1], argv[2])
    if not passed:
        print(
            f"FAIL: layout-scenario label={argv[3]} reason={reason} "
            f"expected={argv[2]!r} actual={actual!r} transcript={argv[1]}"
        )
        return 1
    print(
        f"PASS: layout-scenario label={argv[3]} expected={argv[2]!r} "
        f"actual={actual!r} transcript={argv[1]}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
