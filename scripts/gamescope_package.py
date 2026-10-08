#!/usr/bin/env python3
"""Validate and render the fail-closed Gamescope package identity."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
from typing import Callable


SHA1_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
POCKETFORGE_SOURCE_PREFIX = "https://github.com/pocketforge-os/"
SOURCE_SCHEMA = "pocketforge.gamescope-source/v1"
IDENTITY_SCHEMA = "pocketforge.gamescope-build/v1"
MANIFEST_FIELDS = (
    "schema", "edge_id", "parent_id", "project_id", "path", "kind",
    "upstream_url", "upstream_revision", "declared_url", "locator_revision",
    "pf_url", "pf_revision", "tree_oid", "content_sha256", "license_path",
    "license_sha256", "selectors", "tests", "patch_status",
    "transform_receipt", "fork_history_proof", "fork_pin_ref",
)
RECEIPT_FILES = {
    ".pf-gamescope-source.json",
    ".pf-gamescope-admission.json",
    ".pf-gamescope-materialization.json",
}
AARCH64_CROSS_FILE_BYTES = b"""[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-gcc-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = '/work/aarch64-pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
"""


class PackageInputError(ValueError):
    """An exact source, provenance, architecture, or profile gate failed."""


def _normalize_cross_file_bytes(value: bytes) -> bytes:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PackageInputError("Gamescope Meson cross-file must be UTF-8") from error
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.endswith("\n"):
        normalized += "\n"
    return normalized.encode("utf-8")


@dataclass(frozen=True)
class MesonSetupConfiguration:
    source: Path
    build_dir: Path
    cross_file: Path
    cross_file_bytes: bytes = AARCH64_CROSS_FILE_BYTES
    buildtype: str = "release"
    prefix: str = "/usr"
    auto_features: str = "enabled"
    wrap_mode: str = "nodownload"

    def normalized_cross_file_bytes(self) -> bytes:
        return _normalize_cross_file_bytes(self.cross_file_bytes)

    def argv(self) -> tuple[str, ...]:
        return (
            "meson", "setup", str(self.build_dir), str(self.source),
            "--cross-file", str(self.cross_file),
            f"--wrap-mode={self.wrap_mode}",
            f"--buildtype={self.buildtype}",
            f"--prefix={self.prefix}",
            f"--auto-features={self.auto_features}",
        )

    def cross_file_digest(self) -> str:
        return hashlib.sha256(self.normalized_cross_file_bytes()).hexdigest()

    def canonical_bytes(self) -> bytes:
        payload = {
            "schema": "pocketforge.gamescope-meson-setup/v1",
            "argv": list(self.argv()),
            "cross_file_sha256": self.cross_file_digest(),
        }
        return (json.dumps(payload, sort_keys=True, separators=(",", ":")) +
                "\n").encode("utf-8")

    def digest(self) -> str:
        return hashlib.sha256(self.canonical_bytes()).hexdigest()


@dataclass(frozen=True)
class ExpectedSource:
    upstream_base: str
    integrated_head: str
    present_head: str
    staging_head: str
    rotation_head: str
    patch_series_sha256: str
    dependency_manifest_sha256: str
    source_tree_sha256: str
    license_sha256: str


@dataclass(frozen=True)
class ValidatedSource:
    expected: ExpectedSource
    source_url: str
    dependencies: tuple["Dependency", ...]
    source_tree_sha256: str
    admission_receipt_sha256: str
    validated_edges: int
    verified_project_pins: int
    verified_locator_targets: int


@dataclass(frozen=True)
class Dependency:
    name: str
    revision: str
    source_path: str
    license_path: str
    license_sha256: str


def _license_bundle_path(source: Path, dependency: Dependency) -> Path:
    return source / ".pf-source-licenses" / (
        f"{dependency.name}-{dependency.revision[:12]}-"
        f"{Path(dependency.license_path).name}")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_sha(value: object, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise PackageInputError(f"{label} must be an exact lowercase hexadecimal digest")
    return value


def _load_receipt(source: Path) -> dict[str, object]:
    receipt = source / ".pf-gamescope-source.json"
    try:
        data = json.loads(receipt.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise PackageInputError("Gamescope source receipt is missing") from error
    except (OSError, json.JSONDecodeError) as error:
        raise PackageInputError(f"Gamescope source receipt is invalid: {error}") from error
    if not isinstance(data, dict):
        raise PackageInputError("Gamescope source receipt is not an object")
    return data


def _parse_dependency_manifest(path: Path) -> tuple[tuple[Dependency, ...], int]:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise PackageInputError(
            "tsp-op5a.440.7 dependency manifest is missing") from error
    lines = raw.splitlines()
    if not lines or lines[0] != "# gamescope-source-closure-v1":
        raise PackageInputError("dependency manifest schema marker mismatch")
    reader = csv.DictReader(io.StringIO("\n".join(lines[1:])), dialect="excel-tab")
    if tuple(reader.fieldnames or ()) != MANIFEST_FIELDS:
        raise PackageInputError("dependency manifest header mismatch")
    dependencies: dict[tuple[str, str], Dependency] = {}
    seen_edges: set[str] = set()
    edge_count = 0
    for line_number, row in enumerate(reader, start=3):
        if None in row or any(value is None for value in row.values()):
            raise PackageInputError(f"dependency manifest row {line_number} has invalid fields")
        name = row["project_id"]
        kind = row["kind"]
        revision = row["pf_revision"]
        source_path = row["path"][:-5] if kind == "wrap-git" else row["path"]
        license_path = row["license_path"]
        license_sha = row["license_sha256"]
        edge_id = row["edge_id"]
        if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
            raise PackageInputError(f"dependency project id is invalid: {name}")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", edge_id) or edge_id in seen_edges:
            raise PackageInputError(f"dependency edge id is invalid or duplicated: {edge_id}")
        if kind not in {"gitlink", "wrap-git", "vendored-snapshot"}:
            raise PackageInputError(f"dependency {edge_id} has unsupported source kind {kind}")
        for label in ("upstream_revision", "locator_revision", "pf_revision", "tree_oid"):
            _require_sha(row[label], SHA1_RE, f"dependency {edge_id} {label}")
        _require_sha(license_sha, SHA256_RE, f"dependency {edge_id} licence digest")
        if (source_path.startswith("/") or ".." in source_path.split("/") or
                license_path.startswith("/") or ".." in license_path.split("/")):
            raise PackageInputError(f"dependency {edge_id} has unsafe source metadata")
        if not row["pf_url"].startswith(POCKETFORGE_SOURCE_PREFIX):
            raise PackageInputError(
                f"dependency {edge_id} has non-PocketForge source URL: {row['pf_url']}")
        key = (name, revision)
        dependency = Dependency(name, revision, source_path, license_path, license_sha)
        previous = dependencies.get(key)
        if previous is not None and (
                previous.license_path != dependency.license_path or
                previous.license_sha256 != dependency.license_sha256):
            raise PackageInputError(f"dependency {name}@{revision} has inconsistent licence data")
        dependencies.setdefault(key, dependency)
        seen_edges.add(edge_id)
        edge_count += 1
    if not dependencies:
        raise PackageInputError("tsp-op5a.440.7 dependency manifest is empty")
    return tuple(dependencies[key] for key in sorted(dependencies)), edge_count


def _source_tree_sha256(source: Path) -> str:
    records: list[str] = []
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source).as_posix()
        if relative in RECEIPT_FILES or relative.startswith(".pf-source-licenses/"):
            continue
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            digest = hashlib.sha256(os.readlink(path).encode()).hexdigest()
            type_name = "symlink"
        elif path.is_file():
            digest = _sha256(path)
            type_name = "file"
        else:
            continue
        records.append(f"{relative}\t{type_name}\t{mode:o}\t{digest}\n")
    return hashlib.sha256("".join(records).encode()).hexdigest()


def _load_materialization_receipt(source: Path) -> tuple[dict[str, object], str]:
    path = source / ".pf-gamescope-materialization.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise PackageInputError("Gamescope materialization receipt is missing") from error
    except (OSError, json.JSONDecodeError) as error:
        raise PackageInputError(f"Gamescope materialization receipt is invalid: {error}") from error
    if not isinstance(data, dict):
        raise PackageInputError("Gamescope materialization receipt is not an object")
    return data, _sha256(path)


def _load_admission_receipt(source: Path) -> tuple[dict[str, object], str]:
    path = source / ".pf-gamescope-admission.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise PackageInputError("Gamescope admission receipt is missing") from error
    except (OSError, json.JSONDecodeError) as error:
        raise PackageInputError(f"Gamescope admission receipt is invalid: {error}") from error
    if not isinstance(data, dict):
        raise PackageInputError("Gamescope admission receipt is not an object")
    return data, _sha256(path)


def validate_source(source: Path, expected: ExpectedSource) -> ValidatedSource:
    if not source.is_dir():
        raise PackageInputError(f"Gamescope source context is missing: {source}")
    for label, value, pattern in (
        ("upstream_base", expected.upstream_base, SHA1_RE),
        ("integrated_head", expected.integrated_head, SHA1_RE),
        ("present_head", expected.present_head, SHA1_RE),
        ("staging_head", expected.staging_head, SHA1_RE),
        ("rotation_head", expected.rotation_head, SHA1_RE),
        ("patch_series_sha256", expected.patch_series_sha256, SHA256_RE),
        ("dependency_manifest_sha256", expected.dependency_manifest_sha256, SHA256_RE),
        ("source_tree_sha256", expected.source_tree_sha256, SHA256_RE),
        ("license_sha256", expected.license_sha256, SHA256_RE),
    ):
        _require_sha(value, pattern, label)

    data = _load_receipt(source)
    if data.get("schema") != SOURCE_SCHEMA:
        raise PackageInputError("Gamescope source receipt schema mismatch")
    source_url = data.get("source_url")
    if source_url != "https://github.com/pocketforge-os/gamescope.git":
        raise PackageInputError("Gamescope source URL is not the governed PocketForge fork")
    if data.get("upstream_base") != expected.upstream_base:
        raise PackageInputError("Gamescope upstream base mismatch")
    receipt_head = _require_sha(data.get("integrated_head"), SHA1_RE, "integrated_head")
    if receipt_head != expected.integrated_head:
        raise PackageInputError("Gamescope integration head mismatch")
    if data.get("patch_series_sha256") != expected.patch_series_sha256:
        raise PackageInputError("Gamescope patch-series digest mismatch")
    heads = data.get("required_heads")
    if not isinstance(heads, dict):
        raise PackageInputError("Gamescope required_heads record is missing")
    for label, wanted in (
        ("present", expected.present_head),
        ("staging", expected.staging_head),
        ("rotation", expected.rotation_head),
    ):
        got = heads.get(label)
        _require_sha(got, SHA1_RE, f"{label} head")
        if got != wanted:
            raise PackageInputError(f"Gamescope {label} head mismatch")

    license_path = source / "LICENSE"
    if not license_path.is_file():
        raise PackageInputError("Gamescope licence is missing")
    if _sha256(license_path) != expected.license_sha256:
        raise PackageInputError("Gamescope licence digest mismatch")

    manifest = source / ".github" / "pocketforge-source-closure.tsv"
    if not manifest.is_file():
        raise PackageInputError("tsp-op5a.440.7 dependency manifest is missing")
    if _sha256(manifest) != expected.dependency_manifest_sha256:
        raise PackageInputError("Gamescope dependency manifest digest mismatch")
    dependencies, edge_count = _parse_dependency_manifest(manifest)

    admission, admission_sha256 = _load_admission_receipt(source)
    if admission.get("schema") != "gamescope-source-admission-v1":
        raise PackageInputError("Gamescope admission receipt schema mismatch")
    if admission.get("gamescope_head") != expected.integrated_head:
        raise PackageInputError("Gamescope admitted integration head mismatch")
    if admission.get("manifest_sha256") != expected.dependency_manifest_sha256:
        raise PackageInputError("Gamescope admitted dependency manifest mismatch")
    if admission.get("validated_edges") != 34 or admission.get("verified_project_pins") != 32:
        raise PackageInputError("Gamescope admission closure count mismatch")

    materialization, materialization_sha256 = _load_materialization_receipt(source)
    if materialization.get("schema") != "gamescope-source-materialization-v1":
        raise PackageInputError("Gamescope materialization receipt schema mismatch")
    if materialization.get("gamescope_head") != expected.integrated_head:
        raise PackageInputError("Gamescope materialized integration head mismatch")
    if materialization.get("manifest_sha256") != expected.dependency_manifest_sha256:
        raise PackageInputError("Gamescope materialized dependency manifest mismatch")
    source_tree_sha256 = _require_sha(
        materialization.get("source_tree_sha256"), SHA256_RE,
        "materialized source_tree_sha256")
    if _source_tree_sha256(source) != source_tree_sha256:
        raise PackageInputError("Gamescope materialized source-tree digest mismatch")
    if source_tree_sha256 != expected.source_tree_sha256:
        raise PackageInputError(
            "Gamescope platform-locked source-tree digest mismatch")
    project_pins = len(dependencies)
    receipt_counts = {
        "materialized_git_inputs": 31,
        "generated_root_wrap_aliases": 2,
        "verified_materialized_locator_targets": 33,
    }
    for key, wanted in receipt_counts.items():
        if materialization.get(key) != wanted:
            raise PackageInputError(f"Gamescope materialization {key} mismatch")
    if edge_count != 34 or project_pins != 32:
        raise PackageInputError("Gamescope dependency closure count mismatch")
    for dependency in dependencies:
        bundled_license = _license_bundle_path(source, dependency)
        if not bundled_license.is_file():
            raise PackageInputError(
                f"dependency {dependency.name} licence bundle is missing")
        if _sha256(bundled_license) != dependency.license_sha256:
            raise PackageInputError(
                f"dependency {dependency.name} licence bundle digest mismatch")
    if data.get("dependency_manifest_sha256") != expected.dependency_manifest_sha256:
        raise PackageInputError("Gamescope source receipt dependency manifest mismatch")
    if data.get("admission_receipt_sha256") != admission_sha256:
        raise PackageInputError("Gamescope source receipt admission digest mismatch")
    if data.get("materialization_receipt_sha256") != materialization_sha256:
        raise PackageInputError("Gamescope source receipt materialization digest mismatch")
    if data.get("source_tree_sha256") != source_tree_sha256:
        raise PackageInputError("Gamescope source receipt source-tree digest mismatch")
    return ValidatedSource(
        expected, str(source_url), dependencies, source_tree_sha256, admission_sha256,
        edge_count, project_pins,
        int(materialization["verified_materialized_locator_targets"]),
    )


def render_identity(validated: ValidatedSource, *,
                    meson_configuration: MesonSetupConfiguration,
                    target_arch: str) -> str:
    if target_arch != "aarch64":
        raise PackageInputError(f"Gamescope target architecture is not aarch64: {target_arch}")
    expected = validated.expected
    lines = [
        f"schema={IDENTITY_SCHEMA}",
        f"source_url={validated.source_url}",
        f"upstream_base={expected.upstream_base}",
        f"integrated_head={expected.integrated_head}",
        f"present_head={expected.present_head}",
        f"staging_head={expected.staging_head}",
        f"rotation_head={expected.rotation_head}",
        f"patch_series_sha256={expected.patch_series_sha256}",
        f"meson_options_sha256={meson_configuration.digest()}",
        f"meson_cross_file_sha256={meson_configuration.cross_file_digest()}",
        f"dependency_manifest_sha256={expected.dependency_manifest_sha256}",
        f"admission_receipt_sha256={validated.admission_receipt_sha256}",
        f"source_tree_sha256={validated.source_tree_sha256}",
        f"dependency_edges={validated.validated_edges}",
        f"dependency_project_pins={validated.verified_project_pins}",
        f"verified_locator_targets={validated.verified_locator_targets}",
        f"gamescope_license_sha256={expected.license_sha256}",
        "target_arch=aarch64",
    ]
    lines.extend(
        f"dependency.{dependency.name}.{dependency.revision[:12]}={dependency.revision}"
                 for dependency in validated.dependencies)
    return "\n".join(lines) + "\n"


def configure_build(source: Path, expected: ExpectedSource, *, build_dir: Path,
                    cross_file: Path, identity_out: Path,
                    runner: Callable[..., object] = subprocess.run) -> None:
    validated = validate_source(source, expected)
    configuration = MesonSetupConfiguration(
        source=source, build_dir=build_dir, cross_file=cross_file)
    if configuration.wrap_mode != "nodownload":
        raise PackageInputError(
            "Gamescope Meson setup must use --wrap-mode=nodownload")
    normalized_cross_file = configuration.normalized_cross_file_bytes()
    cross_file.parent.mkdir(parents=True, exist_ok=True)
    cross_file.write_bytes(normalized_cross_file)
    runner(configuration.argv(), check=True)
    identity = render_identity(
        validated, meson_configuration=configuration, target_arch="aarch64")
    identity_out.write_text(identity, encoding="utf-8")


def install_licenses(source: Path, validated: ValidatedSource, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "LICENSE", output / "gamescope-LICENSE")
    os.chmod(output / "gamescope-LICENSE", 0o644)
    for dependency in validated.dependencies:
        license_source = _license_bundle_path(source, dependency)
        destination = output / (
            f"{dependency.name}-{dependency.revision[:12]}-"
            f"{Path(dependency.license_path).name}")
        shutil.copyfile(license_source, destination)
        os.chmod(destination, 0o644)
    shutil.copyfile(source / ".github" / "pocketforge-source-closure.tsv",
                    output / "pocketforge-source-closure.tsv")
    os.chmod(output / "pocketforge-source-closure.tsv", 0o644)


def parse_identity(identity: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for line_number, line in enumerate(identity.splitlines(), start=1):
        if not line or "=" not in line:
            raise PackageInputError(f"installed identity line {line_number} is invalid")
        key, value = line.split("=", 1)
        if not key or not value or key in parsed:
            raise PackageInputError(f"installed identity key is empty or duplicated: {key}")
        parsed[key] = value
    if parsed.get("schema") != IDENTITY_SCHEMA:
        raise PackageInputError("installed identity schema mismatch")
    return parsed


def verify_installed_identity(installed: str, expected: str) -> None:
    parse_identity(installed)
    parse_identity(expected)
    if installed != expected:
        raise PackageInputError("installed identity drift")


def validate_aarch64_elf(readelf_header: str) -> None:
    if re.search(r"^\s*Machine:\s+AArch64\s*$", readelf_header, re.MULTILINE) is None:
        raise PackageInputError("Gamescope binary is not AArch64")


def profile_enabled(device_id: str, mode: str) -> bool:
    return device_id in {"a133-open-7x-gpu", "a133-open-7x-gpu-cts"} and mode == "g1"


def diagnostics_enabled(mode: str, variant: str, *, explicit: bool = False) -> bool:
    return mode == "g1" and variant == "dev" and explicit


def _expected_from_args(args: argparse.Namespace) -> ExpectedSource:
    return ExpectedSource(
        upstream_base=args.upstream_base,
        integrated_head=args.integrated_head,
        present_head=args.present_head,
        staging_head=args.staging_head,
        rotation_head=args.rotation_head,
        patch_series_sha256=args.patch_series_sha256,
        dependency_manifest_sha256=args.dependency_manifest_sha256,
        source_tree_sha256=args.source_tree_sha256,
        license_sha256=args.license_sha256,
    )


def _add_expected_source_args(parser: argparse.ArgumentParser) -> None:
    for option in ("upstream-base", "integrated-head", "present-head", "staging-head",
                   "rotation-head", "patch-series-sha256",
                   "dependency-manifest-sha256", "source-tree-sha256",
                   "license-sha256"):
        parser.add_argument(f"--{option}", required=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate-source")
    validate.add_argument("--source", type=Path, required=True)
    _add_expected_source_args(validate)

    configure = subparsers.add_parser("configure-build")
    configure.add_argument("--source", type=Path, required=True)
    configure.add_argument("--build-dir", type=Path, required=True)
    configure.add_argument("--cross-file", type=Path, required=True)
    configure.add_argument("--identity-out", type=Path, required=True)
    _add_expected_source_args(configure)

    elf = subparsers.add_parser("verify-elf")
    elf.add_argument("header", type=Path)

    licenses = subparsers.add_parser("install-licenses")
    licenses.add_argument("--source", type=Path, required=True)
    licenses.add_argument("--output", type=Path, required=True)
    _add_expected_source_args(licenses)

    args = parser.parse_args(argv)
    try:
        if args.command == "validate-source":
            validate_source(args.source, _expected_from_args(args))
        elif args.command == "configure-build":
            configure_build(
                args.source, _expected_from_args(args),
                build_dir=args.build_dir, cross_file=args.cross_file,
                identity_out=args.identity_out)
        elif args.command == "verify-elf":
            text = (sys.stdin.read() if str(args.header) == "-" else
                    args.header.read_text(encoding="utf-8"))
            validate_aarch64_elf(text)
        else:
            validated = validate_source(args.source, _expected_from_args(args))
            install_licenses(args.source, validated, args.output)
    except (OSError, PackageInputError, subprocess.CalledProcessError) as error:
        print(f"gamescope-package: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
