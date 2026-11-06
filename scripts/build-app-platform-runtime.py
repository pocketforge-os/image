#!/usr/bin/env python3
"""Build a content-described host graphics/WSI runtime closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
from typing import NoReturn


NEEDED_RE = re.compile(r"\(NEEDED\).*\[([^]]+)\]")
SONAME_RE = re.compile(r"\(SONAME\).*\[([^]]+)\]")


def fail(message: str) -> NoReturn:
    raise SystemExit(f"platform-runtime build: {message}")


def load_config(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"invalid config: {error}")
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        fail("config schema_version must be 1")
    return value


def path_list(config: dict[str, object], name: str) -> list[str]:
    value = config.get(name)
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        fail(f"config {name} must be a string array")
    result: list[str] = []
    for item in value:
        path = PurePosixPath(item)
        if path.is_absolute() or ".." in path.parts or str(path) != item or not item:
            fail(f"config {name} has a non-canonical path: {item!r}")
        if item in result:
            fail(f"config {name} has a duplicate: {item!r}")
        result.append(item)
    return result


def elf_metadata(readelf: Path, path: Path) -> tuple[str, list[str]]:
    try:
        result = subprocess.run(
            [str(readelf), "-d", str(path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        fail(f"cannot execute readelf: {error}")
    if result.returncode != 0:
        fail(f"readelf failed for {path}: {result.stderr.strip()}")
    sonames = SONAME_RE.findall(result.stdout)
    if len(sonames) != 1:
        fail(f"ELF must have exactly one SONAME: {path}")
    return sonames[0], NEEDED_RE.findall(result.stdout)


VERSION_RE = re.compile(r"^([A-Za-z][A-Za-z0-9]*)_([0-9]+(?:\.[0-9]+)*)$")


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in value.split("."))


def version_within_floor(version: str, floor: dict[str, str]) -> bool:
    """True only for NAMESPACE_N[.N...] at or below that namespace's floor.

    Private, tag-like (GLIBC_ABI_DT_RELR) and unlisted namespaces never
    compare: they fail closed and need an explicit reviewed floor change.
    """
    match = VERSION_RE.match(version)
    if match is None or match.group(1) not in floor:
        return False
    return version_tuple(match.group(2)) <= version_tuple(floor[match.group(1)])


def symbol_version_floor(
    config: dict[str, object], base_sonames: set[str]
) -> dict[str, dict[str, str]] | None:
    value = config.get("base_symbol_version_floor")
    if value is None:
        return None
    if not isinstance(value, dict) or any(
        not isinstance(soname, str)
        or not isinstance(namespaces, dict)
        or not namespaces
        or any(
            not isinstance(name, str)
            or not isinstance(floor, str)
            or VERSION_RE.match(f"{name}_{floor}") is None
            for name, floor in namespaces.items()
        )
        for soname, namespaces in value.items()
    ):
        fail("config base_symbol_version_floor must map SONAMEs to {NAMESPACE: N.N}")
    if set(value) != base_sonames:
        fail("config base_symbol_version_floor must cover every base SONAME exactly")
    return {soname: dict(sorted(value[soname].items())) for soname in sorted(value)}


def elf_versions(readelf: Path, path: Path) -> tuple[list[str], dict[str, list[str]]]:
    """Parse `readelf -V`: (defined versions, {needed file: [versions]})."""
    try:
        result = subprocess.run(
            [str(readelf), "-V", "-W", str(path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        fail(f"cannot execute readelf: {error}")
    if result.returncode != 0:
        fail(f"readelf -V failed for {path}: {result.stderr.strip()}")
    section = None
    current_file = None
    defined: set[str] = set()
    needs: dict[str, set[str]] = {}
    for line in result.stdout.splitlines():
        if line.startswith("Version definition section"):
            section = "def"
            continue
        if line.startswith("Version needs section"):
            section = "need"
            continue
        if line.startswith("Version symbols section"):
            section = None
            continue
        if section == "def" and "Name: " in line and "Flags: BASE" not in line:
            defined.add(line.split("Name: ", 1)[1].split()[0])
        elif section == "need" and "File: " in line:
            current_file = line.split("File: ", 1)[1].split()[0]
            needs.setdefault(current_file, set())
        elif section == "need" and "Name: " in line:
            if current_file is None:
                fail(f"readelf -V version need without a file: {path}")
            needs[current_file].add(line.split("Name: ", 1)[1].split()[0])
    return sorted(defined), {name: sorted(items) for name, items in sorted(needs.items())}


def check_symbol_versions(
    files: dict[str, dict[str, object]],
    sonames: dict[str, str],
    floor: dict[str, dict[str, str]],
) -> None:
    for relative, metadata in sorted(files.items()):
        needs = metadata["version_needs"]
        assert isinstance(needs, dict)
        for dependency, versions in needs.items():
            for version in versions:
                if dependency in floor:
                    if not version_within_floor(version, floor[dependency]):
                        namespace = version.split("_", 1)[0]
                        limit = floor[dependency].get(namespace)
                        detail = (
                            f"exceeds app-root floor {namespace}_{limit}"
                            if limit is not None and VERSION_RE.match(version)
                            else "has no app-root floor"
                        )
                        fail(
                            f"{metadata['soname']} needs {dependency} {version}, {detail}"
                        )
                    continue
                provider = sonames.get(dependency)
                if provider is None:
                    fail(
                        f"{metadata['soname']} needs version {version} from "
                        f"{dependency}, which is neither base nor bundled"
                    )
                defined = files[provider]["version_defs"]
                assert isinstance(defined, list)
                if version not in defined:
                    fail(
                        f"{metadata['soname']} needs {dependency} {version}, "
                        "not defined by the bundled provider"
                    )


def resolve(host_root: Path, library_dirs: list[str], soname: str) -> Path:
    for directory in library_dirs:
        candidate = host_root / directory / soname
        if candidate.exists() and candidate.is_file():
            return candidate
    fail(f"unresolved non-base dependency: {soname}")


def relative_to_host(host_root: Path, path: Path) -> str:
    try:
        return path.relative_to(host_root).as_posix()
    except ValueError:
        fail(f"path escaped host root: {path}")


def copy_regular(host_root: Path, source: Path, stage: Path, relative: str) -> str:
    resolved = source.resolve(strict=True)
    relative_to_host(host_root.resolve(), resolved)
    if not resolved.is_file():
        fail(f"source is not a regular file: {source}")
    destination = stage / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(resolved, destination)
    os.chmod(destination, 0o755 if os.access(resolved, os.X_OK) else 0o644)
    return hashlib.sha256(destination.read_bytes()).hexdigest()


def json_library_paths(config: dict[str, object], data: list[str]) -> dict[str, str]:
    value = config.get("json_library_paths", {})
    if not isinstance(value, dict) or any(
        not isinstance(key, str) or not isinstance(item, str)
        for key, item in value.items()
    ):
        fail("config json_library_paths must map strings to strings")
    result: dict[str, str] = {}
    for relative, runtime_path in value.items():
        if relative not in data:
            fail(f"json_library_paths key is not a data path: {relative!r}")
        path = PurePosixPath(runtime_path)
        if (
            not path.is_absolute()
            or ".." in path.parts
            or not runtime_path.startswith("/run/pocketforge/platform-runtime/")
        ):
            fail(f"non-canonical platform runtime library path: {runtime_path!r}")
        result[relative] = runtime_path
    return result


def copy_discovery_json(
    host_root: Path,
    source: Path,
    stage: Path,
    relative: str,
    runtime_path: str,
) -> str:
    resolved = source.resolve(strict=True)
    relative_to_host(host_root.resolve(), resolved)
    try:
        value = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"invalid discovery JSON {relative}: {error}")
    if not isinstance(value, dict) or not isinstance(value.get("ICD"), dict):
        fail(f"discovery JSON has no ICD object: {relative}")
    library_path = value["ICD"].get("library_path")
    if not isinstance(library_path, str):
        fail(f"discovery JSON has no ICD.library_path string: {relative}")
    value["ICD"]["library_path"] = runtime_path
    destination = stage / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    os.chmod(destination, 0o644)
    return hashlib.sha256(destination.read_bytes()).hexdigest()


def remove_tree(path: Path) -> None:
    for child in sorted(path.rglob("*"), reverse=True):
        if child.is_dir() and not child.is_symlink():
            child.rmdir()
        else:
            child.unlink()
    path.rmdir()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host-root", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--readelf", default="readelf", type=Path)
    args = parser.parse_args()

    config = load_config(args.config)
    library_dirs = path_list(config, "library_dirs")
    seeds = path_list(config, "seeds")
    data = path_list(config, "data")
    discovery_paths = json_library_paths(config, data)
    base_value = config.get("base_sonames")
    if not isinstance(base_value, list) or any(not isinstance(item, str) for item in base_value):
        fail("config base_sonames must be a string array")
    base_sonames = set(base_value)
    version_floor = symbol_version_floor(config, base_sonames)
    host_distribution = config.get("host_distribution")
    if host_distribution != "debian-12":
        fail("host_distribution must be debian-12")
    if not args.host_root.is_dir():
        fail(f"host root is missing: {args.host_root}")
    if args.output.exists():
        fail(f"output already exists: {args.output}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=f".{args.output.name}.", dir=args.output.parent))
    complete = False
    sonames: dict[str, str] = {}
    root_provided: set[str] = set()
    try:
        queue: list[Path] = []
        for relative in seeds:
            source = args.host_root / relative
            if not source.exists() or not source.is_file():
                fail(f"seed is missing or not a file: {relative}")
            queue.append(source)

        files: dict[str, dict[str, object]] = {}
        seen_sources: set[Path] = set()
        while queue:
            source = queue.pop(0)
            resolved = source.resolve(strict=True)
            if resolved in seen_sources:
                continue
            seen_sources.add(resolved)
            soname, needed = elf_metadata(args.readelf, source)
            relative = relative_to_host(args.host_root, source)
            previous = sonames.get(soname)
            if previous is not None and previous != relative:
                fail(f"duplicate SONAME provider: {soname}: {previous}, {relative}")
            sonames[soname] = relative
            files[relative] = {
                "sha256": copy_regular(args.host_root, source, stage, relative),
                "soname": soname,
                "needed": sorted(needed),
            }
            if version_floor is not None:
                version_defs, version_needs = elf_versions(args.readelf, source)
                files[relative]["version_defs"] = version_defs
                files[relative]["version_needs"] = version_needs
            for dependency in needed:
                if dependency in base_sonames:
                    root_provided.add(dependency)
                elif dependency not in sonames:
                    queue.append(resolve(args.host_root, library_dirs, dependency))

        if version_floor is not None:
            check_symbol_versions(files, sonames, version_floor)

        data_files: dict[str, str] = {}
        for relative in data:
            source = args.host_root / relative
            if not source.exists() or not source.is_file():
                fail(f"data file is missing or not a file: {relative}")
            runtime_path = discovery_paths.get(relative)
            if runtime_path is None:
                digest = copy_regular(args.host_root, source, stage, relative)
            else:
                digest = copy_discovery_json(
                    args.host_root, source, stage, relative, runtime_path
                )
            data_files[relative] = digest

        manifest = {
            "schema_version": 1,
            "host_distribution": host_distribution,
            "base_abi_policy": "bookworm-built platform libraries on app-root glibc/libstdc++",
            "base_abi_sonames": sorted(base_sonames),
            "sonames": dict(sorted(sonames.items())),
            "root_provided_sonames": sorted(root_provided),
            "files": dict(sorted(files.items())),
            "data": dict(sorted(data_files.items())),
            "json_library_paths": dict(sorted(discovery_paths.items())),
        }
        if version_floor is not None:
            manifest["base_symbol_version_floor"] = version_floor
        (stage / "abi.json").write_text(
            json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        os.replace(stage, args.output)
        complete = True
    finally:
        if not complete and stage.exists():
            remove_tree(stage)

    print(
        f"platform-runtime=PASS sonames={len(sonames)} "
        f"root_provided={len(root_provided)} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
