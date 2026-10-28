#!/usr/bin/env python3
"""Hermetic loopback tests for the Steam Link signed first-run fetcher."""

from __future__ import annotations

import contextlib
import hashlib
import http.server
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
FETCHER = ROOT / "apps" / "steamlink" / "steamlink-fetch.py"
TRUSTED_KEY = ROOT / "apps" / "steamlink" / "valve-steamlink-release-key.asc"
VENDOR = Path(
    os.environ.get(
        "PF_STEAMLINK_VENDOR_DIR",
        "/home/matt/recovery/steamlink-vendor/rpi-bookworm-arm64-1.3.32.316",
    )
)
VERSION = "1.3.32.316"
ARCHIVE_NAME = f"steamlink-rpi-bookworm-arm64-{VERSION}.tar.gz"
SIGNATURE_NAME = f"{ARCHIVE_NAME}.sig"
ARCHIVE_SHA256 = "6e1e431265da01b85a7a2fb2ef652f822eb16c5b78aca03f0d0d500dc29b93d3"
FINGERPRINT = "BA23DAE64102FBE0BB140CE5387C648A24C0E740"


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    root: Path
    version = VERSION
    bad_signature = False
    truncate_archive = False

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self.path == "/public_build.txt":
            self._send((self.version + "\n").encode("ascii"))
            return
        if self.path == f"/{ARCHIVE_NAME}":
            body = (self.root / ARCHIVE_NAME).read_bytes()
            if self.truncate_archive:
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body[: len(body) // 2])
                return
            self._send(body)
            return
        if self.path == f"/{SIGNATURE_NAME}":
            body = bytearray((self.root / SIGNATURE_NAME).read_bytes())
            if self.bad_signature:
                body[-1] ^= 1
            self._send(bytes(body))
            return
        self.send_error(404)

    def _send(self, body: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *args: object) -> None:
        del args


@contextlib.contextmanager
def fixture_server(*, version: str = VERSION, bad_signature: bool = False, truncate: bool = False):
    handler = type(
        "ConfiguredFixtureHandler",
        (FixtureHandler,),
        {
            "root": VENDOR,
            "version": version,
            "bad_signature": bad_signature,
            "truncate_archive": truncate,
        },
    )
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def write_platform_runtime(root: Path) -> Path:
    runtime = root / "steamlink-ffmpeg59" / "v1"
    metadata = runtime / "metadata"
    libraries = runtime / "lib" / "aarch64-linux-gnu"
    metadata.mkdir(parents=True)
    libraries.mkdir(parents=True)
    files = {
        "libavcodec.so.59.37.100": b"hermetic avcodec59\n",
        "libavutil.so.57.28.100": b"hermetic avutil57\n",
        "libswresample.so.4.7.100": b"hermetic swresample4\n",
    }
    for name, body in files.items():
        (libraries / name).write_bytes(body)
    (libraries / "libavcodec.so.59").symlink_to("libavcodec.so.59.37.100")
    (libraries / "libavutil.so.57").symlink_to("libavutil.so.57.28.100")
    (libraries / "libswresample.so.4").symlink_to("libswresample.so.4.7.100")
    (metadata / "runtime.toml").write_text(
        "\n".join(
            [
                "schema_version = 1",
                'runtime_id = "steamlink-ffmpeg59"',
                'revision = "v1"',
                'architecture = "aarch64"',
                f'libdir = "{libraries}"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    (metadata / "libraries.sha256").write_text(
        "".join(
            f"{hashlib.sha256(body).hexdigest()}  {name}\n"
            for name, body in sorted(files.items())
        ),
        encoding="ascii",
    )
    return runtime


class SteamLinkFetchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        for name in (ARCHIVE_NAME, SIGNATURE_NAME):
            path = VENDOR / name
            if not path.is_file():
                raise unittest.SkipTest(f"preserved Valve fixture absent: {path}")
        digest = hashlib.sha256((VENDOR / ARCHIVE_NAME).read_bytes()).hexdigest()
        if digest != ARCHIVE_SHA256:
            raise AssertionError(f"preserved archive digest differs: {digest}")

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="steamlink-fetch-test.")
        self.work = Path(self.temp.name)
        self.state = self.work / "state"
        self.runtime = write_platform_runtime(self.work / "platform-runtimes")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_fetch(self, base_url: str, *, state: Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                str(FETCHER),
                "--state-root",
                str(state or self.state),
                "--platform-runtime",
                str(self.runtime),
                "--base-url",
                base_url,
                "--trusted-key",
                str(TRUSTED_KEY),
                "--trusted-fingerprint",
                FINGERPRINT,
                "--minimum-version",
                VERSION,
                "--bootstrap-sha256",
                ARCHIVE_SHA256,
                "--timeout",
                "2",
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def assert_refused(self, result: subprocess.CompletedProcess[str], reason: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"reason={reason}", result.stderr)

    def test_good_signature_installs(self) -> None:
        with fixture_server() as url:
            result = self.run_fetch(url)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("result=installed", result.stdout)
        current = self.state / "current"
        self.assertTrue(current.is_symlink())
        installed = (self.state / os.readlink(current)).resolve()
        self.assertTrue((installed / "steamlink" / "bin" / "shell").is_file())
        self.assertTrue((installed / "receipt.json").is_file())

    def test_bad_signature_refuses(self) -> None:
        with fixture_server(bad_signature=True) as url:
            result = self.run_fetch(url)
        self.assert_refused(result, "signature_invalid")
        self.assertFalse((self.state / "current").exists())

    def test_truncated_download_refuses_without_partial_install(self) -> None:
        with fixture_server(truncate=True) as url:
            result = self.run_fetch(url)
        self.assert_refused(result, "download_truncated")
        self.assertFalse((self.state / "current").exists())
        self.assertEqual(list(self.state.glob(".staging.*")), [])
        self.assertEqual(list((self.state / "builds").glob("*")), [])

    def test_build_below_floor_is_refused(self) -> None:
        with fixture_server(version="1.3.32.315") as url:
            result = self.run_fetch(url)
        self.assert_refused(result, "version_below_floor")
        self.assertFalse((self.state / "current").exists())

    def test_abi_mismatch_keeps_last_good(self) -> None:
        with fixture_server() as url:
            good = self.run_fetch(url)
            self.assertEqual(good.returncode, 0, good.stderr)
            before = os.readlink(self.state / "current")
            (self.runtime / "lib" / "aarch64-linux-gnu" / "libavcodec.so.59.37.100").write_bytes(
                b"wrong ABI\n"
            )
            bad = self.run_fetch(url)
        self.assertEqual(bad.returncode, 0, bad.stderr)
        self.assertIn("reason=abi_mismatch", bad.stdout)
        self.assertIn("fallback=last_good", bad.stdout)
        self.assertEqual(os.readlink(self.state / "current"), before)

    def test_offline_first_run_has_clear_reason(self) -> None:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            unavailable = f"http://127.0.0.1:{probe.getsockname()[1]}"
        result = self.run_fetch(unavailable)
        self.assert_refused(result, "offline")
        self.assertFalse((self.state / "current").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
