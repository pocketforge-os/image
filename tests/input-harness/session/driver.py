#!/usr/bin/env python3
"""Headless gamescope session driver for the PocketForge input harness.

Runs as gamescope's primary child (inherits WAYLAND_DISPLAY, DISPLAY and
LIBEI_SOCKET). Sequence:

  1. wait for the wayland + EIS sockets
  2. create uinput fake pad/keyboard/mouse and shim their udev seat tags
  3. start the EIS bridge (evdev -> libeis sender -> gamescope)
  4. take an idle screenshot, then run every test client in turn:
     launch -> wait mapped -> focus click -> type PHRASE -> screenshot -> SIGTERM
  5. always run the deliberately broken client last-but-one (negative control)
  6. write session.jsonl, chown /out to the host user, run report.py

Exit code is report.py's exit code.
"""

from __future__ import annotations

import json
import os
import signal
import struct
import subprocess
import sys
import time

PHRASE = "hello harness"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/out"
TX_DIR = os.path.join(OUT, "transcripts")
SHOT_DIR = os.path.join(OUT, "screenshots")
SESSION_TX = os.path.join(OUT, "session.jsonl")
BIN = "/harness/bin"
SESSION_DIR = "/harness/session"
PRELOAD = "/harness/lib/libpf-transcript-preload.so"
MANGO_FIFO = os.environ.get("PF_MANGO_FIFO", "/run/pf-mango.fifo")
XDG = os.environ.get("XDG_RUNTIME_DIR", "/run/xdg")

# evdev keycodes for PHRASE characters
KEYMAP = {
    "h": 35, "e": 18, "l": 38, "o": 24, " ": 57,
    "a": 30, "r": 19, "n": 49, "s": 31,
}

CLIENTS = [
    # (name, backend, purpose, gui, preload, env extra)
    ("gtk4-text", "wayland", "email", True, True, {"GDK_BACKEND": "wayland"}),
    ("qt6-text", "wayland", "digits", True, True, {"QT_QPA_PLATFORM": "wayland"}),
    ("sdl3-text", "wayland", "normal", True, True, {"SDL_VIDEODRIVER": "wayland"}),
    ("sdl2-game", "wayland", None, True, True, {"SDL_VIDEODRIVER": "wayland"}),
    ("x11-gtk", "x11", "url", True, False,
     {"GDK_BACKEND": "x11", "GTK_IM_MODULE": "simple"}),
    ("xim-only", "x11", None, False, False, {}),
    ("no-im", "wayland", None, False, True, {}),
    ("broken-client", "headless", None, False, False, {}),
]


class SessionWriter:
    def __init__(self, path: str):
        self.fp = open(path, "w", buffering=1)
        self.seq = 0
        self.t0 = time.monotonic()

    def emit(self, event: str, **fields) -> None:
        self.seq += 1
        rec = {
            "schema": "pf-input-harness.transcript/v1",
            "client": "session",
            "seq": self.seq,
            "t_mono_us": int((time.monotonic() - self.t0) * 1_000_000),
            "event": event,
        }
        rec.update(fields)
        self.fp.write(json.dumps(rec) + "\n")

    def stop(self, rc: int) -> None:
        if self.fp is None:
            return
        self.emit("stop", rc=rc)
        self.fp.close()
        self.fp = None


def log(msg: str) -> None:
    print(f"[driver] {msg}", flush=True)


def fail(sw: SessionWriter, reason: str, hint: str) -> int:
    sw.emit("error", message=f"{reason}: {hint}")
    sw.stop(1)
    print(f"FAIL: input-harness reason={reason} hint={hint}", flush=True)
    return 1


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
            with open(tx_path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
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
            # client exited; the final scan above was its last chance
            return False
        time.sleep(0.2)
    return False


class FakeInput:
    def __init__(self, kind: str, sw: SessionWriter):
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
            raise RuntimeError(f"fake-input {kind} reported bad device line: {line}")
        self.name = info["name"]
        self.node = info["event_node"]
        subprocess.run(
            [os.path.join(SESSION_DIR, "udev-shim.sh"), self.node, kind],
            check=True,
        )
        sw.emit("device_created", kind=kind, name=self.name,
                event_node=self.node)
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


def screenshot(sw: SessionWriter, name: str, shot_type: int = 4) -> bool:
    path = os.path.join(SHOT_DIR, f"{name}.png")
    # Manifest and event paths are relative to the run dir so the same
    # manifest validates both in-container (/out) and on the host ($OUT).
    rel_path = os.path.join("screenshots", f"{name}.png")
    if os.path.exists(path):
        os.unlink(path)
    # Opening the FIFO for write blocks until the mangoapp relay reads it;
    # use O_NONBLOCK + retry so a dead relay fails the shot instead of
    # hanging the driver (the reaper respawns the relay between shots).
    fd = -1
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            fd = os.open(MANGO_FIFO, os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError:
            time.sleep(0.2)
    if fd < 0:
        msg = f"screenshot_relay_missing: no mangoapp reader on {MANGO_FIFO} within 60s ({name})"
        log(msg)
        sw.emit("error", message=msg)
        return False
    with os.fdopen(fd, "w") as fifo:
        fifo.write(f"screenshot {path} {shot_type}\n")
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            time.sleep(0.3)  # let pf-shot's write settle
            try:
                with open(path, "rb") as f:
                    head = f.read(33)
            except OSError:
                continue
            if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
                width, height = struct.unpack(">II", head[16:24])
                sw.emit("screenshot", path=rel_path, type=shot_type,
                        width=width, height=height)
                manifest_path = os.path.join(SHOT_DIR, "manifest.json")
                manifest = []
                if os.path.exists(manifest_path):
                    with open(manifest_path, "r", encoding="utf-8") as f:
                        manifest = json.load(f)
                manifest.append({"path": rel_path, "type": shot_type,
                                 "width": width, "height": height})
                with open(manifest_path, "w", encoding="utf-8") as f:
                    json.dump(manifest, f, indent=1)
                log(f"screenshot {path} {width}x{height}")
                return True
        time.sleep(0.2)
    msg = f"screenshot_timeout: {name} not written within 30s"
    log(msg)
    sw.emit("error", message=msg)
    return False


def type_phrase(kbd: FakeInput) -> None:
    for ch in PHRASE:
        code = KEYMAP[ch]
        kbd.cmd(f"key {code} 1")
        time.sleep(0.02)
        kbd.cmd(f"key {code} 0")
        time.sleep(0.03)


def run_client(sw: SessionWriter, name: str, backend: str, purpose,
               gui: bool, preload: bool, extra_env: dict,
               kbd: FakeInput, mouse: FakeInput) -> None:
    sw.emit("client_launch", target=name)
    env = dict(os.environ)
    env["PF_TRANSCRIPT_DIR"] = TX_DIR
    if purpose:
        env["PF_TX_PURPOSE"] = purpose
    if preload and os.path.exists(PRELOAD):
        env["LD_PRELOAD"] = PRELOAD
    env.update(extra_env)
    proc = subprocess.Popen([os.path.join(BIN, name)], env=env)
    tx_path = os.path.join(TX_DIR, f"{name}.jsonl")
    try:
        if not wait_event_in(tx_path, "mapped", 30, proc):
            log(f"WARN: {name} did not report mapped within 30s")
        if gui:
            mouse.cmd("abs 640 360")
            time.sleep(0.3)
            mouse.cmd("btn 272 1")
            time.sleep(0.05)
            mouse.cmd("btn 272 0")
            if not wait_event_in(tx_path, "enter", 10, proc):
                log(f"WARN: {name} did not report enter within 10s")
            # move slightly so cursor-theme lookups happen again
            mouse.cmd("abs 641 361")
        type_phrase(kbd)
        time.sleep(0.5)
        screenshot(sw, name)
    finally:
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=15)
    sw.emit("client_exit", target=name, rc=proc.returncode)
    log(f"client {name} exited rc={proc.returncode}")


def main() -> int:
    os.makedirs(TX_DIR, exist_ok=True)
    os.makedirs(SHOT_DIR, exist_ok=True)
    sw = SessionWriter(SESSION_TX)
    sw.emit("start", pid=os.getpid(), argv=sys.argv, backend="headless",
            display=os.environ.get("WAYLAND_DISPLAY", ""))

    fakes: list[FakeInput] = []
    bridge = None
    rc = 1
    try:
        wl_name = os.environ.get("WAYLAND_DISPLAY", "gamescope-0")
        wait_for_socket(wl_name, 60)
        eis_path = wait_for_socket(f"{wl_name}-ei", 60)
        sw.emit("compositor_ready", pid=os.getppid(),
                wayland_display=wl_name,
                x_display=os.environ.get("DISPLAY", ""),
                backend="headless")
        log(f"compositor ready: wayland={wl_name} x={os.environ.get('DISPLAY')}")

        pad = FakeInput("pad", sw)
        kbd = FakeInput("keyboard", sw)
        mouse = FakeInput("mouse", sw)
        fakes = [pad, kbd, mouse]

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
            return fail(sw, "eis_bridge_not_ready",
                        "libeis sender never reached emulating state")

        screenshot(sw, "idle")

        for (name, backend, purpose, gui, preload,
             extra_env) in CLIENTS:
            run_client(sw, name, backend, purpose, gui, preload, extra_env,
                       kbd, mouse)

        # exercise the pad once so downstream beads have a known-good path
        pad.cmd("btn 304 1")
        time.sleep(0.05)
        pad.cmd("btn 304 0")

        rc = 0
    except Exception as exc:  # noqa: BLE001 - driver must always write stop
        log(f"driver error: {exc}")
        sw.emit("error", message=str(exc))
        rc = 1
    finally:
        for f in fakes:
            f.destroy()
        if bridge is not None and bridge.poll() is None:
            bridge.terminate()
            try:
                bridge.wait(timeout=5)
            except subprocess.TimeoutExpired:
                bridge.kill()
                bridge.wait(timeout=5)
        sw.stop(rc)

    report = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "report", "report.py")
    if not os.path.exists(report):
        report = "/harness/report/report.py"
    rep = subprocess.run([sys.executable, "-B", report, OUT])
    return rep.returncode


if __name__ == "__main__":
    sys.exit(main())
