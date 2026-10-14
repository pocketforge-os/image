#!/usr/bin/env python3
"""Headless gamescope session driver for the PocketForge input harness.

Runs as gamescope's primary child (inherits WAYLAND_DISPLAY, DISPLAY and
LIBEI_SOCKET). Sequence:

  1. wait for the wayland + EIS sockets
  2. create private SOCK_SEQPACKET keyboard and pointer streams
  3. start the EIS bridge (private input_event fd -> libeis -> gamescope)
  4. take an idle screenshot, then run every test client in turn:
     launch -> wait mapped -> focus click -> type PHRASE -> screenshot -> SIGTERM
  5. always run the deliberately broken client last-but-one (negative control)
  6. write session.jsonl, chown /out to the host user, run report.py

Exit code is report.py's exit code.
"""

from __future__ import annotations

import ctypes
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import time

PHRASE = "hello harness"
QT_PHRASE = "1234567890"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/out"
TX_DIR = os.path.join(OUT, "transcripts")
SHOT_DIR = os.path.join(OUT, "screenshots")
SESSION_TX = os.path.join(OUT, "session.jsonl")
BIN = "/harness/bin"
PRELOAD = "/harness/lib/libpf-transcript-preload.so"
MANGO_FIFO = os.environ.get("PF_MANGO_FIFO", "/run/pf-mango.fifo")
XDG = os.environ.get("XDG_RUNTIME_DIR", "/run/xdg")

# evdev keycodes for PHRASE characters
KEYMAP = {
    "h": 35, "e": 18, "l": 38, "o": 24, " ": 57,
    "a": 30, "r": 19, "n": 49, "s": 31,
    "1": 2, "2": 3, "3": 4, "4": 5, "5": 6,
    "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
}

CLIENTS = [
    # (name, backend, purpose, phrase, gui, preload, env extra)
    ("gtk4-text", "wayland", "email", PHRASE, True, True, {"GDK_BACKEND": "wayland"}),
    ("qt6-text", "wayland", "digits", QT_PHRASE, True, True, {"QT_QPA_PLATFORM": "wayland"}),
    ("sdl3-text", "wayland", "normal", PHRASE, True, True, {"SDL_VIDEODRIVER": "wayland"}),
    ("sdl2-game", "wayland", None, PHRASE, True, True, {"SDL_VIDEODRIVER": "wayland"}),
    ("x11-gtk", "x11", "url", PHRASE, True, False,
     {"GDK_BACKEND": "x11", "GTK_IM_MODULE": "simple"}),
    ("xim-only", "x11", None, PHRASE, False, False, {}),
    ("no-im", "wayland", None, PHRASE, False, True, {}),
    ("broken-client", "headless", None, None, False, False, {}),
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


def prepare_output() -> None:
    """Create output directories only when no earlier run can be reused."""
    if os.path.lexists(SESSION_TX):
        raise RuntimeError(f"stale session transcript exists: {SESSION_TX}")
    for path in (TX_DIR, SHOT_DIR):
        if os.path.exists(path) and not os.path.isdir(path):
            raise RuntimeError(f"output path is not a directory: {path}")
        if os.path.isdir(path):
            with os.scandir(path) as entries:
                if any(entries):
                    raise RuntimeError(f"output directory is not empty: {path}")
    os.makedirs(TX_DIR, exist_ok=True)
    os.makedirs(SHOT_DIR, exist_ok=True)


def wait_for_socket(name: str, timeout: float) -> str:
    path = os.path.join(XDG, name)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return path
        time.sleep(0.2)
    raise TimeoutError(f"socket {path} did not appear within {timeout}s")


def wait_for_x_display(display: str, timeout: float) -> None:
    """Wait for a completed Xwayland handshake, not merely its socket."""
    x11 = ctypes.CDLL("libX11.so.6")
    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        handle = x11.XOpenDisplay(display.encode())
        if handle:
            x11.XCloseDisplay(handle)
            return
        time.sleep(0.1)
    raise TimeoutError(f"XOpenDisplay did not succeed: {display}")


def configure_wayland_display(env: dict[str, str]) -> str:
    """Resolve and export the compositor display for child processes."""
    name = env.get("WAYLAND_DISPLAY") or "gamescope-0"
    env["WAYLAND_DISPLAY"] = name
    return name


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


class PrivateInput:
    def __init__(self, kind: str, event_socket: socket.socket,
                 sw: SessionWriter):
        self.kind = kind
        event_fd = event_socket.fileno()
        try:
            self.proc = subprocess.Popen(
                [os.path.join(BIN, "private-input"),
                 "--event-fd", str(event_fd), kind],
                stdin=subprocess.PIPE,
                text=True,
                pass_fds=(event_fd,),
            )
        finally:
            event_socket.close()
        sw.emit("device_created", kind=kind,
                name=f"PocketForge Private {kind.title()}",
                event_source="private-seqpacket")
        log(f"private {kind} event stream ready")

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


def screenshot(sw: SessionWriter, name: str, phase: str,
               artifact: str | None = None, shot_type: int = 4) -> bool:
    artifact = artifact or name
    path = os.path.join(SHOT_DIR, f"{artifact}.png")
    # Manifest and event paths are relative to the run dir so the same
    # manifest validates both in-container (/out) and on the host ($OUT).
    rel_path = os.path.join("screenshots", f"{artifact}.png")
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
                sw.emit("screenshot", target=name, phase=phase, path=rel_path,
                        type=shot_type, width=width, height=height)
                manifest_path = os.path.join(SHOT_DIR, "manifest.json")
                manifest = []
                if os.path.exists(manifest_path):
                    with open(manifest_path, "r", encoding="utf-8") as f:
                        manifest = json.load(f)
                manifest.append({"target": name, "phase": phase,
                                 "path": rel_path, "type": shot_type,
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


def type_phrase(kbd: PrivateInput, phrase: str) -> None:
    for ch in phrase:
        code = KEYMAP[ch]
        kbd.cmd(f"key {code} 1")
        time.sleep(0.02)
        kbd.cmd(f"key {code} 0")
        time.sleep(0.03)


def wait_for_widget_text(tx_path: str, phrase: str, timeout: float,
                         proc: subprocess.Popen) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(tx_path):
            for record in read_jsonl(tx_path):
                if record.get("event") == "widget_text" and record.get("text") == phrase:
                    return True
        if proc.poll() is not None:
            return False
        time.sleep(0.1)
    return False


def read_jsonl(path: str):
    records = []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def run_client(sw: SessionWriter, name: str, backend: str, purpose, phrase,
               gui: bool, preload: bool, extra_env: dict,
               kbd: PrivateInput, pointer: PrivateInput) -> None:
    tx_path = os.path.join(TX_DIR, f"{name}.jsonl")
    if os.path.lexists(tx_path):
        raise RuntimeError(f"stale transcript exists before {name} launch: {tx_path}")
    sw.emit("client_launch", target=name)
    env = dict(os.environ)
    env["PF_TRANSCRIPT_DIR"] = TX_DIR
    if purpose:
        env["PF_TX_PURPOSE"] = purpose
    if preload and os.path.exists(PRELOAD):
        env["LD_PRELOAD"] = PRELOAD
    env.update(extra_env)
    proc = subprocess.Popen([os.path.join(BIN, name)], env=env)
    try:
        if not wait_event_in(tx_path, "mapped", 30, proc):
            log(f"WARN: {name} did not report mapped within 30s")
        if gui:
            # gamescope headless delivers EIS absolute coordinates in the
            # client's logical space even when the 640x480 surface is scaled
            # into the 1280x720 output. Target the shared logical center.
            pointer.cmd("abs 320 240")
            time.sleep(0.3)
            # A newly mapped gamescope window may consume the first click to
            # activate it.  Keep activation separate from the second click,
            # whose delivery is part of the client acceptance evidence.
            pointer.cmd("btn 272 1")
            time.sleep(0.05)
            pointer.cmd("btn 272 0")
            time.sleep(0.3)
            pointer.cmd("btn 272 1")
            time.sleep(0.05)
            pointer.cmd("btn 272 0")
            time.sleep(0.3)
            if not wait_event_in(tx_path, "enter", 10, proc):
                log(f"WARN: {name} did not report enter within 10s")
            # move slightly so cursor-theme lookups happen again
            pointer.cmd("abs 641 361")
        if phrase is not None:
            if not screenshot(sw, name, "before", f"{name}-before"):
                raise RuntimeError(f"{name} pre-typing screenshot failed")
            type_phrase(kbd, phrase)
            if not wait_for_widget_text(tx_path, phrase, 10, proc):
                raise RuntimeError(
                    f"{name} did not read back expected widget text {phrase!r}")
        time.sleep(0.5)
        screenshot(sw, name, "after")
    finally:
        sw.emit("client_stop", target=name)
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
    try:
        prepare_output()
    except (OSError, RuntimeError) as exc:
        print(f"FAIL: input-harness reason=output_not_empty hint={exc}", flush=True)
        return 1
    sw = SessionWriter(SESSION_TX)
    sw.emit("start", pid=os.getpid(), argv=sys.argv, backend="headless",
            display=os.environ.get("WAYLAND_DISPLAY", ""))

    inputs: list[PrivateInput] = []
    event_readers: list[socket.socket] = []
    bridge = None
    rc = 1
    try:
        wl_name = configure_wayland_display(os.environ)
        wait_for_socket(wl_name, 60)
        eis_path = wait_for_socket(f"{wl_name}-ei", 60)
        x_display = os.environ.get("DISPLAY", "")
        if not x_display:
            raise RuntimeError("gamescope did not export DISPLAY")
        wait_for_x_display(x_display, 60)
        sw.emit("compositor_ready", pid=os.getppid(),
                wayland_display=wl_name,
                x_display=x_display,
                backend="headless")
        log(f"compositor ready: wayland={wl_name} x={os.environ.get('DISPLAY')}")

        kbd_reader, kbd_writer = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_SEQPACKET)
        pointer_reader, pointer_writer = socket.socketpair(
            socket.AF_UNIX, socket.SOCK_SEQPACKET)
        event_readers = [kbd_reader, pointer_reader]
        kbd = PrivateInput("keyboard", kbd_writer, sw)
        inputs.append(kbd)
        pointer = PrivateInput("pointer", pointer_writer, sw)
        inputs.append(pointer)

        try:
            bridge = subprocess.Popen(
                [os.path.join(BIN, "eis-bridge"), eis_path,
                 "--keyboard-event-fd", str(kbd_reader.fileno()),
                 "--pointer-event-fd", str(pointer_reader.fileno())],
                stdout=subprocess.PIPE,
                text=True,
                pass_fds=(kbd_reader.fileno(), pointer_reader.fileno()),
            )
        finally:
            for reader in event_readers:
                reader.close()
            event_readers = []
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

        # Xwayland creates its emulated keyboard keymap lazily on the first
        # libei key frame. Prime it with a non-text modifier before any client
        # provides acceptance evidence, so that initialization cannot consume
        # the first client's phrase.
        kbd.cmd("key 42 1")
        time.sleep(0.05)
        kbd.cmd("key 42 0")
        time.sleep(1.0)

        for (name, backend, purpose, phrase, gui, preload,
             extra_env) in CLIENTS:
            run_client(sw, name, backend, purpose, phrase, gui, preload, extra_env,
                       kbd, pointer)

        rc = 0
    except Exception as exc:  # noqa: BLE001 - driver must always write stop
        log(f"driver error: {exc}")
        sw.emit("error", message=str(exc))
        rc = 1
    finally:
        for reader in event_readers:
            reader.close()
        for source in inputs:
            source.destroy()
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
