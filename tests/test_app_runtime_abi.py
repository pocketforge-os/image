#!/usr/bin/env python3
"""Hermetic Debian-root and host-platform ABI contract tests."""

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import stat
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
        (fixture / "etc" / "resolv.conf").write_text(
            "nameserver 192.168.151.1\n", encoding="utf-8"
        )
        (self.bin / "mmdebstrap").write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                set -eu
                printf '%s\\n' "$@" >"$PF_TEST_LOG"
                output=
                suite=
                mirror=
                for argument in "$@"; do
                    case "$argument" in *.tar) output=$argument ;; esac
                    case "$argument" in bookworm|trixie) suite=$argument ;; esac
                    case "$argument" in http://*|https://*) mirror=$argument ;; esac
                done
                [ -n "$output" ] && [ -n "$suite" ] && [ -n "$mirror" ]
                printf 'ID=debian\\nVERSION_CODENAME=%s\\n' "$suite" \\
                    >"$PF_TEST_FIXTURE/etc/os-release"
                # Like the real mmdebstrap, persist the mirror it was given in the root's apt sources.
                mkdir -p "$PF_TEST_FIXTURE/etc/apt"
                printf 'deb %s %s main\\n' "$mirror" "$suite" \\
                    >"$PF_TEST_FIXTURE/etc/apt/sources.list"
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
                if [ -n "${PF_TEST_OVERLAY_EXPECT:-}" ]; then
                    test -f "$source/$PF_TEST_OVERLAY_EXPECT"
                fi
                if [ -n "${PF_TEST_RESOLV_EXPECT:-}" ]; then
                    test "$(cat "$source/etc/resolv.conf")" = "$PF_TEST_RESOLV_EXPECT"
                    ! grep -R -F '192.168.151.1' "$source"
                fi
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

    def test_systemd_resolved_stub_replaces_build_resolver(self) -> None:
        env = dict(self.env)
        env["PF_TEST_RESOLV_EXPECT"] = "nameserver 127.0.0.53"
        result = run(
            [
                str(ROOT_BUILDER), "--distribution", "debian-13", "--architecture", "arm64",
                "--snapshot", "20261010T000000Z", "--systemd-resolved-stub",
                "--output", str(self.work / "resolved-stub"),
            ],
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_overlay_is_included_and_symlinks_are_refused(self) -> None:
        overlay = self.work / "overlay"
        (overlay / "opt/app").mkdir(parents=True)
        (overlay / "opt/app/fetcher").write_text("source-owned\n", encoding="utf-8")
        env = dict(self.env)
        env["PF_TEST_OVERLAY_EXPECT"] = "opt/app/fetcher"
        result = run(
            [
                str(ROOT_BUILDER), "--distribution", "debian-13", "--architecture", "arm64",
                "--snapshot", "20261010T000000Z", "--overlay", str(overlay),
                "--output", str(self.work / "overlay-root"),
            ],
            env=env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        (overlay / "unsafe").symlink_to("fetcher")
        refused = run(
            [
                str(ROOT_BUILDER), "--distribution", "debian-13", "--architecture", "arm64",
                "--snapshot", "20261010T000000Z", "--overlay", str(overlay),
                "--output", str(self.work / "unsafe-root"),
            ],
            env=self.env,
        )
        self.assertEqual(refused.returncode, 65)
        self.assertIn("overlay contains a link", refused.stderr)
        self.assertFalse((self.work / "unsafe-root").exists())


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
        rootfs.mkdir(mode=0o700)
        result = run(
            [
                "sh", "-c", 'umask 077; exec "$@"', "runtime-installer",
                str(PLATFORM_INSTALLER), str(config), str(self.host), str(rootfs),
            ],
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
        publication_path = [
            rootfs,
            rootfs / "usr",
            rootfs / "usr/lib",
            rootfs / "usr/lib/pocketforge",
            rootfs / "usr/lib/pocketforge/platform-runtimes",
            store.parent,
        ]
        for path in publication_path:
            mode = stat.S_IMODE(path.stat().st_mode)
            self.assertTrue(
                mode & stat.S_IXOTH,
                f"unprivileged app cannot traverse {path.relative_to(rootfs)}: {mode:o}",
            )
        self.assertTrue((store / ".manifest-sha256").is_file())
        entries = sorted(
            store.rglob("*"), key=lambda path: path.relative_to(store).as_posix()
        )
        lines = []
        for path in entries:
            relative = path.relative_to(store).as_posix()
            if path.is_dir() or relative == ".manifest-sha256":
                continue
            self.assertTrue(path.is_file(), relative)
            lines.append(
                f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}\n"
            )
        expected_digest = hashlib.sha256("".join(lines).encode()).hexdigest()
        self.assertEqual(
            (store / ".manifest-sha256").read_text(encoding="utf-8").strip(),
            expected_digest,
        )
        self.assertEqual(store.name, f"sha256-{expected_digest}")
        installed_paths = [store, *store.rglob("*")]
        for path in installed_paths:
            mode = stat.S_IMODE(path.stat().st_mode)
            if path.is_dir():
                self.assertTrue(
                    mode & stat.S_IXOTH,
                    f"unprivileged app cannot traverse {path.relative_to(store)}: {mode:o}",
                )
            elif path.is_file():
                self.assertTrue(
                    mode & stat.S_IROTH,
                    f"unprivileged app cannot read {path.relative_to(store)}: {mode:o}",
                )

        store.chmod(0o500)
        self.assertFalse(
            stat.S_IMODE(store.stat().st_mode) & stat.S_IXOTH,
            "negative control must reproduce the Build 50 inaccessible store",
        )
        for relative in (
            "usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0",
            "usr/lib/aarch64-linux-gnu/libxcb-present.so.0",
            "usr/lib/aarch64-linux-gnu/libxshmfence.so.1",
        ):
            self.assertTrue((store / relative).is_file(), relative)

    def test_installer_uses_global_relative_path_order_for_identity(self) -> None:
        builder = self.work / "fake-builder.py"
        builder.write_text(
            textwrap.dedent(
                """\
                import pathlib
                import sys

                output = pathlib.Path(sys.argv[sys.argv.index("--output") + 1])
                (output / "a/lib").mkdir(parents=True)
                (output / "a/lib/z.so").write_bytes(b"nested")
                (output / "z.txt").write_bytes(b"root")
                """
            ),
            encoding="utf-8",
        )
        rootfs = self.work / "identity-rootfs"
        rootfs.mkdir()
        result = run(
            [str(PLATFORM_INSTALLER), str(self.config), str(self.host), str(rootfs)],
            env={
                "PATH": os.environ["PATH"],
                "PF_APP_RUNTIME_BUILDER": str(builder),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        store = next(
            (rootfs / "usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64").glob(
                "sha256-*"
            )
        )
        lines = [
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(store).as_posix()}\n"
            for path in sorted(
                (path for path in store.rglob("*") if path.is_file()),
                key=lambda path: path.relative_to(store).as_posix(),
            )
            if path.name != ".manifest-sha256"
        ]
        expected_digest = hashlib.sha256("".join(lines).encode()).hexdigest()
        self.assertEqual(store.name, f"sha256-{expected_digest}")

    def test_config_without_symbol_floor_keeps_exact_manifest_bytes(self) -> None:
        # Golden captured from main before the symbol-version gate: a config
        # that does not opt in must keep its runtime bytes and digest.
        output = self.work / "golden"
        result = self.build(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            hashlib.sha256((output / "abi.json").read_bytes()).hexdigest(),
            "77a1d1bd94802f49d79077e1847b75e46f87b0bcd2ff6102e4c76905bb6819e2",
        )


A133_OPEN_CONFIG = ROOT / "build" / "app-platform-runtime-a133-open-v1.json"
# Debian 12 is the oldest app root that mounts this runtime: glibc 2.36,
# GCC 12 libstdc++ (GLIBCXX_3.4.30, CXXABI_1.3.13) and libgcc_s.
BOOKWORM_SYMBOL_FLOOR = {
    "ld-linux-aarch64.so.1": {"GLIBC": "2.36"},
    "libc.so.6": {"GLIBC": "2.36"},
    "libdl.so.2": {"GLIBC": "2.36"},
    "libgcc_s.so.1": {"GCC": "12.0.0"},
    "libm.so.6": {"GLIBC": "2.36"},
    "libpthread.so.0": {"GLIBC": "2.36"},
    "libresolv.so.2": {"GLIBC": "2.36"},
    "librt.so.1": {"GLIBC": "2.36"},
    "libstdc++.so.6": {"GLIBCXX": "3.4.30", "CXXABI": "1.3.13"},
}
# glibc's own DSOs import GLIBC_PRIVATE from the libc they were built with, so
# they must always come from the app root's libc6, never the Bookworm slice.
GLIBC_DSOS = {
    "ld-linux-aarch64.so.1", "libanl.so.1", "libc.so.6", "libdl.so.2",
    "libm.so.6", "libnsl.so.1", "libpthread.so.0", "libresolv.so.2",
    "librt.so.1", "libutil.so.1",
}


class PlatformSymbolVersionTest(unittest.TestCase):
    """Real cc/readelf ELFs: every version need is met by the root floor or a bundled verdef."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pf-platform-symver-test-")
        self.work = Path(self.temp.name)
        self.host = self.work / "host"
        self.libdir = self.host / "usr/lib/aarch64-linux-gnu"
        self.libdir.mkdir(parents=True)
        (self.host / "usr/local/lib").mkdir(parents=True)
        libc = run(["cc", "-print-file-name=libc.so.6"]).stdout.strip()
        self.assertTrue(Path(libc).is_file(), libc)
        self.libc_versions = self.glibc_versions(Path(libc))
        self.compile_provider(with_version=True)
        source = self.work / "gpu.c"
        source.write_text(
            "#include <string.h>\n"
            "int pf_drm(void);\n"
            "int pf_gpu(const char *s) { return (int)strlen(s) + pf_drm(); }\n",
            encoding="utf-8",
        )
        self.check(
            [
                "cc", "-shared", "-fPIC", "-Wl,-soname,libpf_gpu.so.1",
                str(source), f"-L{self.libdir}", "-l:libpfdrm.so.2",
                "-o", str(self.host / "usr/local/lib/libpf_gpu.so.1"),
            ]
        )
        self.config = self.work / "config.json"
        self.write_config({"libc.so.6": {"GLIBC": "2.36"}})

    def tearDown(self) -> None:
        self.temp.cleanup()

    def check(self, args: list[str]) -> None:
        result = run(args)
        self.assertEqual(result.returncode, 0, result.stderr)

    @staticmethod
    def glibc_versions(path: Path) -> set[str]:
        return {
            line.split("Name: ", 1)[1].split()[0]
            for line in run(["readelf", "-V", str(path)]).stdout.splitlines()
            if "Name: GLIBC_" in line and "Flags: BASE" not in line
        }

    def compile_provider(self, *, with_version: bool) -> None:
        source = self.work / "drm.c"
        source.write_text("int pf_drm(void) { return 2; }\n", encoding="utf-8")
        args = [
            "cc", "-shared", "-fPIC", "-Wl,-soname,libpfdrm.so.2", str(source),
            "-o", str(self.libdir / "libpfdrm.so.2"),
        ]
        if with_version:
            script = self.work / "drm.map"
            script.write_text("PFDRM_2.4 { global: pf_drm; local: *; };\n", encoding="utf-8")
            args.insert(-2, f"-Wl,--version-script={script}")
        self.check(args)

    def write_config(self, floor: dict[str, dict[str, str]] | None) -> None:
        value: dict[str, object] = {
            "schema_version": 1,
            "host_distribution": "debian-12",
            "library_dirs": ["usr/local/lib", "usr/lib/aarch64-linux-gnu"],
            "base_sonames": ["libc.so.6"],
            "seeds": ["usr/local/lib/libpf_gpu.so.1"],
            "data": [],
        }
        if floor is not None:
            value["base_symbol_version_floor"] = floor
        self.config.write_text(json.dumps(value), encoding="utf-8")

    def build(self, name: str) -> subprocess.CompletedProcess[str]:
        return run(
            [
                str(PLATFORM_BUILDER), "--host-root", str(self.host),
                "--config", str(self.config), "--output", str(self.work / name),
            ]
        )

    def test_versions_are_satisfied_by_floor_and_bundled_verdefs(self) -> None:
        result = self.build("runtime")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.work / "runtime/abi.json").read_text(encoding="utf-8"))
        self.assertEqual(
            manifest["base_symbol_version_floor"], {"libc.so.6": {"GLIBC": "2.36"}}
        )
        gpu = manifest["files"]["usr/local/lib/libpf_gpu.so.1"]["version_needs"]
        self.assertEqual(gpu["libpfdrm.so.2"], ["PFDRM_2.4"])
        self.assertTrue(gpu["libc.so.6"])
        self.assertTrue(set(gpu["libc.so.6"]) <= self.libc_versions)
        drm = manifest["files"]["usr/lib/aarch64-linux-gnu/libpfdrm.so.2"]
        self.assertEqual(drm["version_defs"], ["PFDRM_2.4"])
        # Deterministic: a second build is byte-identical.
        again = self.build("again")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(
            (self.work / "runtime/abi.json").read_bytes(),
            (self.work / "again/abi.json").read_bytes(),
        )

    def test_base_requirement_newer_than_floor_refuses(self) -> None:
        self.write_config({"libc.so.6": {"GLIBC": "2.0"}})
        result = self.build("newer")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exceeds app-root floor GLIBC_2.0", result.stderr)
        self.assertIn("libc.so.6", result.stderr)
        self.assertFalse((self.work / "newer").exists())

    def test_unlisted_namespace_or_base_soname_refuses(self) -> None:
        self.write_config({"libc.so.6": {"GLIBCXX": "3.4.30"}})
        result = self.build("namespace")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no app-root floor", result.stderr)
        self.write_config({})
        result = self.build("soname")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("base_symbol_version_floor must cover every base SONAME", result.stderr)

    def test_bundled_provider_without_needed_version_refuses(self) -> None:
        self.compile_provider(with_version=False)
        result = self.build("unversioned")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "libpf_gpu.so.1 needs libpfdrm.so.2 PFDRM_2.4, not defined by the bundled provider",
            result.stderr,
        )
        self.assertFalse((self.work / "unversioned").exists())

    def test_private_and_malformed_versions_never_compare(self) -> None:
        import runpy

        builder = runpy.run_path(str(PLATFORM_BUILDER))
        floor = {"GLIBC": "2.36"}
        self.assertTrue(builder["version_within_floor"]("GLIBC_2.17", floor))
        self.assertTrue(builder["version_within_floor"]("GLIBC_2.36", floor))
        self.assertFalse(builder["version_within_floor"]("GLIBC_2.38", floor))
        self.assertFalse(builder["version_within_floor"]("GLIBC_PRIVATE", floor))
        self.assertFalse(builder["version_within_floor"]("GLIBC_ABI_DT_RELR", floor))
        self.assertFalse(builder["version_within_floor"]("GLIBC_2.3x", floor))


class A133OpenRuntimeConfigTest(unittest.TestCase):
    def test_owned_mesa_closure_and_complete_drirc_directory(self) -> None:
        config = json.loads(A133_OPEN_CONFIG.read_text(encoding="utf-8"))
        for seed in (
            "usr/local/lib/libEGL_mesa.so.0",
            "usr/local/lib/libgallium_dri.so",
            "usr/local/lib/libgbm.so.1",
            "usr/local/lib/gbm/dri_gbm.so",
            "usr/local/lib/libvulkan_powervr_mesa.so",
        ):
            self.assertIn(seed, config["seeds"])
        for data in (
            "usr/local/lib/dri/zink_dri.so",
            "usr/local/share/drirc.d/00-mesa-defaults.conf",
            "usr/local/share/drirc.d/10-pocketforge-zink.conf",
            "usr/share/glvnd/egl_vendor.d/50_mesa.json",
            "usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json",
        ):
            self.assertIn(data, config["data"])
        for relative, runtime_path in config["json_library_paths"].items():
            self.assertTrue(
                runtime_path.startswith("/run/pocketforge/platform-runtime/usr/local/lib/"),
                relative,
            )

    def test_symbol_floor_is_the_bookworm_app_root(self) -> None:
        config = json.loads(A133_OPEN_CONFIG.read_text(encoding="utf-8"))
        self.assertEqual(config["base_symbol_version_floor"], BOOKWORM_SYMBOL_FLOOR)
        self.assertEqual(set(config["base_sonames"]), set(BOOKWORM_SYMBOL_FLOOR))

    def test_glibc_dsos_are_never_bundled(self) -> None:
        config = json.loads(A133_OPEN_CONFIG.read_text(encoding="utf-8"))
        seeded = {Path(seed).name for seed in config["seeds"]}
        self.assertEqual(seeded & GLIBC_DSOS, set())
        self.assertIn("libresolv.so.2", config["base_sonames"])


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
