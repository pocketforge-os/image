#!/usr/bin/env python3
"""Version/sha guard for the generated Steam Link NEEDED closure manifest.

A Steam Link version bump (fetcher minimum floor or app.toml version moving past
the manifest) must fail CI until scripts/steamlink-needed-closure.py is re-run.
Negative tests prove the guard and the tool actually refuse mismatches.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "build/steamlink-shell-needed-closure.json"
TOOL = ROOT / "scripts/steamlink-needed-closure.py"
SEEDS = ROOT / "build/app-platform-runtime-a133-open-v1.json"


def vt(value):
    return tuple(int(p) for p in value.split("."))


def fetcher():
    spec = importlib.util.spec_from_file_location("sf", ROOT / "apps/steamlink/steamlink-fetch.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def guard(manifest, floor, app_version, seeds):
    """Return a list of problems; empty means the manifest is current."""
    problems = []
    if len(manifest.get("archive_sha256", "")) != 64:
        problems.append("manifest archive_sha256 missing")
    if vt(manifest["version"]) < vt(floor):
        problems.append("manifest older than fetcher floor")
    if vt(manifest["version"]) < vt(app_version):
        problems.append("manifest older than app.toml version")
    provided = {Path(s).name for s in seeds} | set(manifest["runtime_binds"])
    problems += [f"unseeded {s}" for s in manifest["unresolved"] if s not in provided]
    return problems


class ClosureGuardTest(unittest.TestCase):
    def inputs(self):
        manifest = json.loads(MANIFEST.read_text())
        floor = fetcher().DEFAULT_MINIMUM_VERSION
        app = tomllib.loads((ROOT / "apps/steamlink/app.toml").read_text())["app"]["version"]
        seeds = json.loads(SEEDS.read_text())["seeds"]
        return manifest, floor, app, seeds

    def test_committed_manifest_is_current(self):
        self.assertEqual(guard(*self.inputs()), [])

    def test_manifest_records_signature_verification_and_every_elf(self):
        manifest = self.inputs()[0]
        self.assertTrue(manifest["signature_verified"])
        self.assertGreater(manifest["elf_count"], 0)
        for soname in manifest["unresolved"]:
            self.assertTrue(manifest["provenance"][soname], soname)

    def test_version_bump_fails_until_regenerated(self):
        manifest, floor, app, seeds = self.inputs()
        self.assertTrue(guard(manifest, "1.99.0.1", app, seeds))
        self.assertTrue(guard(manifest, floor, "1.99.0.1", seeds))

    def test_unseeded_soname_fails(self):
        manifest, floor, app, seeds = self.inputs()
        broken = dict(manifest, unresolved=manifest["unresolved"] + ["libnew.so.9"])
        self.assertIn("unseeded libnew.so.9", guard(broken, floor, app, seeds))

    def test_tool_refuses_archive_sha_mismatch(self):
        with tempfile.TemporaryDirectory() as scratch:
            archive = Path(scratch) / "steamlink-rpi-bookworm-arm64-1.4.5.327.tar.gz"
            archive.write_bytes(b"not the pinned archive")
            sig = Path(scratch) / "a.sig"
            sig.write_bytes(b"x")
            result = subprocess.run(
                [sys.executable, "-I", str(TOOL), "--archive", str(archive), "--signature", str(sig),
                 "--expected-sha256", self.inputs()[0]["archive_sha256"], "--check"],
                capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 70)
        self.assertIn("refused", result.stderr)

    def test_tool_refuses_bad_signature(self):
        # Correct name, wrong content and no expected sha: signature gate refuses.
        with tempfile.TemporaryDirectory() as scratch:
            archive = Path(scratch) / "steamlink-rpi-bookworm-arm64-1.4.5.327.tar.gz"
            archive.write_bytes(b"forged")
            sig = Path(scratch) / "a.sig"
            sig.write_bytes(b"forged")
            result = subprocess.run(
                [sys.executable, "-I", str(TOOL), "--archive", str(archive), "--signature", str(sig), "--check"],
                capture_output=True, text=True,
            )
        self.assertEqual(result.returncode, 70)
        self.assertIn("signature_invalid", result.stderr)


if __name__ == "__main__":
    unittest.main()
