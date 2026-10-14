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
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "validate"))
from validate_transcript import validate_file  # noqa: E402

PHRASE = "hello harness"
QT_PHRASE = "1234567890"

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
        widget_phrase=None,
    ):
        self.backend = backend
        self.purpose = purpose
        self.phrase = phrase
        self.forbid_commits = forbid_commits
        self.allow_raw_keys = allow_raw_keys
        self.require_events = tuple(require_events)
        self.expect_invalid = expect_invalid
        self.optional = optional
        self.widget_phrase = widget_phrase


SPECS = {
    "gtk4-text": Spec(
        backend="wayland",
        purpose="email",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "content", "im_state", "pointer_button", "cursor"),
        widget_phrase=PHRASE,
    ),
    "qt6-text": Spec(
        backend="wayland",
        purpose="digits",
        phrase=QT_PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "content", "im_state"),
        widget_phrase=QT_PHRASE,
    ),
    "sdl3-text": Spec(
        backend="wayland",
        purpose="normal",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "im_state"),
        widget_phrase=PHRASE,
    ),
    "sdl2-game": Spec(
        backend="wayland",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "im_state"),
        widget_phrase=PHRASE,
    ),
    "x11-gtk": Spec(
        backend="x11",
        purpose="url",
        phrase=PHRASE,
        allow_raw_keys=True,
        require_events=("enter", "content"),
        widget_phrase=PHRASE,
    ),
    "xim-only": Spec(
        backend="x11",
        forbid_commits=True,
        require_events=("enter", "key", "im_state"),
        widget_phrase=PHRASE,
    ),
    "no-im": Spec(
        backend="wayland",
        forbid_commits=True,
        require_events=("enter", "key"),
        widget_phrase=PHRASE,
    ),
    "wpe-view": Spec(backend="wayland", optional=True),
    # Negative control: this client is deliberately broken. Its transcript
    # MUST be invalid; a valid broken-client transcript means the negative
    # control did not fire and the run is not trustworthy.
    "broken-client": Spec(expect_invalid=True),
}

SESSION_REQUIRED_DEVICES = ("pad", "keyboard", "mouse")
TEXT_REGIONS = {
    # GtkEntry's outer bounds are approximately x=187..1092, y=359..407
    # in the fixed 1280x720 harness layout. Keep this region inside its
    # padding so focus-ring and border-only repaints cannot satisfy the gate.
    "gtk4-text": (204, 369, 1076, 398),
    "qt6-text": (190, 340, 1090, 420),
    "sdl3-text": (220, 290, 1050, 410),
    "sdl2-game": (220, 290, 1050, 410),
    "x11-gtk": (190, 320, 1090, 420),
    "xim-only": (200, 300, 1050, 410),
    "no-im": (200, 290, 1050, 410),
}
MIN_FRAME_CHANGE = {
    # Toolkit fields use their native fonts, so a modest floor is sufficient.
    "gtk4-text": (128, 32),
    "qt6-text": (128, 48),
    "x11-gtk": (128, 32),
    # These clients render the source-owned glyph atlas at a known scale. A
    # single stale first glyph is roughly 46 px wide; the complete phrase is
    # hundreds of pixels wide, so require evidence across the whole line.
    "sdl3-text": (2048, 300),
    "sdl2-game": (2048, 300),
    "no-im": (2048, 300),
    # The pure-Xlib XIM control uses XDrawString's compact server font rather
    # than the glyph atlas. Its full phrase is 117 px wide on the hermetic
    # Xwayland server, so retain enough tolerance for font rasterization while
    # still rejecting a partial first-glyph/short-prefix frame.
    "xim-only": (512, 96),
}


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


def png_rgb(path):
    """Decode an 8-bit, non-interlaced RGB/RGBA PNG using stdlib only."""
    with open(path, "rb") as handle:
        png = handle.read()
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos = 8
    width = height = bpp = 0
    compressed = bytearray()
    while pos + 12 <= len(png):
        length = struct.unpack(">I", png[pos:pos + 4])[0]
        kind = png[pos + 4:pos + 8]
        data = png[pos + 8:pos + 8 + length]
        if len(data) != length:
            return None
        if kind == b"IHDR":
            width, height, depth, color, comp, filt, interlace = struct.unpack(
                ">IIBBBBB", data)
            if depth != 8 or color not in (2, 6) or (comp, filt, interlace) != (0, 0, 0):
                return None
            bpp = 3 if color == 2 else 4
        elif kind == b"IDAT":
            compressed.extend(data)
        elif kind == b"IEND":
            break
        pos += length + 12
    if width <= 0 or height <= 0 or bpp == 0:
        return None
    try:
        raw = zlib.decompress(compressed)
    except zlib.error:
        return None
    stride = width * bpp
    if len(raw) != height * (stride + 1):
        return None
    rows = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        encoded = raw[offset + 1:offset + 1 + stride]
        offset += stride + 1
        if filter_type == 0:
            decoded = bytearray(encoded)
        else:
            decoded = bytearray(stride)
            for i, value in enumerate(encoded):
                left = decoded[i - bpp] if i >= bpp else 0
                up = previous[i]
                upper_left = previous[i - bpp] if i >= bpp else 0
                if filter_type == 1:
                    predictor = left
                elif filter_type == 2:
                    predictor = up
                elif filter_type == 3:
                    predictor = (left + up) // 2
                elif filter_type == 4:
                    p = left + up - upper_left
                    pa, pb, pc = abs(p - left), abs(p - up), abs(p - upper_left)
                    predictor = left if pa <= pb and pa <= pc else up if pb <= pc else upper_left
                else:
                    return None
                decoded[i] = (value + predictor) & 0xff
        if bpp == 3:
            rows.append(bytes(decoded))
        else:
            rows.append(bytes(channel for i, channel in enumerate(decoded) if i % 4 != 3))
        previous = decoded
    return width, height, rows


def frame_change(before_path, after_path, region):
    before = png_rgb(before_path)
    after = png_rgb(after_path)
    if before is None or after is None or before[:2] != after[:2]:
        return None
    width, height = before[:2]
    x0, y0, x1, y1 = region
    if not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height):
        return None
    changed = 0
    min_x = x1
    max_x = x0 - 1
    for y in range(y0, y1):
        brow, arow = before[2][y], after[2][y]
        for x in range(x0, x1):
            i = x * 3
            if sum(abs(brow[i + c] - arow[i + c]) for c in range(3)) >= 48:
                changed += 1
                min_x = min(min_x, x)
                max_x = max(max_x, x)
    span_x = 0 if changed == 0 else max_x - min_x + 1
    return changed, span_x


def check_client(client, transcript_dir):
    """Return (verdict, detail) where verdict is PASS/FAIL/SKIP."""
    spec = SPECS[client]
    path = os.path.join(transcript_dir, f"{client}.jsonl")
    if not os.path.exists(path):
        if spec.optional:
            return "SKIP", "reason=transcript_absent hint=client not available in this image"
        return "FAIL", "reason=transcript_missing hint=client never wrote a transcript"

    problems = validate_file(path, expected_client=client)
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
        elif spec.allow_raw_keys and any(k["state"] == "pressed" for k in keys):
            # No commit path available yet (e.g. text-input relay missing).
            # Resolve the exact ordered press stream; a count alone lets a
            # wrong, duplicated, missing, or reordered phrase pass.
            raw_symbols = []
            for key in keys:
                if key["state"] != "pressed":
                    continue
                symbol = key["keysym"].casefold()
                if symbol == "space":
                    symbol = " "
                raw_symbols.append(symbol)
            raw_phrase = "".join(raw_symbols)
            if raw_phrase != spec.phrase:
                return "FAIL", (
                    f"reason=raw_key_sequence hint=keys={raw_phrase!r} expected={spec.phrase!r}"
                )
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
    if spec.widget_phrase is not None:
        widget_events = by_name.get("widget_text", [])
        actual = widget_events[-1]["text"] if widget_events else None
        if actual != spec.widget_phrase:
            return "FAIL", (
                f"reason=widget_text_mismatch hint=widget_text={actual!r} expected={spec.widget_phrase!r}"
            )

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
    errors = [e for e in events if e["event"] == "error"]
    if errors:
        return "FAIL", f"reason=session_error hint={errors[0]['message']}"
    if "compositor_ready" not in names:
        return "FAIL", "reason=compositor_never_ready hint=no compositor_ready event"
    kinds = {e["kind"] for e in events if e["event"] == "device_created"}
    missing = [k for k in SESSION_REQUIRED_DEVICES if k not in kinds]
    if missing:
        return "FAIL", f"reason=fake_device_missing hint=missing kinds {missing}"
    expected = set(launched)
    lifecycle_targets = {
        e["target"] for e in events
        if e["event"] in ("client_launch", "client_stop", "client_exit")
    }
    unexpected = sorted(lifecycle_targets - expected)
    if unexpected:
        return "FAIL", f"reason=client_lifecycle_unexpected hint=targets={unexpected}"
    for client in launched:
        launches = [e for e in events if e["event"] == "client_launch" and e["target"] == client]
        exits = [e for e in events if e["event"] == "client_exit" and e["target"] == client]
        stops = [e for e in events if e["event"] == "client_stop" and e["target"] == client]
        shots = [e for e in events if e["event"] == "screenshot" and e["target"] == client]
        if len(launches) != 1 or len(stops) != 1 or len(exits) != 1:
            return "FAIL", f"reason=client_lifecycle_missing hint={client} launch={len(launches)} stop={len(stops)} exit={len(exits)}"
        if exits[0]["rc"] != 0:
            return "FAIL", f"reason=client_exit_rc hint={client} rc={exits[0]['rc']}"
        expected_phases = ("before", "after") if client in TEXT_REGIONS else ("after",)
        phase_map = {shot["phase"]: shot for shot in shots}
        ordered = [phase_map.get(phase) for phase in expected_phases]
        if (len(shots) != len(expected_phases) or any(shot is None for shot in ordered)
                or any(shot["seq"] >= stops[0]["seq"] for shot in shots)
                or any(ordered[i]["seq"] >= ordered[i + 1]["seq"]
                       for i in range(len(ordered) - 1))):
            return "FAIL", (
                f"reason=screenshot_after_stop hint={client} screenshot_seq="
                f"{[(e['phase'], e['seq']) for e in shots]} stop_seq={stops[0]['seq']}"
            )
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
    by_target_phase = {}
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
        key = (entry.get("target"), entry.get("phase"))
        if key in by_target_phase:
            return "FAIL", f"reason=screenshot_duplicate hint={key}", paths
        by_target_phase[key] = path
    for client, region in TEXT_REGIONS.items():
        before = by_target_phase.get((client, "before"))
        after = by_target_phase.get((client, "after"))
        if before is None or after is None:
            return "FAIL", f"reason=frame_pair_missing hint={client}", paths
        change = frame_change(before, after, region)
        if change is None:
            return "FAIL", f"reason=frame_region_invalid hint={client} region={region}", paths
        changed, span_x = change
        min_pixels, min_span_x = MIN_FRAME_CHANGE[client]
        if changed < min_pixels or span_x < min_span_x:
            return (
                "FAIL",
                f"reason=stale_frame hint={client} changed_pixels={changed} minimum_pixels={min_pixels} "
                f"changed_span_x={span_x} minimum_span_x={min_span_x} region={region}",
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
        else:
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
