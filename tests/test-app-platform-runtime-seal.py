#!/usr/bin/env python3
"""Exercise production packaging with real DWARF, ABI hashes and CAS aliases."""

import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "build/app-platform-runtime-a133-open-v1.json"
SCRIPTS = ROOT / "scripts"
ELF = runpy.run_path(str(SCRIPTS / "pf-elf-buildid.py"))
RENDERER = runpy.run_path(str(SCRIPTS / "render-app-runtime-root.py"))


class RuntimeSealTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pf-runtime-seal-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.root = self.work / "rootfs"
        self.out = self.work / "out"
        self.config = json.loads(CONFIG.read_text())
        source = self.work / "fixture.c"
        source.write_text("int fixture(void) { return 42; }\n")
        for relative in self.config["seeds"]:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            self.run_ok(["cc", "-g", "-shared", "-nostdlib", "-Wl,--build-id=sha1",
                         f"-Wl,-soname,{target.name}", str(source), "-o", str(target)])
            self.assertTrue(ELF["has_debug_info"](target))
        alias = self.root / "usr/local/lib/dri/zink_dri.so"
        alias.symlink_to("../libgallium_dri.so")
        for relative in self.config["data"]:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if relative in self.config["json_library_paths"]:
                target.write_text('{"ICD":{"library_path":"/host/library.so"}}\n')
            elif not target.exists():
                target.write_text("owned fixture data\n")
        # Keep root-image construction and policy compilation bounded; all ELF,
        # ABI, CAS, descriptor substitution and root rendering remain production.
        self.root_builder = self.work / "root-builder"
        self.root_builder.write_text('''#!/usr/bin/env python3
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
out.mkdir()
data = b"opaque app-root fixture\\n"
(out / "root.raw").write_bytes(data)
(out / "root.metadata.json").write_text(json.dumps({"schema_version":1,
 "distribution":"debian-13", "suite":"trixie", "architecture":"arm64",
 "sha256":hashlib.sha256(data).hexdigest()}))
''')
        self.root_builder.chmod(0o755)
        self.policy_renderer = self.work / "policy-renderer"
        self.policy_renderer.write_text('''#!/usr/bin/env python3
import sys
if sys.argv[-1] == "json":
 print('{"app_id":"org.pocketforge.steamlink","schema_version":1}')
else:
 print("[Service]\\nNoNewPrivileges=yes")
''')
        self.policy_renderer.chmod(0o755)
        (self.root / "usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1").mkdir(parents=True)
        contract = self.root / "usr/share/pocketforge/platform-capabilities.toml"
        contract.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "tests/fixtures/app-policy/platform-capabilities-a133-open.toml", contract)
        self.env = dict(os.environ, PF_OBJCOPY=shutil.which("objcopy"),
                        PF_STRIP=shutil.which("strip"), SRC_DIR=str(ROOT),
                        ROOTFS_EXTRACTED=str(self.root), OUT_DIR=str(self.out),
                        APP_PLATFORM_RUNTIME_CONFIG=str(CONFIG), SNAPSHOT_DATE="20261010T000000Z",
                        PF_STEAMLINK_ROOT_BUILDER=str(self.root_builder),
                        PF_STEAMLINK_POLICY_RENDERER=str(self.policy_renderer))

    def run_ok(self, args, **kwargs):
        result = subprocess.run(args, capture_output=True, text=True, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def finalize(self, *args):
        self.run_ok([str(SCRIPTS / "finalize-elf-debuginfo.sh"), str(self.root),
                     str(self.out), *args], env=self.env)

    def install(self):
        self.run_ok([str(SCRIPTS / "install-app-platform-runtime.sh"), str(CONFIG),
                     str(self.root), str(self.root)], env=self.env)

    def platform(self):
        return next((self.root / "usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64").glob("sha256-*"))

    def snapshot(self, tree):
        return {str(p.relative_to(tree)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in tree.rglob("*") if p.is_file() and not p.is_symlink()}

    def test_old_order_changes_real_elf_bytes_and_breaks_abi_and_cas(self):
        self.install()
        platform = self.platform()
        before = self.snapshot(platform)
        # The image build runs as root. Permit the same mutation in this
        # unprivileged negative control; chmod does not affect the CAS bytes.
        for path in [platform, *platform.rglob("*")]:
            path.chmod(0o755 if path.is_dir() else 0o644)
        self.finalize()
        after = self.snapshot(platform)
        abi = json.loads((platform / "abi.json").read_text())
        for relative, metadata in abi["files"].items():
            self.assertNotEqual(before[relative], after[relative], relative)
            self.assertNotEqual(metadata["sha256"], after[relative], relative)
        alias = "usr/local/lib/dri/zink_dri.so"
        self.assertNotEqual(abi["data"][alias], after[alias])
        self.assertNotEqual(RENDERER["platform_manifest_digest"](platform), platform.name[7:])
        result = subprocess.run(["python3", str(SCRIPTS / "verify-app-platform-runtime.py"),
                                 str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("platform_runtime_incompatible", result.stderr)
        print("RED old ordering: DWARF strip invalidates every ELF ABI hash, data alias and CAS")

    def test_production_order_keeps_seal_and_complete_debug_manifest(self):
        # Execute the real command blocks in their production source order.
        # This catches moving the split back after sealing, or omitting the
        # final read-only pass, without running a privileged rootfs build.
        source = (SCRIPTS / "build-rootfs.sh").read_text().replace("\\\n", " ")
        split_position = source.index('"${SRC_DIR}/scripts/finalize-elf-debuginfo.sh"')
        for verifier in ("verify-mesa-shader-cache.sh", "verify-open-gpu-provider.sh",
                         "verify-open-gpu-tools.sh"):
            # These gates compare unstripped producer hashes/static symbols.
            self.assertLess(source.rindex(f'"${{SRC_DIR}}/scripts/{verifier}"'), split_position)
        commands = re.findall(
            r'(?:python3 )?"\$\{SRC_DIR\}/scripts/'
            r'(?:finalize-elf-debuginfo\.sh|install-app-platform-runtime\.sh|'
            r'install-steamlink-first-run\.sh|verify-app-platform-runtime\.py)"'
            r'[^\n]*', source)
        self.assertEqual(len(commands), 5)
        self.assertIn("finalize-elf-debuginfo.sh", commands[0])
        self.assertIn("--manifest-only", commands[3])
        for command in commands[:3]:
            self.run_ok(["bash", "-euc", command], env=self.env)
        platform = self.platform()
        before = self.snapshot(platform)
        store_before = self.snapshot(self.out / "pf-debuginfo")
        for command in commands[3:]:
            self.run_ok(["bash", "-euc", command], env=self.env)
        self.assertEqual(before, self.snapshot(platform))
        self.assertEqual(store_before, self.snapshot(self.out / "pf-debuginfo"))
        abi = json.loads((platform / "abi.json").read_text())
        for relative, metadata in abi["files"].items():
            self.assertEqual(before[relative], metadata["sha256"])
        for relative, digest in abi["data"].items():
            self.assertEqual(before[relative], digest)
        self.assertEqual(platform.name, "sha256-" + RENDERER["platform_manifest_digest"](platform))
        manifest = (self.out / "pf-elf-build-id-manifest.tsv").read_text()
        actual = {(build_id, path) for build_id, path in
                  (line.split("\t") for line in manifest.splitlines() if not line.startswith("#"))}
        expected = set()
        for path, relative in ELF["iter_elves"](str(self.root), []):
            build_id = ELF["build_id_of"](path)
            expected.add((build_id, relative))
            self.assertFalse(ELF["has_debug_info"](path), relative)
            debug = self.out / "pf-debuginfo/buildid" / build_id[:2] / build_id[2:] / "debuginfo"
            self.assertTrue(ELF["has_debug_info"](debug), relative)
        self.assertEqual(actual, expected)
        self.assertTrue(any("/sha256-" in relative for _, relative in actual))
        self.assertEqual(manifest, (self.root / "usr/share/pocketforge/elf-build-id-manifest.tsv").read_text())
        dropin = self.root / "etc/systemd/system/pf-app@org.pocketforge.steamlink.service.d/20-runtime-root.conf"
        self.assertIn(f"/{platform.relative_to(self.root)}:/run/pocketforge/platform-runtime", dropin.read_text())
        descriptor = self.root / "opt/pocketforge/apps/org.pocketforge.steamlink/app.toml"
        original = descriptor.read_text()
        descriptor.write_text(original.replace(platform.name[7:], "0" * 64))
        result = subprocess.run(["python3", str(SCRIPTS / "verify-app-platform-runtime.py"),
                                 str(self.root)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        descriptor.write_text(original)
        # Last gate is read-only and catches corruption in every recorded class.
        for relative in [*abi["files"], *abi["data"], ".manifest-sha256"]:
            with self.subTest(corrupt=relative):
                path = platform / relative
                original = path.read_bytes()
                path.chmod(0o644)
                path.write_bytes(original + b"corrupt")
                result = subprocess.run(["python3", str(SCRIPTS / "verify-app-platform-runtime.py"),
                                         str(self.root)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, relative)
                path.write_bytes(original)
        print(f"GREEN production ordering: files={len(abi['files'])} data={len(abi['data'])} final_manifest={len(actual)}")


if __name__ == "__main__":
    unittest.main()
