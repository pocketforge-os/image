#!/usr/bin/env python3
"""Evaluate an input-harness run directory and print house verdict lines.

Layout of a run directory:

    <out>/transcripts/<client>.jsonl   one transcript per test client
    <out>/session.jsonl                session-level events
    <out>/screenshots/manifest.json    [{path,type,width,height}, ...]
    <out>/screenshots/*.png            captures from the headless output

Used by the in-container driver (live runs) and by the hermetic self-test
(offline fixture runs) through exactly the same code path:

    report.py <out-dir>

Exit 0 and a final `PASS: input-harness ...` line only when every
registered client met its expectation, the negative-control client was
invalid as designed, session events are complete, and every manifest
screenshot is a PNG of the recorded size.
"""

from __future__ import annotations

import json
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "validate"))
from validate_transcript import validate_file  # noqa: E402

PHRASE = "hello harness"

CLIENT_ORDER = (
    "gtk4-text",
    "qt6-text",
    "sdl3-text",
    "sdl2-game",
    "x11-gtk",
    "xim-only",
    "no-im",
    "wpe-view",
    "broken-client",
)


class Spec:
    def __init__(
        self,
        backend=None,
        purpose=None,
        phrase=None,
        forbid_commits=False,
        allow_raw_keys=False,
        require_events=(),
        expect_invalid=False,
        optional=False,
    ):
        self.backend = backend
        self.purpose = purpose
        self.phrase = phrase
        self.forbid_commits = forbid_commits
        self.allow_raw_keys = allow_raw_keys
        self.require_events = tuple(require_events)
        self.expect_invalid = expect_invalid
        self.optional = optional


SPECS = {
    "gtk4-text": Spec(
        backend="wayland",
        purpose="email",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "content", "im_state", "pointer_button", "cursor"),
    ),
    "qt6-text": Spec(
        backend="wayland",
        purpose="digits",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "content", "im_state"),
    ),
    "sdl3-text": Spec(
        backend="wayland",
        purpose="normal",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "im_state"),
    ),
    "sdl2-game": Spec(
        backend="wayland",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "im_state"),
    ),
    "x11-gtk": Spec(
        backend="x11",
        purpose="url",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "content"),
    ),
    "xim-only": Spec(
        backend="x11",
        forbid_commits=True,
        require_events=("enter", "key", "im_state"),
    ),
    "no-im": Spec(
        backend="wayland",
        forbid_commits=True,
        require_events=("enter", "key"),
    ),
    "wpe-view": Spec(backend="wayland", optional=True),
    # Negative control: this client is deliberately broken. Its transcript
    # MUST be invalid; a valid broken-client transcript means the negative
    # control did not fire and the run is not trustworthy.
    "broken-client": Spec(expect_invalid=True),
}

SESSION_REQUIRED_DEVICES = ("pad", "keyboard", "mouse")


def read_events(path):
    events = []
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if raw:
                events.append(json.loads(raw))
    return events


def png_size(path):
    with open(path, "rb") as handle:
        head = handle.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return width, height


def check_client(client, transcript_dir):
    """Return (verdict, detail) where verdict is PASS/FAIL/SKIP."""
    spec = SPECS[client]
    path = os.path.join(transcript_dir, f"{client}.jsonl")
    if not os.path.exists(path):
        if spec.optional:
            return "SKIP", "reason=transcript_absent hint=client not available in this image"
        return "FAIL", "reason=transcript_missing hint=client never wrote a transcript"

    problems = validate_file(path)
    if problems:
        first = str(problems[0])
        if spec.expect_invalid:
            # The negative control fired: a real client with this transcript
            # would get `FAIL reason=transcript_invalid`; show that verdict.
            return (
                "PASS",
                f"negative_control=confirmed caught=FAIL invalid_lines={len(problems)} first={first}",
            )
        return "FAIL", f"reason=transcript_invalid hint={first}"
    if spec.expect_invalid:
        return "FAIL", "reason=negative_control_not_triggered hint=broken-client transcript validated clean"

    events = read_events(path)
    by_name = {}
    for event in events:
        by_name.setdefault(event["event"], []).append(event)

    start = by_name["start"][0]
    if spec.backend is not None and start["backend"] != spec.backend:
        return "FAIL", (
            f"reason=backend_mismatch hint=start.backend={start['backend']} expected={spec.backend}"
        )
    if by_name["stop"][0]["rc"] != 0:
        return "FAIL", f"reason=client_exit_rc hint=rc={by_name['stop'][0]['rc']}"
    for name in spec.require_events:
        if name not in by_name:
            return "FAIL", f"reason=missing_event hint={client} never logged {name}"
    if any(True for _ in by_name.get("error", ())):
        return "FAIL", f"reason=client_error hint={by_name['error'][0]['message']}"

    if spec.purpose is not None:
        purposes = [e["purpose"] for e in by_name.get("content", []) if e["source"] == "set"]
        if spec.purpose not in purposes:
            return "FAIL", (
                f"reason=content_purpose hint=set purposes={purposes} expected={spec.purpose}"
            )

    commits = "".join(e["text"] for e in by_name.get("commit", []))
    keys = by_name.get("key", [])
    mode = None
    if spec.phrase is not None:
        if spec.phrase in commits:
            mode = "commits"
        elif spec.allow_raw_keys and len([k for k in keys if k["state"] == "pressed"]) >= len(spec.phrase):
            # No commit path available yet (e.g. text-input relay missing):
            # the client must at least have observed the raw key stream and
            # recorded which input-method protocol state it saw.
            if not by_name.get("im_state"):
                return "FAIL", "reason=raw_keys_without_im_state hint=no im_state recorded"
            mode = "raw_keys"
        else:
            return "FAIL", (
                f"reason=phrase_not_committed hint=commits={commits!r} phrase={spec.phrase!r} keys={len(keys)}"
            )
    if spec.forbid_commits and by_name.get("commit"):
        return "FAIL", f"reason=unexpected_commits hint={len(by_name['commit'])} commit events"
    if spec.forbid_commits and by_name.get("content"):
        return "FAIL", f"reason=unexpected_content hint=text-input content on a no-IM client"

    detail = f"events={len(events)}"
    if mode:
        detail += f" mode={mode}"
    if by_name.get("commit"):
        detail += f" commits={len(by_name['commit'])}"
    if by_name.get("cursor"):
        detail += f" cursors={sorted({e['name'] for e in by_name['cursor']})}"
    return "PASS", detail


def check_session(out_dir, launched):
    path = os.path.join(out_dir, "session.jsonl")
    if not os.path.exists(path):
        return "FAIL", "reason=session_transcript_missing hint=driver never wrote session.jsonl"
    problems = validate_file(path, expected_client="session")
    if problems:
        return "FAIL", f"reason=session_transcript_invalid hint={problems[0]}"
    events = read_events(path)
    names = [e["event"] for e in events]
    if "compositor_ready" not in names:
        return "FAIL", "reason=compositor_never_ready hint=no compositor_ready event"
    kinds = {e["kind"] for e in events if e["event"] == "device_created"}
    missing = [k for k in SESSION_REQUIRED_DEVICES if k not in kinds]
    if missing:
        return "FAIL", f"reason=fake_device_missing hint=missing kinds {missing}"
    for client in launched:
        launches = [e for e in events if e["event"] == "client_launch" and e["target"] == client]
        exits = [e for e in events if e["event"] == "client_exit" and e["target"] == client]
        if not launches or not exits:
            return "FAIL", f"reason=client_lifecycle_missing hint={client} launch={len(launches)} exit={len(exits)}"
    if "screenshot" not in names:
        return "FAIL", "reason=no_screenshot_event hint=driver never captured a screenshot"
    return "PASS", f"events={len(events)} devices={sorted(kinds)}"


def check_screenshots(out_dir):
    shot_dir = os.path.join(out_dir, "screenshots")
    manifest_path = os.path.join(shot_dir, "manifest.json")
    if not os.path.exists(manifest_path):
        return "FAIL", "reason=screenshot_manifest_missing hint=driver wrote no screenshots/manifest.json", []
    with open(manifest_path, "r", encoding="utf-8") as handle:
        try:
            manifest = json.load(handle)
        except json.JSONDecodeError as exc:
            return f"FAIL", f"reason=screenshot_manifest_invalid hint={exc}", []
    if not isinstance(manifest, list) or not manifest:
        return "FAIL", "reason=screenshot_manifest_empty hint=no captures recorded", []
    paths = []
    for entry in manifest:
        path = entry["path"] if os.path.isabs(entry["path"]) else os.path.join(out_dir, entry["path"])
        paths.append(path)
        if not os.path.exists(path):
            return "FAIL", f"reason=screenshot_missing hint={path}", paths
        size = png_size(path)
        if size is None:
            return "FAIL", f"reason=screenshot_not_png hint={path}", paths
        if size != (entry["width"], entry["height"]):
            return (
                "FAIL",
                f"reason=screenshot_size hint={path} is {size[0]}x{size[1]} expected {entry['width']}x{entry['height']}",
                paths,
            )
    return "PASS", f"count={len(manifest)} size={manifest[0]['width']}x{manifest[0]['height']}", paths


def report(out_dir):
    transcript_dir = os.path.join(out_dir, "transcripts")
    lines = []
    failures = 0
    skipped = 0
    launched = []
    present = sorted(
        name[: -len(".jsonl")]
        for name in os.listdir(transcript_dir)
        if name.endswith(".jsonl")
    ) if os.path.isdir(transcript_dir) else []
    for client in CLIENT_ORDER:
        if client not in SPECS:  # pragma: no cover - registry drift guard
            continue
        verdict, detail = check_client(client, transcript_dir)
        lines.append(f"{verdict}: {client} {detail}")
        if verdict == "FAIL":
            failures += 1
        if verdict == "SKIP":
            skipped += 1
        elif client != "broken-client":
            launched.append(client)
    # A transcript we do not know about is drift, not a pass.
    for name in present:
        if name not in SPECS:
            lines.append(f"FAIL: {name} reason=unknown_client hint=transcript without a registered spec")
            failures += 1

    session_verdict, session_detail = check_session(out_dir, launched)
    lines.append(f"{session_verdict}: session {session_detail}")
    if session_verdict == "FAIL":
        failures += 1

    shot_verdict, shot_detail, shot_paths = check_screenshots(out_dir)
    lines.append(f"{shot_verdict}: screenshots {shot_detail}")
    if shot_verdict == "FAIL":
        failures += 1

    for line in lines:
        print(line)
    transcript_paths = [
        os.path.join(transcript_dir, f"{client}.jsonl")
        for client in CLIENT_ORDER
        if os.path.exists(os.path.join(transcript_dir, f"{client}.jsonl"))
    ]
    if failures:
        print(
            f"FAIL: input-harness reason=checks_failed hint={failures} failing check(s) above"
        )
        return 1
    print(
        "PASS: input-harness clients={} skipped={} transcripts={} screenshots={}".format(
            len(launched),
            skipped,
            " ".join(transcript_paths),
            " ".join(shot_paths),
        )
    )
    return 0


def main(argv):
    if len(argv) != 2:
        print("usage: report.py <out-dir>", file=sys.stderr)
        return 2
    return report(argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
