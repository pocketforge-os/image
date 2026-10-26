#!/usr/bin/env python3
"""Hermetic Debian-root and host-platform ABI contract tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
ROOT_BUILDER = ROOT / "scripts" / "build-debian-app-root.sh"
PLATFORM_BUILDER = ROOT / "scripts" / "build-app-platform-runtime.py"
PLATFORM_INSTALLER = ROOT / "scripts" / "install-app-platform-runtime.sh"
LOADER_VERIFIER = ROOT / "scripts" / "verify-app-runtime-loader.py"


def run(args: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        **kwargs,
    )


class DebianRootBuilderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pf-debian-root-test-")
        self.work = Path(self.temp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.log = self.work / "mmdebstrap.args"
        fixture = self.work / "fixture"
        (fixture / "etc").mkdir(parents=True)
        (fixture / "etc" / "os-release").write_text(
            "ID=debian\nVERSION_CODENAME=trixie\n", encoding="utf-8"
        )
        (self.bin / "mmdebstrap").write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu
                printf '%s\\n' "$@" >"$PF_TEST_LOG"
                output=
                suite=
                for argument in "$@"; do
                    case "$argument" in *.tar) output=$argument ;; esac
                    case "$argument" in bookworm|trixie) suite=$argument ;; esac
                done
                [ -n "$output" ] && [ -n "$suite" ]
                printf 'ID=debian\\nVERSION_CODENAME=%s\\n' "$suite" \\
                    >"$PF_TEST_FIXTURE/etc/os-release"
                tar -cf "$output" -C "$PF_TEST_FIXTURE" .
                """
            ),
            encoding="utf-8",
        )
        (self.bin / "mksquashfs").write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu
                source=$1
                output=$2
                test -f "$source/etc/os-release"
                cp "$source/etc/os-release" "$output"
                """
            ),
            encoding="utf-8",
        )
        for path in self.bin.iterdir():
            path.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{self.bin}:{self.env['PATH']}",
                "PF_TEST_LOG": str(self.log),
                "PF_TEST_FIXTURE": str(fixture),
            }
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def build(self, distribution: str, name: str) -> subprocess.CompletedProcess[str]:
        return run(
            [
                str(ROOT_BUILDER),
                "--distribution",
                distribution,
                "--architecture",
                "arm64",
                "--snapshot",
                "20261010T000000Z",
                "--package",
                "libstdc++6",
                "--output",
                str(self.work / name),
            ],
            env=self.env,
        )

    def test_trixie_and_bookworm_mapping_with_invalid_negative_control(self) -> None:
        trixie = self.build("debian-13", "trixie")
        self.assertEqual(trixie.returncode, 0, trixie.stderr)
        arguments = self.log.read_text(encoding="utf-8").splitlines()
        self.assertIn("trixie", arguments)
        self.assertNotIn("bookworm", arguments)
        self.assertTrue(any("20261010T000000Z" in item for item in arguments))
        metadata = json.loads(
            (self.work / "trixie" / "root.metadata.json").read_text(encoding="utf-8")
        )
        self.assertEqual(metadata["distribution"], "debian-13")
        self.assertEqual(metadata["suite"], "trixie")
        self.assertEqual(metadata["architecture"], "arm64")
        self.assertEqual(len(metadata["sha256"]), 64)

        bookworm = self.build("debian-12", "bookworm")
        self.assertEqual(bookworm.returncode, 0, bookworm.stderr)
        self.assertIn("bookworm", self.log.read_text(encoding="utf-8").splitlines())

        before = self.log.read_bytes()
        invalid = self.build("debian-14", "invalid")
        self.assertEqual(invalid.returncode, 64)
        self.assertIn("unsupported distribution", invalid.stderr)
        self.assertEqual(self.log.read_bytes(), before)
        self.assertFalse((self.work / "invalid").exists())


class PlatformRuntimeBuilderTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pf-platform-runtime-test-")
        self.work = Path(self.temp.name)
        self.host = self.work / "host"
        for relative in (
            "usr/local/lib/libpf_gpu.so.1",
            "usr/lib/aarch64-linux-gnu/libdrm.so.2",
            "lib/aarch64-linux-gnu/libc.so.6",
            "usr/share/vulkan/icd.d/pf.json",
        ):
            path = self.host / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
        (self.host / "usr/share/vulkan/icd.d/pf.json").write_text(
            json.dumps({"ICD": {"library_path": "/usr/local/lib/libpf_gpu.so.1"}}),
            encoding="utf-8",
        )
        self.config = self.work / "config.json"
        self.config.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "host_distribution": "debian-12",
                    "library_dirs": [
                        "usr/local/lib",
                        "usr/lib/aarch64-linux-gnu",
                        "lib/aarch64-linux-gnu",
                    ],
                    "base_sonames": ["libc.so.6"],
                    "seeds": ["usr/local/lib/libpf_gpu.so.1"],
                    "data": ["usr/share/vulkan/icd.d/pf.json"],
                    "json_library_paths": {
                        "usr/share/vulkan/icd.d/pf.json":
                            "/run/pocketforge/platform-runtime/usr/local/lib/libpf_gpu.so.1"
                    },
                }
            ),
            encoding="utf-8",
        )
        self.readelf = self.work / "readelf"
        self.readelf.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu
                for file in "$@"; do :; done
                case "$file" in
                  *libpf_gpu.so.1)
                    printf '%s\\n' ' 0x (SONAME) Library soname: [libpf_gpu.so.1]' \\
                      ' 0x (NEEDED) Shared library: [libdrm.so.2]' \\
                      ' 0x (NEEDED) Shared library: [libc.so.6]'
                    ;;
                  *libdrm.so.2)
                    printf '%s\\n' ' 0x (SONAME) Library soname: [libdrm.so.2]' \\
                      ' 0x (NEEDED) Shared library: [libc.so.6]'
                    ;;
                  *) printf '%s\\n' ' 0x (SONAME) Library soname: [libc.so.6]' ;;
                esac
                """
            ),
            encoding="utf-8",
        )
        self.readelf.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def build(self, output: Path) -> subprocess.CompletedProcess[str]:
        return run(
            [
                str(PLATFORM_BUILDER),
                "--host-root",
                str(self.host),
                "--config",
                str(self.config),
                "--output",
                str(output),
                "--readelf",
                str(self.readelf),
            ]
        )

    def test_recursive_non_base_closure_and_missing_negative_control(self) -> None:
        output = self.work / "runtime"
        result = self.build(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((output / "abi.json").read_text(encoding="utf-8"))
        self.assertEqual(
            sorted(manifest["sonames"]), ["libdrm.so.2", "libpf_gpu.so.1"]
        )
        self.assertEqual(manifest["root_provided_sonames"], ["libc.so.6"])
        self.assertEqual(manifest["base_abi_sonames"], ["libc.so.6"])
        self.assertTrue((output / "usr" / "local" / "lib" / "libpf_gpu.so.1").is_file())
        self.assertTrue((output / "usr" / "lib" / "aarch64-linux-gnu" / "libdrm.so.2").is_file())
        self.assertTrue((output / "usr" / "share" / "vulkan" / "icd.d" / "pf.json").is_file())
        discovery = json.loads(
            (output / "usr/share/vulkan/icd.d/pf.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            discovery["ICD"]["library_path"],
            "/run/pocketforge/platform-runtime/usr/local/lib/libpf_gpu.so.1",
        )
        self.assertEqual(
            manifest["json_library_paths"]["usr/share/vulkan/icd.d/pf.json"],
            discovery["ICD"]["library_path"],
        )

        (self.host / "usr/lib/aarch64-linux-gnu/libdrm.so.2").unlink()
        failed = self.build(self.work / "missing")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("unresolved non-base dependency: libdrm.so.2", failed.stderr)
        self.assertFalse((self.work / "missing").exists())

        (self.host / "usr/lib/aarch64-linux-gnu/libdrm.so.2").write_bytes(b"libdrm")
        value = json.loads(self.config.read_text(encoding="utf-8"))
        value["json_library_paths"]["usr/share/vulkan/icd.d/pf.json"] = (
            "/usr/local/lib/libpf_gpu.so.1"
        )
        self.config.write_text(json.dumps(value), encoding="utf-8")
        escaped = self.build(self.work / "escaped")
        self.assertNotEqual(escaped.returncode, 0)
        self.assertIn("non-canonical platform runtime library path", escaped.stderr)
        self.assertFalse((self.work / "escaped").exists())

    def test_installer_publishes_dri3_closure_into_shipped_store(self) -> None:
        for relative in (
            "usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0",
            "usr/lib/aarch64-linux-gnu/libxcb-present.so.0",
            "usr/lib/aarch64-linux-gnu/libxshmfence.so.1",
        ):
            path = self.host / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
        config = self.work / "dri3-config.json"
        config.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "host_distribution": "debian-12",
                    "library_dirs": ["usr/lib/aarch64-linux-gnu"],
                    "base_sonames": ["libc.so.6"],
                    "seeds": [
                        "usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0",
                        "usr/lib/aarch64-linux-gnu/libxcb-present.so.0",
                        "usr/lib/aarch64-linux-gnu/libxshmfence.so.1",
                    ],
                    "data": [],
                    "json_library_paths": {},
                }
            ),
            encoding="utf-8",
        )
        readelf = self.work / "dri3-readelf"
        readelf.write_text(
            textwrap.dedent(
                """#!/bin/sh
                set -eu
                for file in "$@"; do :; done
                case "$file" in
                  *libxcb-dri3.so.0) soname=libxcb-dri3.so.0 ;;
                  *libxcb-present.so.0) soname=libxcb-present.so.0 ;;
                  *libxshmfence.so.1) soname=libxshmfence.so.1 ;;
                  *) soname=libc.so.6 ;;
                esac
                printf ' 0x (SONAME) Library soname: [%s]\n' "$soname"
                printf ' 0x (NEEDED) Shared library: [libc.so.6]\n'
                """
            ),
            encoding="utf-8",
        )
        readelf.chmod(0o755)
        rootfs = self.work / "rootfs"
        rootfs.mkdir()
        result = run(
            [str(PLATFORM_INSTALLER), str(config), str(self.host), str(rootfs)],
            env={"PATH": os.environ["PATH"], "PF_APP_RUNTIME_READELF": str(readelf)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("app-platform-runtime=PASS", result.stdout)
        stores = list(
            (rootfs / "usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64").glob(
                "sha256-*"
            )
        )
        self.assertEqual(len(stores), 1)
        store = stores[0]
        self.assertTrue((store / ".manifest-sha256").is_file())
        for relative in (
            "usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0",
            "usr/lib/aarch64-linux-gnu/libxcb-present.so.0",
            "usr/lib/aarch64-linux-gnu/libxshmfence.so.1",
        ):
            self.assertTrue((store / relative).is_file(), relative)


class LoaderVerifierTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pf-loader-trace-test-")
        self.work = Path(self.temp.name)
        self.manifest = self.work / "abi.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "sonames": {
                        "libpf_gpu.so.1": "usr/local/lib/libpf_gpu.so.1",
                        "libdrm.so.2": "usr/lib/aarch64-linux-gnu/libdrm.so.2",
                    },
                    "root_provided_sonames": ["libc.so.6", "libstdc++.so.6"],
                    "base_abi_sonames": ["libc.so.6", "libstdc++.so.6"],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def verify(self, trace: str) -> subprocess.CompletedProcess[str]:
        path = self.work / "trace.txt"
        path.write_text(trace, encoding="utf-8")
        return run(
            [
                str(LOADER_VERIFIER),
                "--manifest",
                str(self.manifest),
                "--trace",
                str(path),
                "--platform-prefix",
                "/run/pocketforge/platform-runtime",
            ]
        )

    def test_positive_missing_and_shadow_controls_share_one_matrix(self) -> None:
        positive = self.verify(
            textwrap.dedent(
                """\
                libpf_gpu.so.1 => /run/pocketforge/platform-runtime/usr/local/lib/libpf_gpu.so.1 (0x1)
                libdrm.so.2 => /run/pocketforge/platform-runtime/usr/lib/aarch64-linux-gnu/libdrm.so.2 (0x2)
                libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x3)
                """
            )
        )
        self.assertEqual(positive.returncode, 0, positive.stderr)
        self.assertIn("loader-closure=PASS", positive.stdout)

        missing = self.verify(
            "libpf_gpu.so.1 => /run/pocketforge/platform-runtime/usr/local/lib/libpf_gpu.so.1 (0x1)\n"
            "libdrm.so.2 => not found\n"
        )
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("not found", missing.stderr)

        shadowed = self.verify(
            "libpf_gpu.so.1 => /run/pocketforge/platform-runtime/usr/local/lib/libpf_gpu.so.1 (0x1)\n"
            "libdrm.so.2 => /usr/lib/aarch64-linux-gnu/libdrm.so.2 (0x2)\n"
            "libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x3)\n"
        )
        self.assertNotEqual(shadowed.returncode, 0)
        self.assertIn("resolved outside platform runtime", shadowed.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
