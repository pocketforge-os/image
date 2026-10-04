#!/usr/bin/env python3
"""Hermetic RED/GREEN controls for the Gamescope package identity boundary."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import gamescope_package as gp  # noqa: E402


BASE = "79399f4b34b5571ba5b03f61c4717eaf93ff75b3"
HEAD = "1b55348e5ec40caf46528103ff2b9291422f13c1"
PRESENT = "b1d220453331e28554d938f060156abfeb504757"
STAGING = "a5b1f4697a13e671f9e8bfd108c3003987ca1fa4"
ROTATION = "eb3ae2c705326b0c6535ea99ee233c17a170ace4"
PATCHES = "bcf1ee23703ad096371a41f6d4fe83c696d4c3803716ba98839213bf7e65d8ea"


class GamescopePackagePathTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="gamescope-package-test.")
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "source"
        self.source.mkdir()
        (self.source / ".github").mkdir()
        (self.source / "LICENSE").write_text("BSD-2-Clause fixture\n", encoding="utf-8")
        self.license_sha = hashlib.sha256(
            (self.source / "LICENSE").read_bytes()).hexdigest()
        self.manifest = self.source / ".github" / "meson-sources.lock"
        self.manifest.write_text(
            "# gamescope-meson-sources-v2\n"
            "libliftoff\tgitlink\t8b08dc1c14fd019cc90ddabe34ad16596b0691f4\t"
            "libliftoff.tar.gz\tlibliftoff\t" + "1" * 64 + "\t"
            "https://github.com/pocketforge-os/libliftoff/archive/"
            "8b08dc1c14fd019cc90ddabe34ad16596b0691f4.tar.gz\t"
            "subprojects/libliftoff\tLICENSE\t" + "2" * 64 + "\n",
            encoding="utf-8",
        )
        self.manifest_sha = hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.receipt = self.source / ".pf-gamescope-source.json"
        self.write_receipt()
        self.expected = gp.ExpectedSource(
            upstream_base=BASE,
            integrated_head=HEAD,
            present_head=PRESENT,
            staging_head=STAGING,
            rotation_head=ROTATION,
            patch_series_sha256=PATCHES,
            dependency_manifest_sha256=self.manifest_sha,
            license_sha256=self.license_sha,
        )

    def write_receipt(self, **changes: object) -> None:
        data: dict[str, object] = {
            "schema": "pocketforge.gamescope-source/v1",
            "source_url": "https://github.com/pocketforge-os/gamescope.git",
            "upstream_base": BASE,
            "integrated_head": HEAD,
            "patch_series_sha256": PATCHES,
            "required_heads": {
                "present": PRESENT,
                "staging": STAGING,
                "rotation": ROTATION,
            },
        }
        data.update(changes)
        self.receipt.write_text(json.dumps(data, sort_keys=True) + "\n", encoding="utf-8")

    def test_positive_source_and_identity(self) -> None:
        validated = gp.validate_source(self.source, self.expected)
        identity = gp.render_identity(
            validated,
            meson_options=(
                "avif_screenshots=disabled", "benchmark=disabled",
                "drm_backend=enabled", "enable_openvr_support=false",
                "enable_tests=false", "input_emulation=disabled",
                "pipewire=disabled", "rt_cap=disabled", "sdl2_backend=enabled",
                "wrap_mode=nodownload",
            ),
            target_arch="aarch64",
        )
        parsed = gp.parse_identity(identity)
        self.assertEqual(parsed["integrated_head"], HEAD)
        self.assertEqual(parsed["patch_series_sha256"], PATCHES)
        self.assertEqual(parsed["dependency_manifest_sha256"], self.manifest_sha)
        self.assertEqual(parsed["target_arch"], "aarch64")
        self.assertEqual(parsed["dependency.libliftoff"],
                         "8b08dc1c14fd019cc90ddabe34ad16596b0691f4")
        gp.verify_installed_identity(identity, identity)

    def test_missing_context_and_head_are_rejected(self) -> None:
        with self.assertRaisesRegex(gp.PackageInputError, "context is missing"):
            gp.validate_source(Path(self.temp.name) / "absent", self.expected)
        self.write_receipt(integrated_head="")
        with self.assertRaisesRegex(gp.PackageInputError, "integrated_head"):
            gp.validate_source(self.source, self.expected)

    def test_wrong_integration_and_stale_gap_heads_are_rejected(self) -> None:
        self.write_receipt(integrated_head="a" * 40)
        with self.assertRaisesRegex(gp.PackageInputError, "integration head mismatch"):
            gp.validate_source(self.source, self.expected)
        self.write_receipt(required_heads={
            "present": PRESENT, "staging": "b" * 40, "rotation": ROTATION})
        with self.assertRaisesRegex(gp.PackageInputError, "staging head mismatch"):
            gp.validate_source(self.source, self.expected)

    def test_upstream_fetch_and_dependency_drift_are_rejected(self) -> None:
        original = self.manifest.read_text(encoding="utf-8")
        self.manifest.write_text(
            original.replace("https://github.com/pocketforge-os/libliftoff",
                             "https://gitlab.freedesktop.org/emersion/libliftoff"),
            encoding="utf-8",
        )
        drifted = gp.ExpectedSource(**{
            **self.expected.__dict__,
            "dependency_manifest_sha256": hashlib.sha256(
                self.manifest.read_bytes()).hexdigest(),
        })
        with self.assertRaisesRegex(gp.PackageInputError, "non-PocketForge source URL"):
            gp.validate_source(self.source, drifted)
        self.manifest.write_text(original, encoding="utf-8")
        with self.assertRaisesRegex(gp.PackageInputError, "dependency manifest digest"):
            gp.validate_source(self.source, gp.ExpectedSource(**{
                **self.expected.__dict__, "dependency_manifest_sha256": "f" * 64}))

    def test_absent_licence_wrong_arch_and_identity_drift_are_rejected(self) -> None:
        (self.source / "LICENSE").unlink()
        with self.assertRaisesRegex(gp.PackageInputError, "Gamescope licence"):
            gp.validate_source(self.source, self.expected)
        with self.assertRaisesRegex(gp.PackageInputError, "not AArch64"):
            gp.validate_aarch64_elf("Machine: Advanced Micro Devices X86-64")
        gp.validate_aarch64_elf("Machine: AArch64")
        installed = (
            "schema=pocketforge.gamescope-build/v1\n"
            f"integrated_head={HEAD}\n"
        )
        drifted = (
            "schema=pocketforge.gamescope-build/v1\n"
            f"integrated_head={'a' * 40}\n"
        )
        with self.assertRaisesRegex(gp.PackageInputError, "installed identity drift"):
            gp.verify_installed_identity(installed, drifted)

    def test_profile_gate_is_exact_and_diagnostics_are_default_off(self) -> None:
        self.assertTrue(gp.profile_enabled("a133-open-7x-gpu", "g1"))
        for device in ("a133", "a133-open", "a133-open-7x-gpu-noradio", "a523"):
            self.assertFalse(gp.profile_enabled(device, "not-shipped"))
            self.assertFalse(gp.profile_enabled(device, "g1"))
        self.assertFalse(gp.diagnostics_enabled("g1", "release"))
        self.assertFalse(gp.diagnostics_enabled("g1", "dev"))
        self.assertTrue(gp.diagnostics_enabled("g1", "dev", explicit=True))

    def test_dockerfile_has_offline_profile_selected_producer(self) -> None:
        dockerfile = (ROOT / "build" / "Dockerfile.pf").read_text(encoding="utf-8")
        for required in (
            "FROM gamescope-${PF_GAMESCOPE_MODE} AS gamescope",
            "COPY --from=gamescope-src . /work/gamescope",
            "--wrap-mode=nodownload",
            "COPY --from=gamescope /out /work/gamescope-package",
        ):
            self.assertIn(required, dockerfile, required)
        self.assertNotIn("wrap-mode=forcefallback", dockerfile)


if __name__ == "__main__":
    unittest.main(verbosity=2)
