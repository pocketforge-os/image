#!/usr/bin/env python3
"""Hermetic contract tests for the app runtime-root renderer and namespace."""

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
RENDERER = ROOT / "scripts" / "render-app-runtime-root.py"
ROOT_CONTENT = b"hermetic runtime root fixture\n"
DIGEST = "sha256:" + hashlib.sha256(ROOT_CONTENT).hexdigest()
PLATFORM_VERSION = "sha256:" + "2" * 64


def manifest(*, root: bool = True, capabilities: tuple[str, ...] = ()) -> str:
    caps = ", ".join(json.dumps(value) for value in capabilities)
    root_table = ""
    if root:
        root_table = textwrap.dedent(
            f"""
            [runtime.root]
            schema = 1
            format = "squashfs"
            digest = "{DIGEST}"
            platform-runtime = "pocketforge/bookworm-aarch64"
            platform-runtime-abi = "1"
            platform-runtime-version = "{PLATFORM_VERSION}"
            library-paths = ["lib", "Qt-5.14.1/lib"]
            """
        )
    return textwrap.dedent(
        f"""
        [app]
        id = "org.pocketforge.steamlink"
        name = "Steam Link"
        version = "1.3.32.316"
        category = "stream"
        use = [{caps}]

        [runtime]
        family = "pocketforge/a133-powervr"
        abi = "1"
        platform-version = "20"
        {root_table}

        [launch]
        exec = "bin/shell"
        needs_network = true
        takes_display = true
        audio = true
        """
    )


def inventory() -> dict[str, object]:
    return {
        "schema_version": 1,
        "platform_runtime": "pocketforge/bookworm-aarch64",
        "platform_runtime_abi": "1",
        "platform_runtime_version": PLATFORM_VERSION,
        "resources": {
            "audio-devices": ["/dev/snd/controlC0", "/dev/snd/pcmC0D0p"],
            "audio-sockets": ["/run/pocketforge/session/audio-0"],
            "broker-sockets": ["/run/pocketforge/input-broker.sock"],
            "display-sockets": ["/run/pocketforge/session/wayland-0"],
            "input-devices": ["/dev/input/event0"],
            "media-devices": ["/dev/media0"],
            "render-devices": ["/dev/dri/renderD128"],
            "session-environment": ["/run/pocketforge/session/environment"],
            "video-decode-devices": ["/dev/video10"],
        },
    }


class RendererTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pf-runtime-root-test-")
        self.work = Path(self.temp.name)
        self.manifest = self.work / "app.toml"
        self.inventory = self.work / "inventory.json"
        self.output = self.work / "50-runtime-root.conf"
        self.app_root_store = self.work / "app-roots"
        self.platform_store = self.work / "platform-runtimes"
        root_path = (
            self.app_root_store
            / "org.pocketforge.steamlink"
            / f"sha256-{DIGEST.removeprefix('sha256:')}.raw"
        )
        root_path.parent.mkdir(parents=True)
        root_path.write_bytes(ROOT_CONTENT)
        platform_path = (
            self.platform_store
            / "pocketforge-bookworm-aarch64"
            / f"sha256-{PLATFORM_VERSION.removeprefix('sha256:')}"
        )
        platform_path.mkdir(parents=True)
        (platform_path / ".manifest-sha256").write_text(
            PLATFORM_VERSION.removeprefix("sha256:") + "\n", encoding="ascii"
        )
        self.inventory.write_text(json.dumps(inventory()), encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def render(self, source: str, *, expect: int = 0) -> subprocess.CompletedProcess[str]:
        self.manifest.write_text(source, encoding="utf-8")
        result = subprocess.run(
            [
                str(RENDERER),
                "--manifest",
                str(self.manifest),
                "--inventory",
                str(self.inventory),
                "--output",
                str(self.output),
                "--app-root-store",
                str(self.app_root_store),
                "--platform-runtime-store",
                str(self.platform_store),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, expect, result.stderr)
        return result

    def test_omitted_root_is_exact_legacy_default(self) -> None:
        self.output.write_text("stale generated drop-in\n", encoding="utf-8")
        result = self.render(manifest(root=False))
        self.assertEqual(result.stdout, "runtime_root=absent action=unchanged\n")
        self.assertFalse(self.output.exists())

    def test_default_root_render_is_deterministic_and_fail_closed(self) -> None:
        self.render(manifest(capabilities=("audio", "input", "vibration")))
        first = self.output.read_bytes()
        self.output.unlink()
        self.render(manifest(capabilities=("audio", "input", "vibration")))
        self.assertEqual(first, self.output.read_bytes())

        unit = first.decode()
        expected = (
            "RootImage=/var/lib/pocketforge/app-roots/org.pocketforge.steamlink/sha256-"
            + DIGEST.removeprefix("sha256:")
            + ".raw"
        )
        self.assertIn(expected, unit)
        self.assertIn("RootImageOptions=ro", unit)
        self.assertIn("ProtectSystem=strict", unit)
        self.assertIn("ProtectHome=yes", unit)
        self.assertIn("PrivateUsers=yes", unit)
        self.assertIn("PrivateDevices=yes", unit)
        self.assertIn("DevicePolicy=closed", unit)
        self.assertIn(
            "ReadWritePaths=/var/lib/pocketforge/apps/org.pocketforge.steamlink", unit
        )
        self.assertIn("DeviceAllow=/dev/dri/renderD128 rw", unit)
        self.assertIn("DeviceAllow=/dev/input/event0 rw", unit)
        self.assertIn("DeviceAllow=/dev/snd/controlC0 rw", unit)
        self.assertNotIn("/dev/video", unit)
        self.assertNotIn("/dev/media", unit)

    def test_every_declared_capability_has_an_explicit_resource_outcome(self) -> None:
        capabilities = (
            "accelerometer",
            "audio",
            "entropy",
            "gnss",
            "gyroscope",
            "imu",
            "input",
            "leds",
            "location",
            "magnetometer",
            "rumble",
            "settings",
            "vibration",
            "video-decode",
        )
        self.render(manifest(capabilities=capabilities))
        unit = self.output.read_text(encoding="utf-8")
        for path in (
            "/dev/dri/renderD128",
            "/dev/input/event0",
            "/dev/media0",
            "/dev/snd/controlC0",
            "/dev/snd/pcmC0D0p",
            "/dev/video10",
        ):
            self.assertIn(f"DeviceAllow={path} rw", unit)
        for path in (
            "/run/pocketforge/input-broker.sock",
            "/run/pocketforge/session/audio-0",
            "/run/pocketforge/session/wayland-0",
        ):
            self.assertIn(f"BindPaths={path}", unit)
        self.assertIn(
            "BindReadOnlyPaths=/run/pocketforge/session/environment", unit
        )
        for capability in capabilities:
            self.assertIn(f"# capability {capability}:", unit)

    def test_input_without_write_capability_is_read_only(self) -> None:
        self.render(manifest(capabilities=("input",)))
        unit = self.output.read_text(encoding="utf-8")
        self.assertIn("DeviceAllow=/dev/input/event0 r", unit)
        self.assertIn("BindReadOnlyPaths=/dev/input/event0", unit)
        self.assertNotIn("DeviceAllow=/dev/input/event0 rw", unit)

    def test_current_optional_and_modifier_syntax_is_normalized(self) -> None:
        self.render(
            manifest(capabilities=(" IMU?", "gnss:precise", "egress:steam.example"))
        )
        unit = self.output.read_text(encoding="utf-8")
        self.assertIn("# capability imu: broker socket only", unit)
        self.assertIn("# capability gnss: broker socket only", unit)
        self.assertIn("# capability egress: declaration only", unit)

        result = self.render(
            manifest(capabilities=("gnss:precise", "gnss?")), expect=65
        )
        self.assertIn("reason=descriptor_invalid", result.stderr)

        data = inventory()
        del data["resources"]["input-devices"]  # type: ignore[index]
        self.inventory.write_text(json.dumps(data), encoding="utf-8")
        no_display_or_audio = manifest(capabilities=("input?",)).replace(
            "takes_display = true", "takes_display = false"
        ).replace("audio = true", "audio = false")
        self.render(no_display_or_audio)
        self.assertNotIn("/dev/input", self.output.read_text(encoding="utf-8"))
        result = self.render(
            no_display_or_audio.replace('use = ["input?"]', 'use = ["input"]'),
            expect=66,
        )
        self.assertIn("reason=required_resource_missing", result.stderr)

    def test_invalid_metadata_and_missing_resources_refuse_without_output(self) -> None:
        bad_cases = (
            ("runtime_root_invalid", manifest().replace(DIGEST, "sha256:not-a-digest")),
            ("runtime_root_invalid", manifest().replace("schema = 1", "schema = 2")),
            (
                "platform_runtime_incompatible",
                manifest().replace(
                    'platform-runtime-abi = "1"', 'platform-runtime-abi = "9"'
                ),
            ),
            ("unsupported_capability", manifest(capabilities=("host-root",))),
            (
                "runtime_root_invalid_library_path",
                manifest().replace(
                    'library-paths = ["lib", "Qt-5.14.1/lib"]',
                    'library-paths = ["../../host"]',
                ),
            ),
        )
        for reason, source in bad_cases:
            with self.subTest(reason=reason):
                self.output.unlink(missing_ok=True)
                result = self.render(source, expect=65)
                self.assertIn(f"reason={reason}", result.stderr)
                self.assertFalse(self.output.exists())

        data = inventory()
        del data["resources"]["audio-devices"]  # type: ignore[index]
        self.inventory.write_text(json.dumps(data), encoding="utf-8")
        result = self.render(manifest(capabilities=("audio",)), expect=66)
        self.assertIn("reason=required_resource_missing", result.stderr)
        self.assertFalse(self.output.exists())

    def test_missing_or_changed_artifacts_refuse_without_output(self) -> None:
        root_path = next(self.app_root_store.rglob("*.raw"))
        root_path.unlink()
        result = self.render(manifest(), expect=66)
        self.assertIn("reason=runtime_root_missing", result.stderr)
        self.assertFalse(self.output.exists())

        root_path.write_bytes(b"changed fixture\n")
        result = self.render(manifest(), expect=65)
        self.assertIn("reason=runtime_root_digest_mismatch", result.stderr)
        self.assertFalse(self.output.exists())
        root_path.write_bytes(ROOT_CONTENT)

        platform_path = next(
            path for path in self.platform_store.rglob("sha256-*") if path.is_dir()
        )
        identity = platform_path / ".manifest-sha256"
        identity.unlink()
        result = self.render(manifest(), expect=66)
        self.assertIn("reason=platform_runtime_missing", result.stderr)
        self.assertFalse(self.output.exists())

        identity.write_text("0" * 64 + "\n", encoding="ascii")
        result = self.render(manifest(), expect=65)
        self.assertIn("reason=platform_runtime_digest_mismatch", result.stderr)
        self.assertFalse(self.output.exists())

    def test_output_materialization_failure_is_typed_and_fail_closed(self) -> None:
        self.output.mkdir()
        result = self.render(manifest(), expect=74)
        self.assertIn("reason=sandbox_render_failed", result.stderr)
        self.assertTrue(self.output.is_dir())


class NamespaceIsolationTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which("bwrap"), "bubblewrap is required")
    def test_host_root_is_read_only_and_only_state_is_persistent(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pf-runtime-root-ns-") as raw:
            work = Path(raw)
            state = work / "state"
            state.mkdir()
            pocketforge = work / "pocketforge"
            (pocketforge / "apps" / "org.pocketforge.steamlink").mkdir(parents=True)
            platform = pocketforge / "platform-runtime"
            platform.mkdir()
            (platform / "immutable").write_text("platform\n", encoding="utf-8")
            result = subprocess.run(
                [
                    "bwrap",
                    "--unshare-all",
                    "--ro-bind",
                    "/",
                    "/",
                    "--proc",
                    "/proc",
                    "--dev",
                    "/dev",
                    "--tmpfs",
                    "/tmp",
                    "--ro-bind",
                    str(pocketforge),
                    "/var/lib/pocketforge",
                    "--bind",
                    str(state),
                    "/var/lib/pocketforge/apps/org.pocketforge.steamlink",
                    "/bin/sh",
                    "-ec",
                    "! touch /etc/pf-runtime-root-host-write; "
                    "! touch /var/lib/pocketforge/platform-runtime/immutable; "
                    "touch /var/lib/pocketforge/apps/org.pocketforge.steamlink/persisted; "
                    "touch /tmp/ephemeral; "
                    "test ! -e /dev/input/event0; "
                    "test ! -e /dev/dri/renderD128; "
                    "test ! -e /dev/video0; "
                    "test ! -e /dev/media0",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((state / "persisted").is_file())
            self.assertFalse(Path("/etc/pf-runtime-root-host-write").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
