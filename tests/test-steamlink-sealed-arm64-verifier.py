#!/usr/bin/env python3
"""Exercise the sealed ARM64 Steam Link verifier in production-like isolation."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile


APP_ID = "org.pocketforge.steamlink"
VERSION = "1.3.32.316"
ARCHIVE_NAME = f"steamlink-rpi-bookworm-arm64-{VERSION}.tar.gz"
ARCHIVE_SHA256 = "6e1e431265da01b85a7a2fb2ef652f822eb16c5b78aca03f0d0d500dc29b93d3"
FINGERPRINT = "BA23DAE64102FBE0BB140CE5387C648A24C0E740"
KEYRING_SHA256 = "eadb9fb69738a0a74967984368243dcf10bbb82fc1267d683e1c3772b1384e1c"
STATE_ROOT = Path(f"/var/lib/pocketforge/apps/{APP_ID}/state")
PLATFORM_RUNTIME = Path(
    "/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1"
)
RUNTIME_BUILDS_ROOT = Path(f"/opt/pocketforge/apps/{APP_ID}/verified-builds")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def write_platform_runtime(root: Path) -> None:
    metadata = root / "metadata"
    libraries = root / "lib/aarch64-linux-gnu"
    metadata.mkdir(parents=True)
    libraries.mkdir(parents=True)
    files = {
        "libavcodec.so.59.37.100": b"sealed test avcodec59\n",
        "libavutil.so.57.28.100": b"sealed test avutil57\n",
        "libswresample.so.4.7.100": b"sealed test swresample4\n",
    }
    links = {
        "libavcodec.so.59": "libavcodec.so.59.37.100",
        "libavutil.so.57": "libavutil.so.57.28.100",
        "libswresample.so.4": "libswresample.so.4.7.100",
    }
    for name, body in files.items():
        (libraries / name).write_bytes(body)
    for name, target in links.items():
        (libraries / name).symlink_to(target)
    (metadata / "runtime.toml").write_text(
        "\n".join(
            [
                "schema_version = 1",
                'runtime_id = "steamlink-ffmpeg59"',
                'revision = "v1"',
                'architecture = "aarch64"',
                f'libdir = "{PLATFORM_RUNTIME / "lib/aarch64-linux-gnu"}"',
                "",
            ]
        ),
        encoding="ascii",
    )
    (metadata / "libraries.sha256").write_text(
        "".join(
            f"{hashlib.sha256(body).hexdigest()}  {name}\n"
            for name, body in sorted(files.items())
        ),
        encoding="ascii",
    )


def require_arm64_elf(path: Path) -> None:
    header = path.read_bytes()[:20]
    if header[:4] != b"\x7fELF" or int.from_bytes(header[18:20], "little") != 183:
        raise AssertionError(f"not an ARM64 ELF: {path}")


def isolated_command(
    extracted: Path,
    state: Path,
    platform: Path,
    qemu: Path,
) -> list[str]:
    return [
        "bwrap",
        "--unshare-all",
        "--uid",
        "1000",
        "--gid",
        "1000",
        "--ro-bind",
        str(extracted),
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--bind",
        str(state),
        str(STATE_ROOT),
        "--bind",
        str(state / "steamlink-fetch/builds"),
        str(RUNTIME_BUILDS_ROOT),
        "--ro-bind",
        str(platform),
        str(PLATFORM_RUNTIME),
        "--ro-bind",
        str(qemu),
        "/usr/libexec/qemu-binfmt/aarch64-binfmt-P",
        "--setenv",
        "HOME",
        "/nonexistent",
        "--setenv",
        "GNUPGHOME",
        "/nonexistent/gnupg",
        "--setenv",
        "PATH",
        "/usr/bin:/bin",
        "--setenv",
        "LC_ALL",
        "C.UTF-8",
        "/usr/bin/python3",
        f"/opt/pocketforge/apps/{APP_ID}/steamlink-fetch.py",
        "--state-root",
        str(STATE_ROOT / "steamlink-fetch"),
        "--runtime-builds-root",
        str(RUNTIME_BUILDS_ROOT),
        "--platform-runtime",
        str(PLATFORM_RUNTIME),
        "--base-url",
        (STATE_ROOT / "vendor").as_uri(),
        "--trusted-keyring",
        f"/opt/pocketforge/apps/{APP_ID}/valve-steamlink-release-key.gpg",
        "--trusted-keyring-sha256",
        KEYRING_SHA256,
        "--trusted-fingerprint",
        FINGERPRINT,
        "--minimum-version",
        VERSION,
        "--bootstrap-sha256",
        ARCHIVE_SHA256,
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root-image", type=Path, required=True)
    parser.add_argument("--vendor-dir", type=Path, required=True)
    parser.add_argument(
        "--qemu-interpreter",
        type=Path,
        default=Path("/usr/libexec/qemu-binfmt/aarch64-binfmt-P"),
    )
    args = parser.parse_args()

    for tool in ("bwrap", "unsquashfs"):
        if shutil.which(tool) is None:
            raise SystemExit(f"sealed verifier test requires {tool}")
    for path in (
        args.root_image,
        args.qemu_interpreter,
        args.vendor_dir / ARCHIVE_NAME,
        args.vendor_dir / f"{ARCHIVE_NAME}.sig",
    ):
        if not path.is_file():
            raise SystemExit(f"sealed verifier test input is missing: {path}")
    if sha256(args.vendor_dir / ARCHIVE_NAME) != ARCHIVE_SHA256:
        raise SystemExit("sealed verifier test archive digest differs")

    with tempfile.TemporaryDirectory(prefix="steamlink-sealed-arm64.") as temporary:
        work = Path(temporary)
        extracted = work / "root"
        subprocess.run(
            ["unsquashfs", "-no-progress", "-d", str(extracted), str(args.root_image)],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        app = extracted / f"opt/pocketforge/apps/{APP_ID}"
        keyring = app / "valve-steamlink-release-key.gpg"
        verifier = extracted / "usr/bin/gpgv"
        require_arm64_elf(verifier)
        if sha256(keyring) != KEYRING_SHA256:
            raise AssertionError("sealed Valve keyring digest differs")
        for mutable_verifier in (extracted / "usr/bin/gpg", extracted / "usr/bin/gpg-agent"):
            if mutable_verifier.exists():
                raise AssertionError(f"mutable verifier leaked into sealed root: {mutable_verifier}")

        state_target = extracted / STATE_ROOT.relative_to("/")
        state_target.mkdir()
        qemu_target = extracted / "usr/libexec/qemu-binfmt/aarch64-binfmt-P"
        qemu_target.parent.mkdir(parents=True, exist_ok=True)
        qemu_target.touch()

        state = work / "state"
        (state / "steamlink-fetch/builds").mkdir(parents=True)
        vendor = state / "vendor"
        vendor.mkdir(parents=True)
        (vendor / "public_build.txt").write_text(f"{VERSION}\n", encoding="ascii")
        shutil.copy2(args.vendor_dir / ARCHIVE_NAME, vendor / ARCHIVE_NAME)
        shutil.copy2(
            args.vendor_dir / f"{ARCHIVE_NAME}.sig",
            vendor / f"{ARCHIVE_NAME}.sig",
        )
        platform = work / "platform-runtime"
        write_platform_runtime(platform)

        result = subprocess.run(
            isolated_command(extracted, state, platform, args.qemu_interpreter),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=180,
        )
        if result.returncode != 0 or "result=installed" not in result.stdout:
            raise AssertionError(
                f"sealed verifier failed rc={result.returncode}\n"
                f"stdout={result.stdout}\nstderr={result.stderr}"
            )
        installed = list((state / "steamlink-fetch/builds").iterdir())
        if len(installed) != 1 or not (installed[0] / "steamlink/bin/shell").is_file():
            raise AssertionError("sealed verifier did not install exactly one payload")
        leaked = [
            path
            for path in state.rglob("*")
            if path.name == "gnupg" or path.name.startswith("S.gpg-agent")
        ]
        if leaked:
            raise AssertionError(f"mutable GPG state leaked: {leaked}")

    print(
        "Steam Link sealed ARM64 verifier: PASS "
        "root=read-only uid=1000 private-users=yes private-devices=yes "
        "private-tmp=yes network=off verifier=gpgv agent=absent fingerprint=exact"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
