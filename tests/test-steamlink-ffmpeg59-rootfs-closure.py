#!/usr/bin/env python3
"""Keep the FFmpeg59 producer manifest valid through rootfs ELF finalization."""

from __future__ import annotations

import hashlib
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
DEFINITION = ROOT / "build/platform-runtimes/steamlink-ffmpeg59/v1"
BUILDER = DEFINITION / "build.sh"
PRODUCER_FINALIZER = DEFINITION / "finalize-runtime.sh"
ROOTFS_BUILDER = ROOT / "scripts/build-rootfs.sh"
ROOTFS_FINALIZER = ROOT / "scripts/finalize-elf-debuginfo.sh"
INSTALLER = ROOT / "scripts/install-platform-runtime.sh"
FETCHER = ROOT / "apps/steamlink/steamlink-fetch.py"
RUNTIME_RELATIVE = Path("usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1")
SOURCE_RELATIVE = Path("usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1")
LIBRARIES = {
    "libavcodec.so.59.37.100": "libavcodec.so.59",
    "libavutil.so.57.28.100": "libavutil.so.57",
    "libswresample.so.4.7.100": "libswresample.so.4",
}
FINALIZER_CALL = '"${definition_dir}/finalize-runtime.sh" "${dest}"'


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SteamLinkFFmpeg59RootfsClosureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="steamlink-ffmpeg59-closure.")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.producer = self.work / "producer"
        self.rootfs = self.work / "rootfs"
        self.out = self.work / "out"
        self.runtime = self.producer / RUNTIME_RELATIVE
        self.libdir = self.runtime / "lib/aarch64-linux-gnu"
        self.metadata = self.runtime / "metadata"
        source = self.producer / SOURCE_RELATIVE
        self.libdir.mkdir(parents=True)
        self.metadata.mkdir()
        source.mkdir(parents=True)

        fixture = self.work / "fixture.c"
        fixture.write_text("int pf_ffmpeg_fixture(void) { return 59; }\n", encoding="ascii")
        for filename, soname in LIBRARIES.items():
            library = self.libdir / filename
            self.run_ok(
                [
                    "cc",
                    "-g",
                    "-shared",
                    "-fPIC",
                    "-nostdlib",
                    "-Wl,--build-id=sha1",
                    f"-Wl,-soname,{soname}",
                    str(fixture),
                    "-o",
                    str(library),
                ]
            )
            (self.libdir / soname).symlink_to(filename)
        (self.metadata / "runtime.toml").write_text(
            "\n".join(
                [
                    "schema_version = 1",
                    'runtime_id = "steamlink-ffmpeg59"',
                    'revision = "v1"',
                    'architecture = "aarch64"',
                    'libdir = "/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1/lib/aarch64-linux-gnu"',
                    "",
                ]
            ),
            encoding="ascii",
        )
        (source / "README.md").write_text("source-owned FFmpeg59 fixture\n", encoding="ascii")

    def run_ok(self, args: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(args, text=True, capture_output=True, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def seal_producer(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        if FINALIZER_CALL in builder:
            self.assertLess(builder.index(FINALIZER_CALL), builder.index('> "${dest}/metadata/libraries.sha256"'))
            self.run_ok(
                [str(PRODUCER_FINALIZER), str(self.runtime)],
                env={
                    **os.environ,
                    "PF_FFMPEG_STRIP": shutil.which("strip") or "strip",
                    "PF_FFMPEG_READELF": shutil.which("readelf") or "readelf",
                },
            )
        (self.metadata / "libraries.sha256").write_text(
            "".join(f"{sha256(self.libdir / name)}  {name}\n" for name in sorted(LIBRARIES)),
            encoding="ascii",
        )
        payload = []
        for relative_root in (RUNTIME_RELATIVE, SOURCE_RELATIVE):
            for path in sorted((self.producer / relative_root).rglob("*")):
                if path.is_file() and not path.is_symlink() and path.name != "payload.sha256":
                    payload.append(f"{sha256(path)}  {path.relative_to(self.producer).as_posix()}\n")
        (self.metadata / "payload.sha256").write_text("".join(sorted(payload)), encoding="ascii")
        for path in [self.producer, *self.producer.rglob("*")]:
            path.chmod(0o555 if path.is_dir() else 0o444)

    def install_runtime(self) -> None:
        self.run_ok([str(INSTALLER), str(self.producer), str(self.rootfs), "v1"])
        installed = self.rootfs / RUNTIME_RELATIVE
        # Production assembles as root; make its permitted ELF mutation possible
        # in this unprivileged regression without changing any hashed bytes.
        for path in [installed, *installed.rglob("*")]:
            if not path.is_symlink():
                path.chmod(0o755 if path.is_dir() else 0o644)

    def finalize_rootfs(self) -> None:
        owned = self.rootfs / "usr/bin/root-owned"
        owned.parent.mkdir(parents=True, exist_ok=True)
        fixture = self.work / "root-owned.c"
        fixture.write_text("int main(void) { return 0; }\n", encoding="ascii")
        self.run_ok(["cc", "-g", "-Wl,--build-id=sha1", str(fixture), "-o", str(owned)])
        self.run_ok(
            [str(ROOTFS_FINALIZER), str(self.rootfs), str(self.out)],
            env={
                **os.environ,
                "PF_OBJCOPY": shutil.which("objcopy") or "objcopy",
                "PF_STRIP": shutil.which("strip") or "strip",
            },
        )

    def test_build65_rootfs_order_preserves_exact_runtime_identity(self) -> None:
        self.seal_producer()
        source = ROOTFS_BUILDER.read_text(encoding="utf-8")
        install_position = source.index('"${SRC_DIR}/scripts/install-platform-runtime.sh"')
        finalize_position = source.index('"${SRC_DIR}/scripts/finalize-elf-debuginfo.sh"')
        if install_position < finalize_position:
            self.install_runtime()
            self.finalize_rootfs()
        else:
            self.finalize_rootfs()
            self.install_runtime()

        spec = importlib.util.spec_from_file_location("steamlink_fetch", FETCHER)
        assert spec is not None and spec.loader is not None
        fetcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fetcher)
        installed = self.rootfs / RUNTIME_RELATIVE
        try:
            fetcher.validate_platform_runtime(installed)
        except fetcher.Refusal as error:
            detail = re.sub(r"\s+", "_", error.detail.strip())
            self.fail(f"STEAMFETCH result=refused reason={error.reason} detail={detail}")

        recorded = {
            filename: digest
            for digest, filename in (
                line.split()
                for line in (installed / "metadata/libraries.sha256").read_text().splitlines()
            )
        }
        for filename, soname in LIBRARIES.items():
            self.assertEqual(recorded[filename], sha256(installed / "lib/aarch64-linux-gnu" / filename))
            self.assertEqual(os.readlink(installed / "lib/aarch64-linux-gnu" / soname), filename)


if __name__ == "__main__":
    unittest.main()
