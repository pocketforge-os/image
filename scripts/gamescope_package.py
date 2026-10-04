#!/usr/bin/env python3
"""Validate and render the fail-closed Gamescope package identity."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
from typing import Iterable


SHA1_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
POCKETFORGE_SOURCE_PREFIX = "https://github.com/pocketforge-os/"
SOURCE_SCHEMA = "pocketforge.gamescope-source/v1"
IDENTITY_SCHEMA = "pocketforge.gamescope-build/v1"


class PackageInputError(ValueError):
    """An exact source, provenance, architecture, or profile gate failed."""


@dataclass(frozen=True)
class ExpectedSource:
    upstream_base: str
    integrated_head: str
    present_head: str
    staging_head: str
    rotation_head: str
    patch_series_sha256: str
    dependency_manifest_sha256: str
    license_sha256: str


@dataclass(frozen=True)
class ValidatedSource:
    expected: ExpectedSource
    source_url: str
    dependencies: tuple["Dependency", ...]


@dataclass(frozen=True)
class Dependency:
    name: str
    revision: str
    meson_path: str
    license_path: str
    license_sha256: str


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


def _parse_dependency_manifest(path: Path) -> tuple[Dependency, ...]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as error:
        raise PackageInputError(
            "tsp-op5a.440.7 dependency manifest is missing") from error
    dependencies: list[Dependency] = []
    seen: set[str] = set()
    for line_number, line in enumerate(lines, start=1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 10:
            raise PackageInputError(
                f"dependency manifest row {line_number} has {len(fields)} fields, expected 10")
        (name, kind, revision, archive_filename, archive_root, archive_sha,
         archive_url, meson_path, license_path, license_sha) = fields
        if not re.fullmatch(r"[a-z0-9][a-z0-9+_.-]*", name) or name in seen:
            raise PackageInputError(f"dependency manifest name is invalid or duplicated: {name}")
        if kind not in {"gitlink", "wrap-file"}:
            raise PackageInputError(f"dependency {name} has unsupported source kind {kind}")
        _require_sha(revision, SHA1_RE, f"dependency {name} revision")
        _require_sha(archive_sha, SHA256_RE, f"dependency {name} archive digest")
        _require_sha(license_sha, SHA256_RE, f"dependency {name} licence digest")
        if ("/" in archive_filename or "/" in archive_root or
                license_path.startswith("/") or ".." in license_path.split("/")):
            raise PackageInputError(f"dependency {name} has unsafe archive metadata")
        if not archive_url.startswith(POCKETFORGE_SOURCE_PREFIX):
            raise PackageInputError(
                f"dependency {name} has non-PocketForge source URL: {archive_url}")
        if not meson_path.startswith("subprojects/"):
            raise PackageInputError(f"dependency {name} has invalid Meson path")
        dependencies.append(Dependency(
            name=name,
            revision=revision,
            meson_path=meson_path,
            license_path=license_path,
            license_sha256=license_sha,
        ))
        seen.add(name)
    if not dependencies:
        raise PackageInputError("tsp-op5a.440.7 dependency manifest is empty")
    return tuple(sorted(dependencies, key=lambda dependency: dependency.name))


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

    manifest = source / ".github" / "meson-sources.lock"
    if not manifest.is_file():
        raise PackageInputError("tsp-op5a.440.7 dependency manifest is missing")
    if _sha256(manifest) != expected.dependency_manifest_sha256:
        raise PackageInputError("Gamescope dependency manifest digest mismatch")
    dependencies = _parse_dependency_manifest(manifest)
    return ValidatedSource(expected, str(source_url), dependencies)


def _options_digest(options: Iterable[str]) -> str:
    canonical = "".join(f"{option}\n" for option in sorted(options))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def render_identity(validated: ValidatedSource, *, meson_options: Iterable[str],
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
        f"meson_options_sha256={_options_digest(meson_options)}",
        f"dependency_manifest_sha256={expected.dependency_manifest_sha256}",
        f"gamescope_license_sha256={expected.license_sha256}",
        "target_arch=aarch64",
    ]
    lines.extend(f"dependency.{dependency.name}={dependency.revision}"
                 for dependency in validated.dependencies)
    return "\n".join(lines) + "\n"


def install_licenses(source: Path, validated: ValidatedSource, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / "LICENSE", output / "gamescope-LICENSE")
    os.chmod(output / "gamescope-LICENSE", 0o644)
    for dependency in validated.dependencies:
        if dependency.meson_path.endswith(".wrap"):
            dependency_root = source / "subprojects" / dependency.name
        else:
            dependency_root = source / dependency.meson_path
        license_source = dependency_root / dependency.license_path
        if not license_source.is_file():
            raise PackageInputError(
                f"dependency {dependency.name} licence is missing after offline setup")
        if _sha256(license_source) != dependency.license_sha256:
            raise PackageInputError(f"dependency {dependency.name} licence digest mismatch")
        destination = output / f"{dependency.name}-{Path(dependency.license_path).name}"
        shutil.copyfile(license_source, destination)
        os.chmod(destination, 0o644)
    shutil.copyfile(source / ".github" / "meson-sources.lock",
                    output / "meson-sources.lock")
    os.chmod(output / "meson-sources.lock", 0o644)


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
    return device_id == "a133-open-7x-gpu" and mode == "g1"


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
        license_sha256=args.license_sha256,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate-source")
    validate.add_argument("--source", type=Path, required=True)
    for option in ("upstream-base", "integrated-head", "present-head", "staging-head",
                   "rotation-head", "patch-series-sha256",
                   "dependency-manifest-sha256", "license-sha256"):
        validate.add_argument(f"--{option}", required=True)
    validate.add_argument("--meson-option", action="append", default=[])
    validate.add_argument("--identity-out", type=Path, required=True)

    elf = subparsers.add_parser("verify-elf")
    elf.add_argument("header", type=Path)

    licenses = subparsers.add_parser("install-licenses")
    licenses.add_argument("--source", type=Path, required=True)
    licenses.add_argument("--output", type=Path, required=True)
    for option in ("upstream-base", "integrated-head", "present-head", "staging-head",
                   "rotation-head", "patch-series-sha256",
                   "dependency-manifest-sha256", "license-sha256"):
        licenses.add_argument(f"--{option}", required=True)

    args = parser.parse_args(argv)
    try:
        if args.command == "validate-source":
            validated = validate_source(args.source, _expected_from_args(args))
            identity = render_identity(
                validated, meson_options=args.meson_option, target_arch="aarch64")
            args.identity_out.write_text(identity, encoding="utf-8")
        elif args.command == "verify-elf":
            text = (sys.stdin.read() if str(args.header) == "-" else
                    args.header.read_text(encoding="utf-8"))
            validate_aarch64_elf(text)
        else:
            validated = validate_source(args.source, _expected_from_args(args))
            install_licenses(args.source, validated, args.output)
    except (OSError, PackageInputError) as error:
        print(f"gamescope-package: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
