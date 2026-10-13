#!/usr/bin/env python3
"""Validator for pf-input-harness.transcript/v1 JSONL transcripts.

Stdlib-only. Used both by the in-container driver and by the hermetic
self-test (tests/test-input-harness-selftest.py). Exits 0 when every
checked transcript is valid; on rejection prints `reason=<code> hint=<..>`
lines on stderr and exits 1.
"""

from __future__ import annotations

import json
import sys

SCHEMA = "pf-input-harness.transcript/v1"

BACKENDS = ("wayland", "x11", "headless")
KEY_STATES = ("pressed", "released")
CONTENT_SOURCES = ("set", "protocol")
COMMIT_SOURCES = ("im", "toolkit", "key")
CONTENT_HINTS = (
    "auto-correct",
    "auto-completion",
    "auto-capitalization",
    "hidden",
    "sensitive",
    "latin-only",
    "multiline",
    "none",
)
CONTENT_PURPOSES = (
    "normal",
    "alpha",
    "digits",
    "number",
    "phone",
    "email",
    "url",
    "password",
    "pin",
    "terminal",
    "multiline",
    "unknown",
)
IM_PROTOCOLS = (
    "text-input-v3",
    "input-method-v2",
    "gamescope-input-method",
    "xim",
    "sdl-textinput",
    "none",
)
IM_STATES = ("available", "unavailable", "enabled", "disabled")
AXES = ("vertical", "horizontal")
DEVICE_KINDS = ("pad", "keyboard", "mouse")

_STR = "str"
_INT = "int"
_NUM = "num"
_BOOL = "bool"


def _enum(values):
    return ("enum", values)


def _list_of(kind):
    return ("list", kind)


# Closed field sets per event: every listed field is required, and any
# field not listed is rejected.
EVENTS = {
    "start": {
        "pid": _INT,
        "argv": _list_of(_STR),
        "backend": _enum(BACKENDS),
        "display": _STR,
    },
    "stop": {"rc": _INT},
    "mapped": {"width": _INT, "height": _INT},
    "error": {"message": _STR},
    "enter": {"serial": _INT},
    "leave": {"serial": _INT},
    "key": {
        "keycode": _INT,
        "keysym": _STR,
        "state": _enum(KEY_STATES),
        "mods": _INT,
    },
    "content": {
        "source": _enum(CONTENT_SOURCES),
        "hints": _list_of(_enum(CONTENT_HINTS)),
        "purpose": _enum(CONTENT_PURPOSES),
    },
    "commit": {"text": _STR, "source": _enum(COMMIT_SOURCES)},
    "preedit": {"text": _STR},
    "widget_text": {"text": _STR},
    "im_state": {"protocol": _enum(IM_PROTOCOLS), "state": _enum(IM_STATES)},
    "screen_keyboard": {"shown": _BOOL},
    "pointer_motion": {"x": _NUM, "y": _NUM},
    "pointer_button": {
        "button": _INT,
        "state": _enum(KEY_STATES),
        "x": _NUM,
        "y": _NUM,
    },
    "pointer_axis": {"axis": _enum(AXES), "value": _NUM},
    "cursor": {"name": _STR},
    # Session-level events (session.jsonl)
    "device_created": {
        "kind": _enum(DEVICE_KINDS),
        "name": _STR,
        "event_node": _STR,
    },
    "compositor_ready": {
        "pid": _INT,
        "wayland_display": _STR,
        "x_display": _STR,
        "backend": _STR,
    },
    "client_launch": {"target": _STR},
    "client_stop": {"target": _STR},
    "client_exit": {"target": _STR, "rc": _INT},
    "screenshot": {
        "target": _STR,
        "path": _STR,
        "type": _INT,
        "width": _INT,
        "height": _INT,
    },
}

_ENVELOPE = {
    "schema": _STR,
    "client": _STR,
    "seq": _INT,
    "t_mono_us": _INT,
    "event": _STR,
}


class Problem:
    def __init__(self, reason: str, hint: str):
        self.reason = reason
        self.hint = hint

    def __str__(self) -> str:
        return f"reason={self.reason} hint={self.hint}"


def _check_value(value, kind, where):
    if isinstance(kind, tuple) and kind[0] == "enum":
        if not isinstance(value, str) or value not in kind[1]:
            yield Problem(
                "event_field_value",
                f"{where}: {value!r} not one of {kind[1]}",
            )
        return
    if isinstance(kind, tuple) and kind[0] == "list":
        if not isinstance(value, list):
            yield Problem("event_field_type", f"{where}: expected list")
            return
        for i, item in enumerate(value):
            yield from _check_value(item, kind[1], f"{where}[{i}]")
        return
    if kind == _STR:
        ok = isinstance(value, str)
    elif kind == _INT:
        ok = isinstance(value, int) and not isinstance(value, bool)
    elif kind == _NUM:
        ok = isinstance(value, (int, float)) and not isinstance(value, bool)
    elif kind == _BOOL:
        ok = isinstance(value, bool)
    else:  # pragma: no cover - internal error
        raise AssertionError(f"unknown kind {kind!r}")
    if not ok:
        yield Problem("event_field_type", f"{where}: expected {kind}")


def validate_lines(lines, expected_client=None):
    """Validate an iterable of raw lines. Returns a list of Problem."""
    problems = []
    events = []
    for lineno, raw in enumerate(lines, start=1):
        raw = raw.strip()
        if not raw:
            problems.append(
                Problem("malformed_json", f"line {lineno}: empty line")
            )
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError as exc:
            problems.append(
                Problem("malformed_json", f"line {lineno}: {exc}")
            )
            continue
        if not isinstance(obj, dict):
            problems.append(
                Problem("envelope_field", f"line {lineno}: not a JSON object")
            )
            continue
        envelope_ok = True
        for field, kind in _ENVELOPE.items():
            if field not in obj:
                envelope_ok = False
                problems.append(
                    Problem(
                        "envelope_field",
                        f"line {lineno}: missing {field!r}",
                    )
                )
        if not envelope_ok:
            events.append(None)
            continue
        if obj.get("schema") != SCHEMA:
            problems.append(
                Problem(
                    "schema_mismatch",
                    f"line {lineno}: schema {obj.get('schema')!r} != {SCHEMA!r}",
                )
            )
        if obj.get("seq") != lineno:
            problems.append(
                Problem(
                    "seq_gap",
                    f"line {lineno}: seq {obj.get('seq')!r} != line number {lineno}",
                )
            )
        if (
            expected_client is not None
            and obj.get("client") != expected_client
        ):
            problems.append(
                Problem(
                    "client_mismatch",
                    f"line {lineno}: client {obj.get('client')!r} != {expected_client!r}",
                )
            )
        name = obj.get("event")
        if name not in EVENTS:
            problems.append(
                Problem("unknown_event", f"line {lineno}: event {name!r}")
            )
            events.append(None)
            continue
        spec = EVENTS[name]
        extra = set(obj) - set(_ENVELOPE) - set(spec)
        if extra:
            problems.append(
                Problem(
                    "event_field",
                    f"line {lineno}: {name}: unexpected fields {sorted(extra)}",
                )
            )
        for field, kind in spec.items():
            if field not in obj:
                problems.append(
                    Problem(
                        "event_field",
                        f"line {lineno}: {name}: missing {field!r}",
                    )
                )
                continue
            problems.extend(
                _check_value(obj[field], kind, f"line {lineno}: {name}.{field}")
            )
        events.append(obj)
    real = [e for e in events if e is not None]
    if len(real) >= 2:
        for prev, cur in zip(real, real[1:]):
            if cur["t_mono_us"] < prev["t_mono_us"]:
                problems.append(
                    Problem(
                        "time_regress",
                        f"seq {cur['seq']}: t_mono_us went backwards",
                    )
                )
                break
    if not real:
        problems.append(Problem("empty_transcript", "no valid events at all"))
        return problems
    if real[0].get("event") != "start":
        problems.append(Problem("start_not_first", "first event is not start"))
    if real[-1].get("event") != "stop":
        problems.append(Problem("stop_not_last", "last event is not stop"))
    if any(e.get("event") == "start" for e in real[1:]):
        problems.append(Problem("duplicate_start", "duplicate start event"))
    return problems


def validate_file(path, expected_client=None):
    with open(path, "r", encoding="utf-8") as handle:
        return validate_lines(handle, expected_client=expected_client)


def main(argv):
    if len(argv) < 2:
        print("usage: validate_transcript.py <file.jsonl> [...]", file=sys.stderr)
        return 2
    failed = False
    for path in argv[1:]:
        expected = None
        if path.endswith(".jsonl"):
            stem = path.rsplit("/", 1)[-1][: -len(".jsonl")]
            if stem != "session":
                expected = stem
        problems = validate_file(path, expected_client=expected)
        if problems:
            failed = True
            print(f"FAIL: {path}", file=sys.stderr)
            for problem in problems:
                print(f"  {problem}", file=sys.stderr)
        else:
            print(f"PASS: {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
