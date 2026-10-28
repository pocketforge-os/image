#!/usr/bin/env python3
"""Fetch, authenticate, and atomically select Valve's Steam Link client."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.error
import urllib.request


DEFAULT_BASE_URL = "https://media.steampowered.com/steamlink/rpi/bookworm/arm64"
DEFAULT_FINGERPRINT = "BA23DAE64102FBE0BB140CE5387C648A24C0E740"
DEFAULT_MINIMUM_VERSION = "1.3.32.316"
DEFAULT_BOOTSTRAP_SHA256 = (
    "6e1e431265da01b85a7a2fb2ef652f822eb16c5b78aca03f0d0d500dc29b93d3"
)
VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9]+){3}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_POINTER_BYTES = 128
MAX_SIGNATURE_BYTES = 64 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 50_000
EXPECTED_LIBRARIES = {
    "libavcodec.so.59.37.100": "libavcodec.so.59",
    "libavutil.so.57.28.100": "libavutil.so.57",
    "libswresample.so.4.7.100": "libswresample.so.4",
}


class Refusal(Exception):
    def __init__(self, reason: str, detail: str):
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


def refuse(reason: str, detail: str) -> None:
    raise Refusal(reason, detail)


def version_tuple(value: str) -> tuple[int, int, int, int]:
    if not VERSION_RE.fullmatch(value):
        refuse("version_invalid", f"non-canonical version: {value!r}")
    return tuple(int(part) for part in value.split("."))  # type: ignore[return-value]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        refuse("state_invalid", str(error))
    return digest.hexdigest()


def ensure_state_root(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.is_symlink() or not path.is_dir():
            refuse("state_invalid", f"state root is not a real directory: {path}")
        (path / "builds").mkdir(mode=0o700, exist_ok=True)
        if (path / "builds").is_symlink():
            refuse("state_invalid", "builds directory is a symlink")
    except OSError as error:
        refuse("state_invalid", str(error))


def read_url(url: str, destination: Path, *, timeout: float, limit: int, kind: str) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "PocketForge-SteamFetch/1"})
    written = 0
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            length_header = response.headers.get("Content-Length")
            expected = int(length_header) if length_header is not None else None
            if expected is not None and (expected < 0 or expected > limit):
                refuse("download_too_large", f"{kind} Content-Length is {expected}")
            with destination.open("xb") as output:
                while True:
                    chunk = response.read(min(1024 * 1024, limit - written + 1))
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > limit:
                        refuse("download_too_large", f"{kind} exceeded {limit} bytes")
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            if expected is not None and written != expected:
                refuse(
                    "download_truncated",
                    f"{kind} received {written} bytes, expected {expected}",
                )
    except Refusal:
        raise
    except (http.client.IncompleteRead, EOFError) as error:
        refuse("download_truncated", f"{kind}: {error}")
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
        refuse("offline", f"{kind}: {error}")


def discover(base_url: str, stage: Path, timeout: float) -> str:
    pointer = stage / "public_build.txt"
    read_url(
        f"{base_url.rstrip('/')}/public_build.txt",
        pointer,
        timeout=timeout,
        limit=MAX_POINTER_BYTES,
        kind="version pointer",
    )
    try:
        value = pointer.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as error:
        refuse("version_invalid", str(error))
    version_tuple(value)
    return value


def verify_signature(
    archive: Path, signature: Path, trusted_key: Path, trusted_fingerprint: str, stage: Path
) -> None:
    if not trusted_key.is_file() or trusted_key.is_symlink():
        refuse("trust_key_invalid", f"trusted key is not a regular file: {trusted_key}")
    gnupg = stage / "gnupg"
    gnupg.mkdir(mode=0o700)
    try:
        imported = subprocess.run(
            ["gpg", "--homedir", str(gnupg), "--batch", "--no-options", "--import", str(trusted_key)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if imported.returncode != 0:
            refuse("trust_key_invalid", imported.stderr.strip() or "gpg import failed")
        listed = subprocess.run(
            ["gpg", "--homedir", str(gnupg), "--batch", "--with-colons", "--fingerprint", "--list-keys"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        fingerprints = [
            line.split(":")[9]
            for line in listed.stdout.splitlines()
            if line.startswith("fpr:") and len(line.split(":")) > 9
        ]
        if listed.returncode != 0 or not fingerprints or fingerprints[0] != trusted_fingerprint:
            refuse("trust_key_invalid", "committed key primary fingerprint differs")
        verified = subprocess.run(
            [
                "gpg",
                "--homedir",
                str(gnupg),
                "--batch",
                "--no-options",
                "--status-fd=1",
                "--verify",
                str(signature),
                str(archive),
            ],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        refuse("signature_invalid", f"gpg unavailable: {error}")
    valid = any(
        line.startswith("[GNUPG:] VALIDSIG ")
        and line.split()[2] == trusted_fingerprint
        and line.split()[-1] == trusted_fingerprint
        for line in verified.stdout.splitlines()
    )
    if verified.returncode != 0 or not valid:
        refuse("signature_invalid", "detached Valve signature did not validate")


def validate_platform_runtime(runtime: Path) -> None:
    metadata = runtime / "metadata"
    manifest_path = metadata / "runtime.toml"
    hashes_path = metadata / "libraries.sha256"
    libdir = runtime / "lib" / "aarch64-linux-gnu"
    try:
        if manifest_path.is_symlink() or hashes_path.is_symlink():
            refuse("abi_mismatch", "platform metadata contains a symlink")
        with manifest_path.open("rb") as source:
            manifest = tomllib.load(source)
    except Refusal:
        raise
    except (OSError, tomllib.TOMLDecodeError) as error:
        refuse("abi_mismatch", f"platform runtime manifest: {error}")
    expected = {
        "schema_version": 1,
        "runtime_id": "steamlink-ffmpeg59",
        "revision": "v1",
        "architecture": "aarch64",
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            refuse("abi_mismatch", f"platform runtime {key} differs")
    declared_libdir = manifest.get("libdir")
    production_libdir = "/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1/lib/aarch64-linux-gnu"
    if declared_libdir not in {str(libdir), production_libdir}:
        refuse("abi_mismatch", "platform runtime libdir differs")
    try:
        lines = hashes_path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        refuse("abi_mismatch", f"library manifest: {error}")
    recorded: dict[str, str] = {}
    for line in lines:
        fields = line.split()
        if len(fields) != 2 or not SHA256_RE.fullmatch(fields[0]):
            refuse("abi_mismatch", "invalid library hash manifest")
        digest, name = fields
        if name in recorded:
            refuse("abi_mismatch", f"duplicate library entry: {name}")
        recorded[name] = digest
    if set(recorded) != set(EXPECTED_LIBRARIES):
        refuse("abi_mismatch", "platform runtime library set differs")
    for filename, soname in EXPECTED_LIBRARIES.items():
        library = libdir / filename
        link = libdir / soname
        if not library.is_file() or library.is_symlink() or sha256_file(library) != recorded[filename]:
            refuse("abi_mismatch", f"platform runtime library differs: {filename}")
        if not link.is_symlink() or os.readlink(link) != filename:
            refuse("abi_mismatch", f"platform runtime SONAME differs: {soname}")


def safe_extract(archive: Path, destination: Path, expected_version: str) -> None:
    destination.mkdir(mode=0o700)
    total = 0
    count = 0
    links: list[tuple[Path, str]] = []
    try:
        with tarfile.open(archive, mode="r:gz") as bundle:
            for member in bundle:
                count += 1
                if count > MAX_ARCHIVE_MEMBERS:
                    refuse("archive_invalid", "archive has too many members")
                pure = PurePosixPath(member.name)
                if (
                    pure.is_absolute()
                    or not pure.parts
                    or pure.parts[0] != "steamlink"
                    or any(part in {"", ".", ".."} for part in pure.parts)
                ):
                    refuse("archive_invalid", f"unsafe archive path: {member.name!r}")
                target = destination.joinpath(*pure.parts)
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True, mode=0o755)
                    continue
                if member.issym():
                    link = PurePosixPath(member.linkname)
                    if (
                        len(link.parts) != 1
                        or link.name in {"", ".", ".."}
                        or link.is_absolute()
                    ):
                        refuse(
                            "archive_invalid",
                            f"unsafe archive symlink: {member.name} -> {member.linkname}",
                        )
                    links.append((target, link.name))
                    continue
                if not member.isfile():
                    refuse("archive_invalid", f"non-regular archive member: {member.name}")
                total += member.size
                if total > MAX_EXTRACTED_BYTES:
                    refuse("archive_invalid", "archive expands beyond the size limit")
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                source = bundle.extractfile(member)
                if source is None:
                    refuse("archive_invalid", f"cannot read archive member: {member.name}")
                with target.open("xb") as output:
                    shutil.copyfileobj(source, output, length=1024 * 1024)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            for target, link_name in links:
                link_target = target.parent / link_name
                if not link_target.is_file() or link_target.is_symlink():
                    refuse(
                        "archive_invalid",
                        f"archive symlink target is not a same-directory regular file: {target}",
                    )
                target.symlink_to(link_name)
    except Refusal:
        raise
    except (OSError, tarfile.TarError, EOFError) as error:
        refuse("archive_invalid", str(error))
    version_file = destination / "steamlink" / "version.txt"
    shell = destination / "steamlink" / "bin" / "shell"
    try:
        actual_version = version_file.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as error:
        refuse("archive_invalid", f"version.txt: {error}")
    if actual_version != expected_version:
        refuse("version_mismatch", f"archive version is {actual_version!r}")
    if shell.is_symlink() or not shell.is_file() or not os.access(shell, os.X_OK):
        refuse("archive_invalid", "steamlink/bin/shell is not a regular executable")


def archive_manifest(archive: Path, expected_version: str) -> dict[str, dict[str, object]]:
    """Describe the signed archive in the normalized form safe_extract installs."""
    result: dict[str, dict[str, object]] = {}
    total = 0
    count = 0
    version_body: bytes | None = None
    try:
        with tarfile.open(archive, mode="r:gz") as bundle:
            for member in bundle:
                count += 1
                if count > MAX_ARCHIVE_MEMBERS:
                    refuse("archive_invalid", "archive has too many members")
                pure = PurePosixPath(member.name)
                if (
                    pure.is_absolute()
                    or not pure.parts
                    or pure.parts[0] != "steamlink"
                    or any(part in {"", ".", ".."} for part in pure.parts)
                ):
                    refuse("archive_invalid", f"unsafe archive path: {member.name!r}")
                name = pure.as_posix()
                if member.isdir():
                    continue
                if name in result:
                    refuse("archive_invalid", f"duplicate archive member: {name}")
                if member.issym():
                    link = PurePosixPath(member.linkname)
                    if len(link.parts) != 1 or link.name in {"", ".", ".."} or link.is_absolute():
                        refuse("archive_invalid", f"unsafe archive symlink: {name} -> {member.linkname}")
                    result[name] = {"type": "symlink", "target": link.name}
                    continue
                if not member.isfile():
                    refuse("archive_invalid", f"non-regular archive member: {name}")
                total += member.size
                if total > MAX_EXTRACTED_BYTES:
                    refuse("archive_invalid", "archive expands beyond the size limit")
                source = bundle.extractfile(member)
                if source is None:
                    refuse("archive_invalid", f"cannot read archive member: {name}")
                digest = hashlib.sha256()
                body = bytearray() if name == "steamlink/version.txt" else None
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
                    if body is not None:
                        body.extend(chunk)
                if body is not None:
                    version_body = bytes(body)
                result[name] = {
                    "type": "file",
                    "sha256": digest.hexdigest(),
                    "executable": bool(member.mode & 0o111),
                }
    except Refusal:
        raise
    except (OSError, tarfile.TarError, EOFError) as error:
        refuse("archive_invalid", str(error))
    try:
        actual_version = version_body.decode("ascii").strip() if version_body is not None else None
    except UnicodeError as error:
        refuse("archive_invalid", f"version.txt: {error}")
    if actual_version != expected_version:
        refuse("version_mismatch", f"archive version is {actual_version!r}")
    for name, entry in result.items():
        if entry["type"] == "symlink":
            target = str(PurePosixPath(name).parent / str(entry["target"]))
            if result.get(target, {}).get("type") != "file":
                refuse("archive_invalid", f"archive symlink target is not a regular file: {name}")
    return result


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def installed_manifest(build: Path) -> dict[str, dict[str, object]]:
    top = build / "steamlink"
    if not top.is_dir() or top.is_symlink():
        refuse("state_invalid", "installed steamlink tree is not a real directory")
    result: dict[str, dict[str, object]] = {}
    try:
        for path in top.rglob("*"):
            name = path.relative_to(build).as_posix()
            if path.is_symlink():
                result[name] = {"type": "symlink", "target": os.readlink(path)}
            elif path.is_file():
                result[name] = {
                    "type": "file",
                    "sha256": sha256_file(path),
                    "executable": bool(path.stat().st_mode & 0o111),
                }
            elif not path.is_dir():
                refuse("state_invalid", f"unsupported installed node: {name}")
    except OSError as error:
        refuse("state_invalid", str(error))
    return result


def atomic_symlink(state: Path, name: str, target: str) -> None:
    temporary = state / f".{name}.{secrets.token_hex(8)}"
    try:
        temporary.symlink_to(target)
        os.replace(temporary, state / name)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def validate_build(build: Path, args: argparse.Namespace) -> Path:
    if not build.is_dir() or build.is_symlink():
        refuse("state_invalid", f"build is not a real directory: {build}")
    receipt_path = build / "receipt.json"
    manifest_path = build / "payload-manifest.json"
    archive = build / "verified-source" / "archive.tar.gz"
    signature = build / "verified-source" / "archive.tar.gz.sig"
    for path in (receipt_path, manifest_path, archive, signature):
        if not path.is_file() or path.is_symlink():
            refuse("state_invalid", f"build metadata is not a regular file: {path.name}")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        stored_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        refuse("state_invalid", str(error))
    version = receipt.get("version")
    digest = receipt.get("archive_sha256")
    manifest_digest = receipt.get("payload_manifest_sha256")
    if (
        receipt.get("schema_version") != 2
        or not isinstance(version, str)
        or not VERSION_RE.fullmatch(version)
        or not isinstance(digest, str)
        or not SHA256_RE.fullmatch(digest)
        or not isinstance(manifest_digest, str)
        or not SHA256_RE.fullmatch(manifest_digest)
        or receipt.get("signing_fingerprint") != args.trusted_fingerprint
    ):
        refuse("state_invalid", "build receipt fields differ")
    if build.name != f"{version}-{digest}":
        refuse("state_invalid", "build directory identity differs from receipt")
    if sha256_file(archive) != digest:
        refuse("state_invalid", "retained archive digest differs")
    manifest_bytes = canonical_json(stored_manifest)
    if hashlib.sha256(manifest_bytes).hexdigest() != manifest_digest:
        refuse("state_invalid", "payload manifest digest differs")
    with tempfile.TemporaryDirectory(prefix=".verify.", dir=build.parent.parent) as stage_name:
        verify_signature(
            archive,
            signature,
            args.trusted_key,
            args.trusted_fingerprint,
            Path(stage_name),
        )
    expected_manifest = archive_manifest(archive, version)
    if stored_manifest != expected_manifest:
        refuse("state_invalid", "payload manifest is not bound to retained signed archive")
    if installed_manifest(build) != expected_manifest:
        refuse("state_invalid", "installed payload differs from signed archive")
    shell = build / "steamlink" / "bin" / "shell"
    if not shell.is_file() or shell.is_symlink() or not os.access(shell, os.X_OK):
        refuse("state_invalid", "installed shell is not executable")
    return build


def selected_build(state: Path, link_name: str, args: argparse.Namespace) -> Path | None:
    link = state / link_name
    if not link.exists() and not link.is_symlink():
        return None
    if not link.is_symlink():
        refuse("state_invalid", f"{link_name} is not a symlink")
    target = os.readlink(link)
    pure = PurePosixPath(target)
    if len(pure.parts) != 2 or pure.parts[0] != "builds" or any(part in {"", ".", ".."} for part in pure.parts):
        refuse("state_invalid", f"{link_name} target is invalid")
    return validate_build(state / target, args)


def receipt_version(build: Path | None) -> str | None:
    if build is None:
        return None
    try:
        value = json.loads((build / "receipt.json").read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    version = value.get("version")
    return version if isinstance(version, str) and VERSION_RE.fullmatch(version) else None


def install_candidate(args: argparse.Namespace, state: Path, stage: Path, version: str) -> Path:
    archive_name = f"steamlink-rpi-bookworm-arm64-{version}.tar.gz"
    archive = stage / archive_name
    signature = stage / f"{archive_name}.sig"
    base = args.base_url.rstrip("/")
    read_url(f"{base}/{archive_name}", archive, timeout=args.timeout, limit=MAX_ARCHIVE_BYTES, kind="archive")
    read_url(
        f"{base}/{archive_name}.sig",
        signature,
        timeout=args.timeout,
        limit=MAX_SIGNATURE_BYTES,
        kind="signature",
    )
    verify_signature(archive, signature, args.trusted_key, args.trusted_fingerprint, stage)
    digest = sha256_file(archive)
    if version == args.minimum_version and digest != args.bootstrap_sha256:
        refuse("digest_mismatch", "minimum release archive digest differs")
    manifest = archive_manifest(archive, version)
    payload = stage / "payload"
    safe_extract(archive, payload, version)
    validate_platform_runtime(args.platform_runtime)
    manifest_bytes = canonical_json(manifest)
    (payload / "payload-manifest.json").write_bytes(manifest_bytes)
    source = payload / "verified-source"
    source.mkdir(mode=0o700)
    os.replace(archive, source / "archive.tar.gz")
    os.replace(signature, source / "archive.tar.gz.sig")
    receipt = {
        "schema_version": 2,
        "version": version,
        "archive_sha256": digest,
        "payload_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        "signing_fingerprint": args.trusted_fingerprint,
        "archive_url": f"{base}/{archive_name}",
        "signature_url": f"{base}/{archive_name}.sig",
    }
    receipt_path = payload / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
    receipt_path.chmod(0o600)
    relative = f"builds/{version}-{digest}"
    installed = state / relative
    if installed.exists() or installed.is_symlink():
        validate_build(installed, args)
    else:
        os.replace(payload, installed)
    previous = selected_build(state, "current", args)
    if previous is not None and previous != installed:
        atomic_symlink(state, "last-good", previous.relative_to(state).as_posix())
    atomic_symlink(state, "current", relative)
    return installed


def report_success(result: str, build: Path, *, reason: str | None = None, fallback: bool = False) -> None:
    fields = ["STEAMFETCH", f"result={result}"]
    if reason:
        fields.append(f"reason={reason}")
    if fallback:
        fields.append("fallback=last_good")
    fields.append(f"path={build}")
    print(" ".join(fields), flush=True)


def launch_if_requested(build: Path, launch: bool) -> None:
    if launch:
        top = build / "steamlink"
        shell = top / "bin" / "shell"
        qt = top / "Qt-5.14.1"
        environment = os.environ.copy()
        environment["PATH"] = ":".join(
            part for part in (str(top / "bin"), environment.get("PATH", "")) if part
        )
        environment["QTDIR"] = str(qt)
        environment["QT_PLUGIN_PATH"] = str(qt / "plugins")
        environment["LD_LIBRARY_PATH"] = ":".join(
            part
            for part in (str(top / "lib"), str(qt / "lib"), environment.get("LD_LIBRARY_PATH", ""))
            if part
        )
        data_home = environment.get("XDG_DATA_HOME", str(Path(environment.get("HOME", "/")) / ".local/share"))
        environment["SDL_GAMECONTROLLERCONFIG_FILE"] = str(
            Path(data_home) / "Valve Corporation/SteamLink/controller_map.txt"
        )
        os.chdir(top)
        os.execve(shell, [str(shell)], environment)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    result.add_argument("--state-root", type=Path, required=True)
    result.add_argument("--platform-runtime", type=Path, required=True)
    result.add_argument("--base-url", default=DEFAULT_BASE_URL)
    result.add_argument(
        "--trusted-key",
        type=Path,
        default=Path(__file__).with_name("valve-steamlink-release-key.asc"),
    )
    result.add_argument("--trusted-fingerprint", default=DEFAULT_FINGERPRINT)
    result.add_argument("--minimum-version", default=DEFAULT_MINIMUM_VERSION)
    result.add_argument("--bootstrap-sha256", default=DEFAULT_BOOTSTRAP_SHA256)
    result.add_argument("--timeout", type=float, default=15.0)
    result.add_argument("--launch", action="store_true")
    return result


def main() -> int:
    args = parser().parse_args()
    if not re.fullmatch(r"[0-9A-F]{40}", args.trusted_fingerprint):
        print("STEAMFETCH result=refused reason=trust_key_invalid detail=fingerprint", file=sys.stderr)
        return 64
    if not SHA256_RE.fullmatch(args.bootstrap_sha256):
        print("STEAMFETCH result=refused reason=digest_invalid detail=bootstrap", file=sys.stderr)
        return 64
    try:
        minimum = version_tuple(args.minimum_version)
        ensure_state_root(args.state_root)
        with tempfile.TemporaryDirectory(prefix=".staging.", dir=args.state_root) as stage_name:
            stage = Path(stage_name)
            try:
                candidate = discover(args.base_url, stage, args.timeout)
                candidate_tuple = version_tuple(candidate)
                if candidate_tuple < minimum:
                    refuse("version_below_floor", f"candidate {candidate} is below {args.minimum_version}")
                current = selected_build(args.state_root, "current", args)
                current_version = receipt_version(current)
                if current_version is not None and candidate_tuple < version_tuple(current_version):
                    refuse("version_below_floor", f"candidate {candidate} is older than last-good {current_version}")
                validate_platform_runtime(args.platform_runtime)
                if current is not None and current_version == candidate:
                    report_success("cached", current)
                    launch_if_requested(current, args.launch)
                    return 0
                installed = install_candidate(args, args.state_root, stage, candidate)
                report_success("installed", installed)
                launch_if_requested(installed, args.launch)
                return 0
            except Refusal as error:
                if error.reason == "abi_mismatch":
                    raise
                fallback = selected_build(args.state_root, "current", args) or selected_build(
                    args.state_root, "last-good", args
                )
                if fallback is not None:
                    report_success("fallback", fallback, reason=error.reason, fallback=True)
                    launch_if_requested(fallback, args.launch)
                    return 0
                raise
    except Refusal as error:
        detail = re.sub(r"\s+", "_", error.detail.strip())[:240]
        print(f"STEAMFETCH result=refused reason={error.reason} detail={detail}", file=sys.stderr)
        return 70


if __name__ == "__main__":
    raise SystemExit(main())
