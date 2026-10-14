#!/usr/bin/env python3
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENT = ROOT / "guest" / "agent.py"


def send_frame(sock, header, payload=b""):
    header = dict(header, payload_len=len(payload))
    encoded = json.dumps(header, separators=(",", ":")).encode()
    sock.sendall(struct.pack(">I", len(encoded)) + encoded + payload)


def recv_exact(sock, size):
    data = b""
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise AssertionError("partial frame")
        data += part
    return data


def recv_frame(sock):
    size = struct.unpack(">I", recv_exact(sock, 4))[0]
    header = json.loads(recv_exact(sock, size))
    return header, recv_exact(sock, header["payload_len"])


def run_case(work, runner_body, request):
    runner = work / f"runner-{request['request_id']}"
    runner.write_text("#!/bin/sh\nset -eu\nout=\nwhile test $# -gt 0; do case \"$1\" in --out) out=$2; shift 2;; *) shift;; esac; done\n" + runner_body)
    runner.chmod(0o755)
    left, right = socket.socketpair()
    process = subprocess.Popen(
        [sys.executable, str(AGENT), "--fd", str(right.fileno()), "--once", "--runner", str(runner)],
        pass_fds=(right.fileno(),),
    )
    right.close()
    send_frame(left, request)
    frames = []
    while True:
        frame = recv_frame(left)
        frames.append(frame)
        if frame[0].get("kind") == "complete":
            break
    left.close()
    assert process.wait(timeout=10) == 0
    return frames


def main():
    with tempfile.TemporaryDirectory(prefix="pf-input-guest-agent.") as td:
        work = Path(td)
        request = {"protocol": "pf-input-harness.control/v1", "kind": "run", "request_id": 7, "suite": "full-input"}
        frames = run_case(
            work,
            "mkdir -p \"$out/transcripts\" \"$out/screenshots\"\n"
            "printf '%s\\n' '{\"event\":\"widget_text\",\"text\":\"hello harness\"}' > \"$out/transcripts/gtk4.jsonl\"\n"
            "printf '\\211PNG\\r\\n\\032\\nfixture' > \"$out/screenshots/gtk4.png\"\n"
            "printf '%s\\n' 'PASS: input-harness' > \"$out/report.txt\"\n",
            request,
        )
        artifacts = [frame for frame in frames if frame[0]["kind"] == "artifact"]
        assert {frame[0]["name"] for frame in artifacts} == {
            "report.txt", "screenshots/gtk4.png", "transcripts/gtk4.jsonl"
        }
        for header, payload in artifacts:
            assert header["sha256"] == hashlib.sha256(payload).hexdigest()
        assert frames[-1][0]["passed"] is True

        bad = dict(request, request_id=8)
        frames = run_case(
            work,
            "mkdir -p \"$out\"\nln -s /etc/passwd \"$out/report.txt\"\n",
            bad,
        )
        assert frames[-1][0]["passed"] is False
        assert frames[-1][0]["reason"] == "unsafe_artifact"

        oversized = dict(request, request_id=10)
        frames = run_case(
            work,
            "mkdir -p \"$out\"\ntruncate -s 16777217 \"$out/report.txt\"\n",
            oversized,
        )
        assert frames[-1][0]["passed"] is False
        assert frames[-1][0]["reason"] == "unsafe_artifact"

        malformed = dict(request, request_id=9, kind="delete")
        frames = run_case(work, "exit 99\n", malformed)
        assert frames[-1][0]["passed"] is False
        assert frames[-1][0]["reason"] == "invalid_request"

        missing = work / "absent-virtio-port"
        env = dict(os.environ, PF_INPUT_HARNESS_PORT=str(missing))
        refused = subprocess.run(
            [sys.executable, str(AGENT), "--once"], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            timeout=10, check=False,
        )
        assert refused.returncode != 0
        assert "virtio port absent" in refused.stdout
    print("guest-agent: PASS artifacts=3 symlink=refused oversized=refused malformed=refused absent_port=refused channel=mocked")


if __name__ == "__main__":
    main()
