#!/usr/bin/env python3
"""Generate input-harness report fixtures (stdlib only).

Creates a "good" run directory that a healthy harness run must resemble,
plus mutated negative-control directories that report.py must reject with
specific reason= codes. Used by tests/test-input-harness-selftest.py; the
fixtures are generated, never hand-edited, so schema drift shows up here.

Usage: make_fixtures.py <output-dir>
"""

from __future__ import annotations

import json
import os
import shutil
import struct
import sys
import zlib

SCHEMA = "pf-input-harness.transcript/v1"
PHRASE = "hello harness"
QT_PHRASE = "1234567890"
WIDTH = 1280
HEIGHT = 720

LAUNCHED = (
    "gtk4-text",
    "qt6-text",
    "sdl3-text",
    "sdl2-game",
    "x11-gtk",
    "xim-only",
    "no-im",
    "broken-client",
)


class Builder:
    def __init__(self, client):
        self.client = client
        self.lines = []
        self.t = 0

    def event(self, _event, **fields):
        self.t += 1000
        record = {
            "schema": SCHEMA,
            "client": self.client,
            "seq": len(self.lines) + 1,
            "t_mono_us": self.t,
            "event": _event,
        }
        record.update(fields)
        self.lines.append(record)
        return self

    def write(self, path):
        with open(path, "w", encoding="utf-8") as handle:
            for record in self.lines:
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def commits(builder, text=PHRASE, source="toolkit"):
    for ch in text:
        builder.event("commit", text=ch, source=source)


KEYCODES = {
    "h": 43,
    "e": 26,
    "l": 46,
    "o": 32,
    " ": 65,
    "a": 38,
    "r": 27,
    "n": 57,
    "s": 39,
    "z": 52,
}


def keys(builder, text=PHRASE):
    """Emit the resolved key sequence seen by the real toolkit clients."""
    for ch in text:
        keysym = "space" if ch == " " else ch
        keycode = KEYCODES[ch]
        builder.event("key", keycode=keycode, keysym=keysym, state="pressed", mods=0)
        builder.event("key", keycode=keycode, keysym=keysym, state="released", mods=0)


def make_png(path, width=WIDTH, height=HEIGHT, rgb=(40, 44, 52)):
    raw = bytearray()
    row = bytes(rgb) * width
    for _ in range(height):
        raw.append(0)
        raw.extend(row)

    def chunk(tag, payload):
        return (
            struct.pack(">I", len(payload))
            + tag
            + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
        )

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        handle.write(chunk(b"IEND", b""))


def build_good(out_dir):
    tdir = os.path.join(out_dir, "transcripts")
    sdir = os.path.join(out_dir, "screenshots")
    os.makedirs(tdir, exist_ok=True)
    os.makedirs(sdir, exist_ok=True)

    b = Builder("gtk4-text")
    b.event("start", pid=101, argv=["gtk4-text", "--purpose", "email"], backend="wayland", display="gamescope-0")
    b.event("mapped", width=640, height=480)
    b.event("enter", serial=1)
    b.event("content", source="set", hints=["auto-completion"], purpose="email")
    b.event("im_state", protocol="input-method-v2", state="unavailable")
    b.event("pointer_motion", x=320.0, y=240.0)
    b.event("pointer_button", button=272, state="pressed", x=320.0, y=240.0)
    b.event("pointer_button", button=272, state="released", x=320.0, y=240.0)
    b.event("cursor", name="text")
    keys(b)
    b.event("widget_text", text=PHRASE)
    b.event("leave", serial=2)
    b.event("stop", rc=0)
    b.write(os.path.join(tdir, "gtk4-text.jsonl"))

    b = Builder("qt6-text")
    b.event("start", pid=102, argv=["qt6-text", "--purpose", "digits"], backend="wayland", display="gamescope-0")
    b.event("mapped", width=640, height=480)
    b.event("enter", serial=1)
    b.event("content", source="set", hints=["latin-only"], purpose="digits")
    b.event("im_state", protocol="text-input-v3", state="unavailable")
    commits(b, QT_PHRASE)
    b.event("widget_text", text=QT_PHRASE)
    b.event("stop", rc=0)
    b.write(os.path.join(tdir, "qt6-text.jsonl"))

    b = Builder("sdl3-text")
    b.event("start", pid=103, argv=["sdl3-text"], backend="wayland", display="gamescope-0")
    b.event("mapped", width=1280, height=720)
    b.event("enter", serial=1)
    b.event("content", source="set", hints=["none"], purpose="normal")
    b.event("im_state", protocol="sdl-textinput", state="enabled")
    b.event("screen_keyboard", shown=False)
    commits(b, source="toolkit")
    b.event("widget_text", text=PHRASE)
    b.event("stop", rc=0)
    b.write(os.path.join(tdir, "sdl3-text.jsonl"))

    b = Builder("sdl2-game")
    b.event("start", pid=104, argv=["sdl2-game"], backend="wayland", display="gamescope-0")
    b.event("mapped", width=1280, height=720)
    b.event("enter", serial=1)
    b.event("im_state", protocol="sdl-textinput", state="enabled")
    commits(b, source="toolkit")
    b.event("widget_text", text=PHRASE)
    b.event("stop", rc=0)
    b.write(os.path.join(tdir, "sdl2-game.jsonl"))

    b = Builder("x11-gtk")
    b.event("start", pid=105, argv=["x11-gtk", "--purpose", "url"], backend="x11", display=":0")
    b.event("mapped", width=640, height=480)
    b.event("enter", serial=1)
    b.event("content", source="set", hints=["none"], purpose="url")
    commits(b)
    b.event("widget_text", text=PHRASE)
    b.event("stop", rc=0)
    b.write(os.path.join(tdir, "x11-gtk.jsonl"))

    b = Builder("xim-only")
    b.event("start", pid=106, argv=["xim-only"], backend="x11", display=":0")
    b.event("mapped", width=640, height=480)
    b.event("enter", serial=1)
    b.event("im_state", protocol="xim", state="unavailable")
    keys(b)
    b.event("widget_text", text=PHRASE)
    b.event("stop", rc=0)
    b.write(os.path.join(tdir, "xim-only.jsonl"))

    b = Builder("no-im")
    b.event("start", pid=107, argv=["no-im"], backend="wayland", display="gamescope-0")
    b.event("mapped", width=640, height=480)
    b.event("enter", serial=1)
    keys(b)
    b.event("widget_text", text=PHRASE)
    b.event("stop", rc=0)
    b.write(os.path.join(tdir, "no-im.jsonl"))

    # The negative control: deliberately malformed (seq gap, unknown event,
    # bad field type). report.py must reject it and count that as the
    # negative control firing.
    with open(os.path.join(tdir, "broken-client.jsonl"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps({"schema": SCHEMA, "client": "broken-client", "seq": 1, "t_mono_us": 100, "event": "start", "pid": 108, "argv": ["broken-client"], "backend": "wayland", "display": "gamescope-0"}) + "\n")
        handle.write(json.dumps({"schema": SCHEMA, "client": "broken-client", "seq": 7, "t_mono_us": 200, "event": "teleport", "where": "moon"}) + "\n")
        handle.write(json.dumps({"schema": SCHEMA, "client": "broken-client", "seq": 3, "t_mono_us": 300, "event": "commit", "text": 42, "source": "im"}) + "\n")

    b = Builder("session")
    b.event("start", pid=1, argv=["driver.py"], backend="headless", display="gamescope-0")
    b.event("device_created", kind="pad", name="PocketForge Fake Pad", event_node="/dev/input/event3")
    b.event("device_created", kind="keyboard", name="PocketForge Fake Keyboard", event_node="/dev/input/event4")
    b.event("device_created", kind="mouse", name="PocketForge Fake Mouse", event_node="/dev/input/event5")
    b.event("compositor_ready", pid=50, wayland_display="gamescope-0", x_display=":0", backend="headless")
    for i, client in enumerate(LAUNCHED):
        b.event("client_launch", target=client)
        b.event("screenshot", target=client, path=f"screenshots/{client}.png", type=4, width=WIDTH, height=HEIGHT)
        b.event("client_stop", target=client)
        b.event("client_exit", target=client, rc=0)
    b.event("stop", rc=0)
    b.write(os.path.join(out_dir, "session.jsonl"))

    for client in LAUNCHED:
        make_png(os.path.join(sdir, f"{client}.png"))
    with open(os.path.join(sdir, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(
            [
                {"path": f"screenshots/{client}.png", "type": 4, "width": WIDTH, "height": HEIGHT}
                for client in LAUNCHED
            ],
            handle,
            indent=1,
        )
    return out_dir


def clone(good_dir, name):
    target = os.path.join(os.path.dirname(good_dir), name)
    shutil.copytree(good_dir, target)
    return target


def build_negatives(good_dir):
    """Return {name: (dir, expected_reason)} for report-level negatives."""
    negatives = {}

    d = clone(good_dir, "neg-widget-text")
    path = os.path.join(d, "transcripts", "qt6-text.jsonl")
    records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    stop = records.pop()
    records.append({
        "schema": SCHEMA,
        "client": "qt6-text",
        "seq": 0,
        "t_mono_us": stop["t_mono_us"] - 1,
        "event": "widget_text",
        "text": "",
    })
    records.append(stop)
    for i, record in enumerate(records, start=1):
        record["seq"] = i
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    negatives["neg-widget-text"] = (d, "widget_text_mismatch")

    def write_gtk_raw(directory, text):
        b = Builder("gtk4-text")
        b.event("start", pid=101, argv=["gtk4-text", "--purpose", "email"], backend="wayland", display="gamescope-0")
        b.event("mapped", width=640, height=480)
        b.event("enter", serial=1)
        b.event("content", source="set", hints=["auto-completion"], purpose="email")
        b.event("im_state", protocol="input-method-v2", state="unavailable")
        b.event("pointer_button", button=272, state="pressed", x=320.0, y=240.0)
        b.event("cursor", name="text")
        keys(b, text)
        b.event("stop", rc=0)
        b.write(os.path.join(directory, "transcripts", "gtk4-text.jsonl"))

    d = clone(good_dir, "neg-broken-valid")
    b = Builder("broken-client")
    b.event("start", pid=108, argv=["broken-client"], backend="wayland", display="gamescope-0")
    b.event("stop", rc=0)
    b.write(os.path.join(d, "transcripts", "broken-client.jsonl"))
    negatives["neg-broken-valid"] = (d, "negative_control_not_triggered")

    d = clone(good_dir, "neg-no-commits")
    b = Builder("gtk4-text")
    b.event("start", pid=101, argv=["gtk4-text"], backend="wayland", display="gamescope-0")
    b.event("mapped", width=640, height=480)
    b.event("enter", serial=1)
    b.event("content", source="set", hints=["none"], purpose="email")
    b.event("im_state", protocol="input-method-v2", state="unavailable")
    b.event("pointer_button", button=272, state="pressed", x=1.0, y=1.0)
    b.event("cursor", name="text")
    b.event("stop", rc=0)
    b.write(os.path.join(d, "transcripts", "gtk4-text.jsonl"))
    negatives["neg-no-commits"] = (d, "phrase_not_committed")

    for name, text in (
        ("neg-raw-wrong", "hello harnesz"),
        ("neg-raw-duplicate", "hello  harness"),
        ("neg-raw-missing", "hello harnes"),
        ("neg-raw-reordered", "ehllo harness"),
    ):
        d = clone(good_dir, name)
        write_gtk_raw(d, text)
        negatives[name] = (d, "raw_key_sequence")

    d = clone(good_dir, "neg-client-identity")
    path = os.path.join(d, "transcripts", "qt6-text.jsonl")
    records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    for record in records:
        record["client"] = "gtk4-text"
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    negatives["neg-client-identity"] = (d, "client_mismatch")

    d = clone(good_dir, "neg-client-exit")
    path = os.path.join(d, "session.jsonl")
    records = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
    for record in records:
        if record["event"] == "client_exit" and record["target"] == "qt6-text":
            record["rc"] = 7
    with open(path, "w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record) + "\n")
    negatives["neg-client-exit"] = (d, "client_exit_rc")

    d = clone(good_dir, "neg-corrupt-session")
    with open(os.path.join(d, "session.jsonl"), "a", encoding="utf-8") as handle:
        handle.write("{not json\n")
    negatives["neg-corrupt-session"] = (d, "session_transcript_invalid")

    d = clone(good_dir, "neg-shot-size")
    make_png(os.path.join(d, "screenshots", "gtk4-text.png"), width=640, height=480)
    negatives["neg-shot-size"] = (d, "screenshot_size")

    d = clone(good_dir, "neg-shot-not-png")
    with open(os.path.join(d, "screenshots", "gtk4-text.png"), "wb") as handle:
        handle.write(b"not a png at all")
    negatives["neg-shot-not-png"] = (d, "screenshot_not_png")

    d = clone(good_dir, "neg-no-manifest")
    os.remove(os.path.join(d, "screenshots", "manifest.json"))
    negatives["neg-no-manifest"] = (d, "screenshot_manifest_missing")

    d = clone(good_dir, "neg-unknown-client")
    b = Builder("mystery")
    b.event("start", pid=999, argv=["mystery"], backend="wayland", display="gamescope-0")
    b.event("stop", rc=0)
    b.write(os.path.join(d, "transcripts", "mystery.jsonl"))
    negatives["neg-unknown-client"] = (d, "unknown_client")

    d = clone(good_dir, "neg-client-missing")
    os.remove(os.path.join(d, "transcripts", "qt6-text.jsonl"))
    negatives["neg-client-missing"] = (d, "transcript_missing")

    d = clone(good_dir, "neg-session-missing-device")
    lines = open(os.path.join(d, "session.jsonl"), encoding="utf-8").read().splitlines()
    kept = [ln for ln in lines if '"mouse"' not in ln]
    # renumber seq after dropping a line
    fixed = []
    for i, ln in enumerate(kept, start=1):
        rec = json.loads(ln)
        rec["seq"] = i
        fixed.append(json.dumps(rec))
    with open(os.path.join(d, "session.jsonl"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(fixed) + "\n")
    negatives["neg-session-missing-device"] = (d, "fake_device_missing")

    # A session error event (e.g. a screenshot that never landed) must
    # fail the whole run even when every client transcript looks good.
    d = clone(good_dir, "neg-session-error")
    session_path = os.path.join(d, "session.jsonl")
    records = [
        json.loads(ln)
        for ln in open(session_path, encoding="utf-8").read().splitlines()
        if ln.strip()
    ]
    stop_rec = records.pop()
    records.append(
        {
            "schema": SCHEMA,
            "client": "session",
            "seq": 0,
            "t_mono_us": stop_rec["t_mono_us"] - 1,
            "event": "error",
            "message": "screenshot_timeout: idle not written within 30s",
        }
    )
    records.append(stop_rec)
    for i, rec in enumerate(records, start=1):
        rec["seq"] = i
    with open(session_path, "w", encoding="utf-8") as handle:
        for rec in records:
            handle.write(json.dumps(rec) + "\n")
    negatives["neg-session-error"] = (d, "session_error")

    return negatives


def build_validator_negatives(out_dir):
    """Return [(path, expected_reason)] exercising validate_transcript.py."""
    vdir = os.path.join(out_dir, "validator-negatives")
    os.makedirs(vdir, exist_ok=True)
    cases = []

    def write_case(name, lines, reason):
        path = os.path.join(vdir, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
        cases.append((path, reason))

    def env(client, seq, t, event, **fields):
        rec = {"schema": SCHEMA, "client": client, "seq": seq, "t_mono_us": t, "event": event}
        rec.update(fields)
        return json.dumps(rec)

    start = env("case", 1, 100, "start", pid=1, argv=["case"], backend="wayland", display="gamescope-0")
    stop = env("case", 3, 300, "stop", rc=0)

    write_case("malformed-json.jsonl", [start, "{oops", stop], "malformed_json")
    write_case("seq-gap.jsonl", [start, env("case", 5, 200, "enter", serial=1), stop], "seq_gap")
    write_case("unknown-event.jsonl", [start, env("case", 2, 200, "teleport", where="moon"), env("case", 3, 250, "enter", serial=1), stop], "unknown_event")
    write_case("bad-type.jsonl", [start, env("case", 2, 200, "commit", text=42, source="im"), env("case", 3, 250, "enter", serial=1), stop], "event_field_type")
    write_case("bad-enum.jsonl", [start, env("case", 2, 200, "content", source="set", hints=[], purpose="banana"), env("case", 3, 250, "enter", serial=1), stop], "event_field_value")
    write_case("extra-field.jsonl", [start, env("case", 2, 200, "enter", serial=1, bonus="x"), stop], "event_field")
    write_case("wrong-client.jsonl", [start, env("other", 2, 200, "enter", serial=1), stop], "client_mismatch")
    write_case("stop-not-last.jsonl", [start, stop, env("case", 3, 400, "enter", serial=1)], "stop_not_last")
    write_case("time-regress.jsonl", [start, env("case", 2, 50, "enter", serial=1), stop], "time_regress")
    write_case("bad-schema.jsonl", [json.dumps({"schema": "wrong/v9", "client": "case", "seq": 1, "t_mono_us": 1, "event": "start", "pid": 1, "argv": [], "backend": "wayland", "display": ":0"}), stop], "schema_mismatch")
    return cases


def main(argv):
    if len(argv) != 2:
        print("usage: make_fixtures.py <output-dir>", file=sys.stderr)
        return 2
    root = argv[1]
    good = build_good(os.path.join(root, "good"))
    build_negatives(good)
    build_validator_negatives(root)
    print(f"fixtures written under {root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
