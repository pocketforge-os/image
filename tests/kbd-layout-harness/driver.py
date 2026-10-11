#!/usr/bin/env python3
"""Keyboard-layout session driver for headless gamescope (tsp-ihne1.6, AC1).

Runs as gamescope's primary child (inherits WAYLAND_DISPLAY, DISPLAY and
LIBEI_SOCKET). Sequence:

  1. wait for the wayland + EIS sockets
  2. create uinput fake keyboard/mouse and shim their udev seat tags
  3. start the EIS bridge (evdev -> libeis sender -> gamescope), the same
     path a physical USB keyboard takes into the compositor keymap
  4. launch the x11-gtk transcript client, focus it, press one probe key
     (evdev KEY_SEMICOLON, code 39) and wait for the committed text
  5. write /out/result.json with the committed text vs PF_KBD_EXPECT

gamescope translates the key through the XKB keymap built from
XKB_DEFAULT_* (wlserver.cpp), so the committed character is whatever the
keyboardLayout preference selected: 'oe' under de, ';' under us.
Exit 0 when committed == expected, 1 otherwise.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time

OUT = sys.argv[1] if len(sys.argv) > 1 else "/out"
TX_DIR = os.path.join(OUT, "transcripts")
RESULT = os.path.join(OUT, "result.json")
BIN = "/harness/bin"
SESSION_DIR = "/harness/session"
XDG = os.environ.get("XDG_RUNTIME_DIR", "/run/xdg")

EXPECT = os.environ.get("PF_KBD_EXPECT", "")
TOKEN = os.environ.get("PF_KEYBOARD_LAYOUT", "")
SOURCE = os.environ.get("PF_KEYBOARD_LAYOUT_SOURCE", "")
PROBE_KEYCODE = int(os.environ.get("PF_KBD_KEYCODE", "39"))  # KEY_SEMCOLON


def log(msg: str) -> None:
    print(f"[kbd-driver] {msg}", flush=True)


def fail(reason: str, hint: str) -> int:
    print(f"FAIL: kbd-layout-gamescope reason={reason} hint={hint}",
          flush=True)
    write_result(committed=None, passed=False, error=f"{reason}: {hint}")
    return 1


def write_result(committed, passed: bool, error: str | None = None) -> None:
    doc = {
        "token": TOKEN,
        "source": SOURCE,
        "keycode": PROBE_KEYCODE,
        "expected": EXPECT,
        "committed": committed,
        "pass": bool(passed),
    }
    if error:
        doc["error"] = error
    with open(RESULT, "w", encoding="utf-8") as fp:
        json.dump(doc, fp, indent=1)
        fp.write("\n")


def wait_for_socket(name: str, timeout: float) -> str:
    path = os.path.join(XDG, name)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return path
        time.sleep(0.2)
    raise TimeoutError(f"socket {path} did not appear within {timeout}s")


def wait_event_in(tx_path: str, event: str, timeout: float,
                  proc: subprocess.Popen | None = None) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(tx_path):
            with open(tx_path, "r", encoding="utf-8", errors="replace") as fp:
                for line in fp:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if rec.get("event") == event:
                        return True
        if proc is not None and proc.poll() is not None:
            return False
        time.sleep(0.2)
    return False


class FakeInput:
    def __init__(self, kind: str):
        self.kind = kind
        self.proc = subprocess.Popen(
            [os.path.join(BIN, "fake-input"), kind],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        )
        line = self.proc.stdout.readline().strip()
        info = json.loads(line)
        if info.get("kind") != kind or not info.get("event_node"):
            raise RuntimeError(
                f"fake-input {kind} reported bad device line: {line}")
        self.name = info["name"]
        self.node = info["event_node"]
        subprocess.run(
            [os.path.join(SESSION_DIR, "udev-shim.sh"), self.node, kind],
            check=True,
        )
        log(f"fake {kind} at {self.node} ({self.name})")

    def cmd(self, line: str) -> None:
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def destroy(self) -> None:
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


def committed_text(tx_path: str) -> str:
    parts = []
    if not os.path.exists(tx_path):
        return ""
    with open(tx_path, "r", encoding="utf-8", errors="replace") as fp:
        for line in fp:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("event") == "commit":
                parts.append(rec.get("text", ""))
    return "".join(parts)


def main() -> int:
    os.makedirs(TX_DIR, exist_ok=True)
    if not EXPECT:
        return fail("expect_missing", "PF_KBD_EXPECT was not set by entry")
    log(f"token={TOKEN!r} source={SOURCE!r} expect={EXPECT!r} "
        f"keycode={PROBE_KEYCODE}")

    fakes: list[FakeInput] = []
    bridge = None
    client = None
    try:
        wl_name = os.environ.get("WAYLAND_DISPLAY", "gamescope-0")
        wait_for_socket(wl_name, 60)
        eis_path = wait_for_socket(f"{wl_name}-ei", 60)
        log(f"compositor ready: wayland={wl_name} "
            f"x={os.environ.get('DISPLAY', '')}")

        kbd = FakeInput("keyboard")
        mouse = FakeInput("mouse")
        fakes = [kbd, mouse]

        bridge = subprocess.Popen(
            [os.path.join(BIN, "eis-bridge"), eis_path, kbd.node, mouse.node],
            stdout=subprocess.PIPE, text=True,
        )
        deadline = time.monotonic() + 30
        ready = False
        while time.monotonic() < deadline:
            if bridge.poll() is not None:
                raise RuntimeError(
                    f"eis-bridge exited early rc={bridge.returncode}")
            line = bridge.stdout.readline().strip()
            if line == "READY":
                ready = True
                break
            if line:
                log(f"eis-bridge: {line}")
        if not ready:
            return fail("eis_bridge_not_ready",
                        "libeis sender never reached emulating state")

        env = dict(os.environ)
        env["PF_TRANSCRIPT_DIR"] = TX_DIR
        env["PF_TX_PURPOSE"] = "kbd-layout-probe"
        env["GDK_BACKEND"] = "x11"
        client = subprocess.Popen([os.path.join(BIN, "x11-gtk")], env=env)
        tx_path = os.path.join(TX_DIR, "x11-gtk.jsonl")
        if not wait_event_in(tx_path, "mapped", 60, client):
            return fail("client_not_mapped",
                        "x11-gtk never reported a mapped window")

        mouse.cmd("abs 640 360")
        time.sleep(0.3)
        mouse.cmd("btn 272 1")
        time.sleep(0.05)
        mouse.cmd("btn 272 0")
        if not wait_event_in(tx_path, "enter", 30, client):
            return fail("client_not_focused",
                        "x11-gtk never reported keyboard focus")

        time.sleep(0.3)
        kbd.cmd(f"key {PROBE_KEYCODE} 1")
        time.sleep(0.02)
        kbd.cmd(f"key {PROBE_KEYCODE} 0")

        if not wait_event_in(tx_path, "commit", 30, client):
            return fail("no_commit",
                        "probe key produced no committed text in the client")
        time.sleep(0.3)
        committed = committed_text(tx_path)
        log(f"committed={committed!r} expected={EXPECT!r}")
        write_result(committed=committed, passed=committed == EXPECT)
        if committed != EXPECT:
            print("FAIL: kbd-layout-gamescope reason=commit_mismatch "
                  f"hint=committed {committed!r} != expected {EXPECT!r} "
                  f"for token {TOKEN!r}", flush=True)
            return 1
        return 0
    except Exception as exc:  # noqa: BLE001 - driver must always report
        log(f"driver error: {exc}")
        return fail("driver_error", str(exc))
    finally:
        if client is not None and client.poll() is None:
            client.send_signal(signal.SIGTERM)
            try:
                client.wait(timeout=15)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=15)
        for fake in fakes:
            fake.destroy()
        if bridge is not None and bridge.poll() is None:
            bridge.terminate()
            try:
                bridge.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge.kill()
                bridge.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
