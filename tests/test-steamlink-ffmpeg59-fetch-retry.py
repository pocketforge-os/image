#!/usr/bin/env python3
"""Hermetic loopback test for the steamlink-ffmpeg59 build.sh fetch_one retry.

snapshot.debian.org answers 503/504 for the first fetch of a cold object and
200 a minute later (tsp-hqm1p.153). This runs the shipped fetch_one against a
local HTTPS server (build.sh pins --proto '=https') that fails the same way and
proves: transient 5xx is retried and then succeeds; the retry is bounded;
permanent errors are not retried; and a wrong object still fails closed on the
unchanged size and sha256 checks.
"""

from __future__ import annotations

import hashlib
import http.server
import os
from pathlib import Path
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "build/platform-runtimes/steamlink-ffmpeg59/v1/build.sh"
BLOCKED = 75
# The shipped retry budget. The harness shortens only the sleep between tries.
SHIPPED_RETRIES = 5
SHIPPED_DELAY = "--retry-delay 20"
TEST_DELAY = "--retry-delay 1"
BODY = b"pinned ffmpeg object bytes\n"


def extract_shipped_definitions() -> str:
    """Return die, require_equal and fetch_one exactly as build.sh defines them."""
    text = BUILDER.read_text()
    parts = []
    for pattern in (r"^die\(\) .*$", r"^require_equal\(\) .*$"):
        found = re.search(pattern, text, re.MULTILINE)
        if found is None:
            raise AssertionError(f"build.sh no longer defines {pattern}")
        parts.append(found.group(0))
    body = re.search(r"^fetch_one\(\) \{$.*?^\}$", text, re.MULTILINE | re.DOTALL)
    if body is None:
        raise AssertionError("build.sh no longer defines fetch_one")
    parts.append(body.group(0))
    return "\n".join(parts) + "\n"


SHIPPED = extract_shipped_definitions()


class Plan:
    """Per-path scripted statuses: the first len(statuses) requests fail."""

    def __init__(self, statuses: list[int], body: bytes = BODY):
        self.statuses = statuses
        self.body = body
        self.hits = 0


class Handler(http.server.BaseHTTPRequestHandler):
    plans: dict[str, Plan] = {}
    lock = threading.Lock()

    def do_GET(self) -> None:  # noqa: N802 (http.server API)
        with self.lock:
            plan = self.plans[self.path]
            plan.hits += 1
            attempt = plan.hits
        if attempt <= len(plan.statuses):
            self.send_response(plan.statuses[attempt - 1])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(plan.body)))
        self.end_headers()
        self.wfile.write(plan.body)

    def log_message(self, *_args) -> None:
        pass


def make_certificate(directory: Path) -> Path:
    cert = directory / "cert.pem"
    key = directory / "key.pem"
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", str(key), "-out", str(cert), "-days", "1",
            "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        check=True,
        capture_output=True,
    )
    return cert


class FetchOneRetry(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        for tool in ("openssl", "curl", "bash"):
            if shutil.which(tool) is None:
                print(f"BLOCKED: {tool} is required", file=sys.stderr)
                sys.exit(BLOCKED)
        cls.scratch = Path(tempfile.mkdtemp(prefix="steamlink-ffmpeg59-fetch."))
        cert = make_certificate(cls.scratch)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, cls.scratch / "key.pem")
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"https://127.0.0.1:{cls.server.server_port}"
        cls.env = {
            key: value
            for key, value in os.environ.items()
            if key.lower() not in {"http_proxy", "https_proxy", "all_proxy", "no_proxy"}
        }
        cls.env["NO_PROXY"] = "127.0.0.1,localhost"
        cls.env["CURL_CA_BUNDLE"] = str(cert)
        # Exercise the shipped function; only the sleep between tries is shortened
        # (test_shipped_flags separately requires the shipped delay to be present).
        harness = (
            "set -euo pipefail\n"
            + SHIPPED.replace(SHIPPED_DELAY, TEST_DELAY)
            + 'FFMPEG_SNAPSHOT_BASE=$1\nsrc_objects=$2\n'
            + 'fetch_one "$3" "$4" "$5"\n'
        )
        cls.harness = cls.scratch / "harness.sh"
        cls.harness.write_text(harness)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        shutil.rmtree(cls.scratch)

    def fetch(self, name: str, plan: Plan, *, base: str | None = None, size=None, sha=None):
        Handler.plans["/" + name] = plan
        out = self.scratch / ("objects-" + name)
        out.mkdir()
        result = subprocess.run(
            [
                "bash", str(self.harness), base or self.base, str(out), name,
                str(len(BODY) if size is None else size),
                sha or hashlib.sha256(BODY).hexdigest(),
            ],
            env=self.env, capture_output=True, text=True, timeout=120,
        )
        return result, out / name

    def test_shipped_flags(self) -> None:
        """The hardened transport flags and the retry budget are all present."""
        for flag in (
            "--fail", "--location", "--proto '=https'", "--tlsv1.2",
            f"--retry {SHIPPED_RETRIES}", SHIPPED_DELAY, "--max-time",
        ):
            self.assertIn(flag, SHIPPED)
        self.assertNotIn("--retry-all-errors", SHIPPED)
        self.assertIn("size", SHIPPED)
        self.assertIn("sha256", SHIPPED)

    def test_cold_object_504_twice_then_200_succeeds(self) -> None:
        plan = Plan([504, 504])
        result, path = self.fetch("cold-504", plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plan.hits, 3)
        self.assertEqual(path.read_bytes(), BODY)

    def test_cold_object_503_then_200_succeeds(self) -> None:
        plan = Plan([503])
        result, path = self.fetch("cold-503", plan)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plan.hits, 2)
        self.assertEqual(path.read_bytes(), BODY)

    def test_persistent_504_is_bounded_and_fails(self) -> None:
        plan = Plan([504] * 50)
        result, _ = self.fetch("always-504", plan)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(plan.hits, 1 + SHIPPED_RETRIES)

    def test_permanent_404_is_not_retried(self) -> None:
        plan = Plan([404] * 50)
        result, _ = self.fetch("missing", plan)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(plan.hits, 1)

    def test_wrong_size_fails_closed_without_retry(self) -> None:
        plan = Plan([], body=BODY + b"x")
        result, _ = self.fetch("wrong-size", plan)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong-size size drift", result.stderr)
        self.assertEqual(plan.hits, 1)

    def test_wrong_bytes_fail_closed_without_retry(self) -> None:
        plan = Plan([], body=BODY.upper())
        result, _ = self.fetch("wrong-bytes", plan)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("wrong-bytes sha256 drift", result.stderr)
        self.assertEqual(plan.hits, 1)

    def test_plain_http_is_refused(self) -> None:
        plan = Plan([])
        http_base = self.base.replace("https://", "http://", 1)
        result, _ = self.fetch("plain-http", plan, base=http_base)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(plan.hits, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
