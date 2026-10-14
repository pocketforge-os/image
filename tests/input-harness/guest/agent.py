#!/usr/bin/env python3
"""Bounded virtio-serial agent for the guest-only input harness."""
import argparse
import hashlib
import json
import os
import signal
import stat
import struct
import subprocess
import tempfile
import time

PROTOCOL = "pf-input-harness.control/v1"
PORT = os.environ.get("PF_INPUT_HARNESS_PORT", "/dev/virtio-ports/org.pocketforge.input-harness.0")
RUNNER = "/opt/pf-input-harness/run-guest.sh"
MAX_HEADER = 64 * 1024
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
MEDIA = {".json": "application/json", ".jsonl": "application/x-ndjson", ".png": "image/png", ".txt": "text/plain"}


class ProtocolError(Exception):
    pass


class UnsafeArtifact(Exception):
    pass


class RunnerTimeout(Exception):
    pass


def process_group_exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def terminate_process_group(process, grace):
    """Terminate the runner session, escalating until no group member lives."""
    group = process.pid
    try:
        os.killpg(group, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while process_group_exists(group) and time.monotonic() < deadline:
        time.sleep(0.02)
    if process_group_exists(group):
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if process.poll() is None:
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=grace)


def run_runner(runner, output, timeout=1800, terminate_grace=5):
    process = subprocess.Popen(
        [runner, "--out", output], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        start_new_session=True,
    )
    try:
        try:
            stdout, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            terminate_process_group(process, terminate_grace)
            try:
                stdout, _ = process.communicate(timeout=terminate_grace)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, _ = process.communicate(timeout=terminate_grace)
            raise RunnerTimeout("runner exceeded time bound") from error
        return subprocess.CompletedProcess(
            process.args, process.returncode, stdout=stdout)
    finally:
        # A runner that exits while a detached descendant remains is also a
        # failed lifecycle. The dedicated session makes that cleanup bounded.
        terminate_process_group(process, terminate_grace)


def read_exact(stream, size):
    data = bytearray()
    while len(data) < size:
        part = os.read(stream, size - len(data))
        if not part:
            raise ProtocolError("channel closed during frame")
        data.extend(part)
    return bytes(data)


def read_frame(stream):
    length = struct.unpack(">I", read_exact(stream, 4))[0]
    if not 0 < length <= MAX_HEADER:
        raise ProtocolError("header length outside bounds")
    header = json.loads(read_exact(stream, length))
    if not isinstance(header, dict):
        raise ProtocolError("frame header is not an object")
    payload_len = header.get("payload_len")
    if not isinstance(payload_len, int) or not 0 <= payload_len <= MAX_FILE:
        raise ProtocolError("payload length outside bounds")
    return header, read_exact(stream, payload_len)


def write_all(stream, data):
    sent = 0
    while sent < len(data):
        count = os.write(stream, data[sent:])
        if count <= 0:
            raise ProtocolError("channel closed during write")
        sent += count


def write_frame(stream, header, payload=b""):
    header = dict(header, protocol=PROTOCOL, payload_len=len(payload))
    encoded = json.dumps(header, separators=(",", ":"), sort_keys=True).encode()
    if len(encoded) > MAX_HEADER:
        raise ProtocolError("response header exceeds bound")
    write_all(stream, struct.pack(">I", len(encoded)) + encoded + payload)


def artifact_files(root):
    total = 0
    output = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        for entry in dirs:
            path = os.path.join(directory, entry)
            if stat.S_ISLNK(os.lstat(path).st_mode):
                raise UnsafeArtifact("symlink directory")
        for entry in files:
            path = os.path.join(directory, entry)
            relative = os.path.relpath(path, root)
            suffix = os.path.splitext(relative)[1]
            if suffix not in MEDIA or relative.startswith("../"):
                raise UnsafeArtifact(f"unapproved artifact {relative}")
            try:
                descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
            except OSError as error:
                raise UnsafeArtifact(f"cannot safely open {relative}") from error
            try:
                info = os.fstat(descriptor)
                if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE:
                    raise UnsafeArtifact(f"unsafe artifact {relative}")
                total += info.st_size
                if total > MAX_TOTAL:
                    raise UnsafeArtifact("aggregate artifact bound exceeded")
                data = read_exact(descriptor, info.st_size)
            finally:
                os.close(descriptor)
            output.append((relative, MEDIA[suffix], data))
    return sorted(output)


def complete(stream, request_id, passed, reason, report=""):
    write_frame(stream, {
        "kind": "complete", "request_id": request_id, "passed": passed,
        "reason": reason, "report": report,
    })


def serve_once(stream, runner):
    request_id = 0
    try:
        header, payload = read_frame(stream)
        request_id = header.get("request_id", 0)
        if (header.get("protocol") != PROTOCOL or header.get("kind") != "run"
                or not isinstance(request_id, int) or request_id < 0
                or header.get("suite") != "full-input" or payload):
            complete(stream, request_id, False, "invalid_request")
            return
        run_root = "/run" if os.path.isdir("/run") and os.access("/run", os.W_OK) else None
        with tempfile.TemporaryDirectory(prefix="pf-input-harness.", dir=run_root) as output:
            try:
                result = run_runner(runner, output)
            except RunnerTimeout:
                complete(stream, request_id, False, "runner_timeout")
                return
            for name, media_type, data in artifact_files(output):
                write_frame(stream, {
                    "kind": "artifact", "request_id": request_id, "name": name,
                    "media_type": media_type, "sha256": hashlib.sha256(data).hexdigest(),
                }, data)
            report_path = os.path.join(output, "report.txt")
            report = ""
            if os.path.isfile(report_path) and not os.path.islink(report_path):
                with open(report_path, encoding="utf-8", errors="replace") as source:
                    report = source.read(MAX_HEADER)
            passed = result.returncode == 0 and report.startswith("PASS: input-harness")
            complete(stream, request_id, passed, "pass" if passed else "runner_failed", report)
    except UnsafeArtifact:
        complete(stream, request_id, False, "unsafe_artifact")
    except (ProtocolError, json.JSONDecodeError, ValueError):
        complete(stream, request_id, False, "invalid_request")
    except (OSError, subprocess.SubprocessError):
        complete(stream, request_id, False, "agent_error")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fd", type=int)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--runner", default=RUNNER)
    args = parser.parse_args()
    if args.fd is not None:
        serve_once(args.fd, args.runner)
        return
    try:
        port_mode = os.stat(PORT, follow_symlinks=False).st_mode
    except FileNotFoundError:
        raise SystemExit(f"input harness virtio port absent: {PORT}") from None
    if not stat.S_ISCHR(port_mode):
        raise SystemExit(f"input harness virtio port is not a character device: {PORT}")
    while True:
        descriptor = os.open(PORT, os.O_RDWR | os.O_CLOEXEC)
        try:
            serve_once(descriptor, args.runner)
        finally:
            os.close(descriptor)
        if args.once:
            return


if __name__ == "__main__":
    main()
