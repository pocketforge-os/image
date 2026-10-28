#!/usr/bin/env python3
"""Hermetic loopback tests for the Steam Link signed first-run fetcher."""

from __future__ import annotations

import contextlib
import hashlib
import http.server
import importlib.util
import io
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import tempfile
import threading
import unittest
from unittest import mock


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


def make_synthetic_signed_fixture(root: Path) -> tuple[Path, str, str]:
    """Create CI-only inputs; developer runs exercise the preserved Valve files."""
    if shutil.which("gpg") is None:
        raise AssertionError("gpg is required for Steam Link signature tests")
    archive = root / ARCHIVE_NAME
    with tarfile.open(archive, "w:gz") as bundle:
        files = {
            "steamlink/version.txt": (f"{VERSION}\n".encode("ascii"), 0o644),
            "steamlink/bin/shell": (b"#!/bin/sh\nexit 0\n", 0o755),
        }
        for name, (body, mode) in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(body)
            member.mode = mode
            member.mtime = 0
            bundle.addfile(member, io.BytesIO(body))

    gnupg = root / "fixture-gnupg"
    gnupg.mkdir(mode=0o700)
    common = ["gpg", "--batch", "--homedir", str(gnupg), "--pinentry-mode", "loopback"]
    subprocess.run(
        [*common, "--passphrase", "", "--quick-gen-key", "Steam Link CI Fixture", "rsa2048", "sign", "0"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    listing = subprocess.run(
        [*common, "--with-colons", "--list-keys"],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    fingerprint = next(
        line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")
    )
    key = root / "fixture-release-key.asc"
    key.write_bytes(
        subprocess.run(
            [*common, "--armor", "--export", fingerprint],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    )
    subprocess.run(
        [*common, "--local-user", fingerprint, "--detach-sign", "--output", str(root / SIGNATURE_NAME), str(archive)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return key, fingerprint, hashlib.sha256(archive.read_bytes()).hexdigest()


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
        global ARCHIVE_SHA256, FINGERPRINT, TRUSTED_KEY, VENDOR
        for name in (ARCHIVE_NAME, SIGNATURE_NAME):
            path = VENDOR / name
            if not path.is_file():
                cls.fixture_temp = tempfile.TemporaryDirectory(prefix="steamlink-signed-fixture.")
                VENDOR = Path(cls.fixture_temp.name)
                TRUSTED_KEY, FINGERPRINT, ARCHIVE_SHA256 = make_synthetic_signed_fixture(VENDOR)
                return
        digest = hashlib.sha256((VENDOR / ARCHIVE_NAME).read_bytes()).hexdigest()
        if digest != ARCHIVE_SHA256:
            raise AssertionError(f"preserved archive digest differs: {digest}")

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "fixture_temp"):
            cls.fixture_temp.cleanup()

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

    def test_launch_uses_archive_runtime_paths_and_working_directory(self) -> None:
        spec = importlib.util.spec_from_file_location("steamlink_fetch", FETCHER)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        build = self.work / "build"
        top = build / "steamlink"
        (top / "bin").mkdir(parents=True)
        (top / "lib").mkdir()
        (top / "Qt-5.14.1" / "lib").mkdir(parents=True)
        (top / "Qt-5.14.1" / "plugins").mkdir()
        shell = top / "bin" / "shell"
        shell.write_text("#!/bin/sh\n", encoding="ascii")
        shell.chmod(0o755)
        with mock.patch.object(module.os, "chdir") as chdir, mock.patch.object(
            module.os, "execv"
        ) as execv, mock.patch.object(module.os, "execve") as execve:
            module.launch_if_requested(build, True)
        execv.assert_not_called()
        chdir.assert_called_once_with(top)
        executable, argv, environment = execve.call_args.args
        self.assertEqual(executable, shell)
        self.assertEqual(argv, [str(shell)])
        self.assertEqual(environment["QTDIR"], str(top / "Qt-5.14.1"))
        self.assertEqual(environment["QT_PLUGIN_PATH"], str(top / "Qt-5.14.1" / "plugins"))
        self.assertEqual(
            environment["LD_LIBRARY_PATH"].split(":"),
            [
                part
                for part in (
                    str(top / "lib"),
                    str(top / "Qt-5.14.1" / "lib"),
                    os.environ.get("LD_LIBRARY_PATH", ""),
                )
                if part
            ],
        )
        self.assertEqual(environment["PATH"].split(":", 1)[0], str(top / "bin"))

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
        self.assert_refused(bad, "abi_mismatch")
        self.assertNotIn("result=fallback", bad.stdout)
        self.assertEqual(os.readlink(self.state / "current"), before)

    def test_tampered_cached_build_is_refused(self) -> None:
        with fixture_server() as url:
            good = self.run_fetch(url)
            self.assertEqual(good.returncode, 0, good.stderr)
            installed = self.state / os.readlink(self.state / "current")
            (installed / "steamlink" / "bin" / "shell").write_text(
                "#!/bin/sh\nexit 23\n", encoding="ascii"
            )
            tampered = self.run_fetch(url)
        self.assert_refused(tampered, "state_invalid")
        self.assertNotIn("result=cached", tampered.stdout)
        self.assertNotIn("result=fallback", tampered.stdout)

    def test_corrupt_current_falls_back_to_verified_last_good(self) -> None:
        with fixture_server() as url:
            good = self.run_fetch(url)
        self.assertEqual(good.returncode, 0, good.stderr)
        valid_target = os.readlink(self.state / "current")
        (self.state / "last-good").symlink_to(valid_target)
        (self.state / "current").unlink()
        (self.state / "current").symlink_to("builds/corrupt-current")
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            unavailable = f"http://127.0.0.1:{probe.getsockname()[1]}"
        fallback = self.run_fetch(unavailable)
        self.assertEqual(fallback.returncode, 0, fallback.stderr)
        self.assertIn("result=fallback", fallback.stdout)
        self.assertIn("fallback=last_good", fallback.stdout)
        self.assertIn(str(self.state / valid_target), fallback.stdout)

    def test_successful_install_prunes_unreferenced_builds(self) -> None:
        with fixture_server() as url:
            good = self.run_fetch(url)
            self.assertEqual(good.returncode, 0, good.stderr)
            historical = self.state / "builds" / ("1.3.32.314-" + "1" * 64)
            historical.mkdir()
            (historical / "stale").write_text("stale\n", encoding="ascii")
            (self.state / "current").unlink()
            repaired = self.run_fetch(url)
        self.assertEqual(repaired.returncode, 0, repaired.stderr)
        self.assertFalse(historical.exists())
        self.assertEqual(len(list((self.state / "builds").iterdir())), 1)

    def test_offline_first_run_has_clear_reason(self) -> None:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            unavailable = f"http://127.0.0.1:{probe.getsockname()[1]}"
        result = self.run_fetch(unavailable)
        self.assert_refused(result, "offline")
        self.assertFalse((self.state / "current").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
