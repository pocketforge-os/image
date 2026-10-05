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


BASE = "bb2ddfc8b1091d6c4d0133b1ea9dcd2494b69ab9"
HEAD = "4232739e75c95113871e260967e8b4ff995ea897"
PRESENT = "b1d220453331e28554d938f060156abfeb504757"
STAGING = "a5b1f4697a13e671f9e8bfd108c3003987ca1fa4"
ROTATION = "eb3ae2c705326b0c6535ea99ee233c17a170ace4"
PATCHES = "cf0736049af178c1e94fd40bea54a28d309010c65d07fb3a981e130395a9508c"


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
        self.manifest = self.source / ".github" / "pocketforge-source-closure.tsv"
        header = "\t".join(gp.MANIFEST_FIELDS)
        rows = []
        # 31 materialized Git edges, 29 distinct Git pins, and three distinct
        # snapshots reproduce the landed 34-edge/32-pin closure shape.
        projects = [f"dep{index:02d}" for index in range(29)] + ["dep00", "dep01"]
        for index, project in enumerate(projects):
            revision = f"{int(project[3:]) + 1:040x}"
            license_bytes = f"licence for {project}\n".encode()
            license_sha = hashlib.sha256(license_bytes).hexdigest()
            bundle = self.source / ".pf-source-licenses" / (
                f"{project}-{revision[:12]}-LICENSE")
            bundle.parent.mkdir(exist_ok=True)
            bundle.write_bytes(license_bytes)
            rows.append(self.manifest_row(
                edge_id=f"edge-{index:02d}", project=project,
                revision=revision, kind="gitlink",
                path=f"subprojects/{project}-{index:02d}",
                license_sha=license_sha,
            ))
        for index in range(3):
            project = f"snapshot{index}"
            revision = f"{100 + index:040x}"
            license_bytes = f"licence for {project}\n".encode()
            license_sha = hashlib.sha256(license_bytes).hexdigest()
            bundle = self.source / ".pf-source-licenses" / (
                f"{project}-{revision[:12]}-LICENSE")
            bundle.write_bytes(license_bytes)
            rows.append(self.manifest_row(
                edge_id=f"snapshot-{index}", project=project,
                revision=revision, kind="vendored-snapshot",
                path=f"thirdparty/{project}.hpp", license_sha=license_sha,
            ))
        self.manifest.write_text(
            "# gamescope-source-closure-v1\n" + header + "\n" +
            "\n".join(rows) + "\n", encoding="utf-8")
        self.manifest_sha = hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.receipt = self.source / ".pf-gamescope-source.json"
        source_tree_sha = gp._source_tree_sha256(self.source)
        self.admission = self.source / ".pf-gamescope-admission.json"
        self.admission.write_text(json.dumps({
            "schema": "gamescope-source-admission-v1",
            "gamescope_head": HEAD,
            "manifest_sha256": self.manifest_sha,
            "projects": [],
            "validated_edges": 34,
            "verified_project_pins": 32,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        self.materialization = self.source / ".pf-gamescope-materialization.json"
        self.materialization.write_text(json.dumps({
            "schema": "gamescope-source-materialization-v1",
            "gamescope_head": HEAD,
            "generated_root_wrap_aliases": 2,
            "manifest_sha256": self.manifest_sha,
            "materialized_git_inputs": 31,
            "normalized_gitlink_urls": 19,
            "source_tree_sha256": source_tree_sha,
            "verified_materialized_locator_targets": 33,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        self.write_receipt(
            dependency_manifest_sha256=self.manifest_sha,
            admission_receipt_sha256=hashlib.sha256(
                self.admission.read_bytes()).hexdigest(),
            materialization_receipt_sha256=hashlib.sha256(
                self.materialization.read_bytes()).hexdigest(),
            source_tree_sha256=source_tree_sha,
        )
        self.expected = gp.ExpectedSource(
            upstream_base=BASE,
            integrated_head=HEAD,
            present_head=PRESENT,
            staging_head=STAGING,
            rotation_head=ROTATION,
            patch_series_sha256=PATCHES,
            dependency_manifest_sha256=self.manifest_sha,
            source_tree_sha256=source_tree_sha,
            license_sha256=self.license_sha,
        )

    @staticmethod
    def manifest_row(*, edge_id: str, project: str, revision: str,
                     kind: str, path: str, license_sha: str) -> str:
        values = {
            "schema": "1", "edge_id": edge_id, "parent_id": "gamescope",
            "project_id": project, "path": path, "kind": kind,
            "upstream_url": f"https://example.invalid/{project}.git",
            "upstream_revision": revision, "declared_url": "-",
            "locator_revision": revision,
            "pf_url": f"https://github.com/pocketforge-os/{project}.git",
            "pf_revision": revision, "tree_oid": revision,
            "content_sha256": "-", "license_path": "LICENSE",
            "license_sha256": license_sha, "selectors": "native,aarch64",
            "tests": "fixture", "patch_status": "exact",
            "transform_receipt": "-", "fork_history_proof": "-",
            "fork_pin_ref": "refs/heads/pocketforge",
        }
        return "\t".join(values[field] for field in gp.MANIFEST_FIELDS)

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
        meson_configuration = gp.MesonSetupConfiguration(
            source=Path("/work/gamescope"),
            build_dir=Path("/work/gamescope/build-aarch64"),
            cross_file=Path("/work/aarch64.ini"),
        )
        identity = gp.render_identity(
            validated,
            meson_configuration=meson_configuration,
            target_arch="aarch64",
        )
        parsed = gp.parse_identity(identity)
        self.assertEqual(parsed["integrated_head"], HEAD)
        self.assertEqual(parsed["patch_series_sha256"], PATCHES)
        self.assertEqual(parsed["dependency_manifest_sha256"], self.manifest_sha)
        self.assertEqual(parsed["source_tree_sha256"],
                         self.expected.source_tree_sha256)
        self.assertEqual(parsed["meson_cross_file_sha256"],
                         meson_configuration.cross_file_digest())
        self.assertEqual(parsed["target_arch"], "aarch64")
        self.assertEqual(parsed["dependency.dep00.000000000000"],
                         f"{1:040x}")
        self.assertEqual(parsed["dependency_edges"], "34")
        self.assertEqual(parsed["dependency_project_pins"], "32")
        self.assertEqual(parsed["verified_locator_targets"], "33")
        gp.verify_installed_identity(identity, identity)
        licenses = Path(self.temp.name) / "licenses"
        gp.install_licenses(self.source, validated, licenses)
        self.assertEqual(len(list(licenses.iterdir())), 34)

    def test_meson_identity_tracks_exact_setup_argv_and_cross_file(self) -> None:
        base = gp.MesonSetupConfiguration(
            source=Path("/work/gamescope"),
            build_dir=Path("/work/gamescope/build-aarch64"),
            cross_file=Path("/work/aarch64.ini"),
        )
        self.assertIn("--wrap-mode=nodownload", base.argv())
        self.assertIn("--buildtype=release", base.argv())
        self.assertIn("--prefix=/usr", base.argv())
        self.assertIn("--auto-features=enabled", base.argv())
        self.assertNotIn("upstream_tests=enabled", base.canonical_bytes().decode())

        variants = (
            gp.MesonSetupConfiguration(
                source=base.source, build_dir=base.build_dir,
                cross_file=base.cross_file, buildtype="debug"),
            gp.MesonSetupConfiguration(
                source=base.source, build_dir=base.build_dir,
                cross_file=base.cross_file, prefix="/opt/pocketforge"),
            gp.MesonSetupConfiguration(
                source=base.source, build_dir=base.build_dir,
                cross_file=base.cross_file, auto_features="disabled"),
            gp.MesonSetupConfiguration(
                source=base.source, build_dir=base.build_dir,
                cross_file=base.cross_file, wrap_mode="forcefallback"),
            gp.MesonSetupConfiguration(
                source=base.source, build_dir=base.build_dir,
                cross_file=Path("/work/alternate-aarch64.ini")),
            gp.MesonSetupConfiguration(
                source=base.source, build_dir=base.build_dir,
                cross_file=base.cross_file,
                cross_file_bytes=base.cross_file_bytes + b"# changed\n"),
        )
        for variant in variants:
            with self.subTest(argv=variant.argv()):
                self.assertNotEqual(base.digest(), variant.digest())
        with self.assertRaises(TypeError):
            gp.MesonSetupConfiguration(
                source=base.source, build_dir=base.build_dir,
                cross_file=base.cross_file,
                upstream_tests="enabled",  # type: ignore[call-arg]
            )

    def test_configure_build_uses_one_configuration_for_setup_and_identity(self) -> None:
        calls: list[tuple[str, ...]] = []

        def runner(argv: tuple[str, ...], *, check: bool) -> None:
            self.assertTrue(check)
            calls.append(argv)

        build_dir = Path(self.temp.name) / "build-aarch64"
        cross_file = Path(self.temp.name) / "aarch64.ini"
        identity_out = Path(self.temp.name) / "gamescope-build-id"
        configuration = gp.MesonSetupConfiguration(
            source=self.source, build_dir=build_dir, cross_file=cross_file)
        gp.configure_build(
            self.source, self.expected,
            build_dir=build_dir,
            cross_file=cross_file,
            identity_out=identity_out,
            runner=runner,
        )

        self.assertEqual(calls, [configuration.argv()])
        self.assertEqual(cross_file.read_bytes(),
                         configuration.normalized_cross_file_bytes())
        identity = gp.parse_identity(identity_out.read_text(encoding="utf-8"))
        self.assertEqual(identity["meson_options_sha256"], configuration.digest())

    def test_dependency_license_bundle_drift_is_rejected(self) -> None:
        bundle = next((self.source / ".pf-source-licenses").iterdir())
        bundle.write_text("drift\n", encoding="utf-8")
        with self.assertRaisesRegex(gp.PackageInputError, "licence bundle digest"):
            gp.validate_source(self.source, self.expected)

    def test_self_consistent_tree_and_receipt_rewrite_is_externally_rejected(self) -> None:
        locked_tree = gp._source_tree_sha256(self.source)
        locked_expected = gp.ExpectedSource(**{
            **self.expected.__dict__,
            "source_tree_sha256": locked_tree,
        })
        (self.source / "meson.build").write_text(
            "project('tampered-gamescope')\n", encoding="utf-8")
        tampered_tree = gp._source_tree_sha256(self.source)
        self.assertNotEqual(tampered_tree, locked_tree)

        materialization = json.loads(self.materialization.read_text(encoding="utf-8"))
        materialization["source_tree_sha256"] = tampered_tree
        self.materialization.write_text(
            json.dumps(materialization, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        source_receipt = json.loads(self.receipt.read_text(encoding="utf-8"))
        source_receipt["source_tree_sha256"] = tampered_tree
        source_receipt["materialization_receipt_sha256"] = hashlib.sha256(
            self.materialization.read_bytes()).hexdigest()
        self.receipt.write_text(
            json.dumps(source_receipt, sort_keys=True) + "\n", encoding="utf-8")

        with self.assertRaisesRegex(
                gp.PackageInputError, "platform-locked source-tree digest mismatch"):
            gp.validate_source(self.source, locked_expected)

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
            original.replace("https://github.com/pocketforge-os/dep00",
                             "https://gitlab.freedesktop.org/example/dep00"),
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
            "ARG PF_GAMESCOPE_SOURCE_TREE_SHA256",
            "COPY --from=gamescope-src . /work/gamescope",
            "--source-tree-sha256 ${PF_GAMESCOPE_SOURCE_TREE_SHA256}",
            "configure-build ${common_args}",
            "--wrap-mode=nodownload",
            "COPY --from=gamescope /out /work/gamescope-package",
        ):
            self.assertIn(required, dockerfile, required)
        self.assertNotIn("--meson-option", dockerfile)
        self.assertNotIn("upstream_tests=enabled", dockerfile)
        self.assertNotIn("cat > /work/aarch64.ini", dockerfile)
        self.assertNotIn("meson setup /work/gamescope/build-aarch64", dockerfile)
        self.assertNotIn("wrap-mode=forcefallback", dockerfile)
        self.assertNotIn("gamescope-deps", dockerfile)
        self.assertNotIn("prime-meson-sources.sh", dockerfile)


if __name__ == "__main__":
    unittest.main(verbosity=2)
