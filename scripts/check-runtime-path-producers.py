#!/usr/bin/env python3
"""Audit app-policy paths against sources shipped in the same rootfs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shlex
import sys
from typing import Iterable


SCHEMA = "pocketforge.runtime-path-producers/v1"
PATH_DIRECTIVES = {
    "BindPaths",
    "BindReadOnlyPaths",
    "InaccessiblePaths",
    "ReadOnlyPaths",
    "ReadWritePaths",
}
DIRECTORY_DIRECTIVES = {
    "StateDirectory": "/var/lib",
    "CacheDirectory": "/var/cache",
    "RuntimeDirectory": "/run",
}
UNIT_DIRS = (
    "etc/systemd/system",
    "usr/lib/systemd/system",
    "lib/systemd/system",
)
TMPFILES_DIRS = ("etc/tmpfiles.d", "usr/lib/tmpfiles.d", "lib/tmpfiles.d")


class AuditError(Exception):
    pass


def load_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise AuditError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise AuditError(f"{path} is not an object")
    return value


def logical_lines(path: Path) -> Iterable[str]:
    pending = ""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise AuditError(f"cannot read unit {path}: {error}") from error
    for raw in lines:
        line = f"{pending}{raw.strip()}"
        if line.endswith("\\"):
            pending = f"{line[:-1]} "
            continue
        pending = ""
        if line and not line.startswith(("#", ";")):
            yield line
    if pending:
        raise AuditError(f"unterminated continuation in {path}")


def assignments(path: Path) -> Iterable[tuple[str, list[str]]]:
    for line in logical_lines(path):
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        try:
            words = shlex.split(value, comments=False, posix=True)
        except ValueError as error:
            raise AuditError(f"cannot parse {path}: {line}: {error}") from error
        yield key.strip(), words


def unit_instance(path: Path) -> str | None:
    name = path.name
    if name.endswith(".conf") and path.parent.name.endswith(".service.d"):
        name = path.parent.name.removesuffix(".d")
    if "@" not in name or not name.endswith(".service"):
        return None
    return name.split("@", 1)[1].removesuffix(".service") or None


def expand_instance(value: str, path: Path) -> str:
    instance = unit_instance(path)
    return value.replace("%i", instance) if instance is not None else value


def shipped_units(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for relative in UNIT_DIRS:
        directory = root / relative
        if not directory.is_dir():
            continue
        for path in sorted(directory.iterdir()):
            if path.name.endswith((".service", ".socket")) and path.is_file():
                result.setdefault(path.name, path)
    return result


def shipped_tmpfiles(root: Path) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for relative in TMPFILES_DIRS:
        directory = root / relative
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("*.conf")):
            if path.is_file():
                result.setdefault(path.name, path)
    return result


def declarative_producers(
    units: dict[str, Path], tmpfiles: dict[str, Path]
) -> dict[str, str]:
    result: dict[str, str] = {}
    for name, unit in units.items():
        for key, words in assignments(unit):
            if key in DIRECTORY_DIRECTIVES:
                prefix = DIRECTORY_DIRECTIVES[key]
                for word in words:
                    relative = word.split(":", 1)[0].lstrip("-")
                    if relative:
                        path = expand_instance(f"{prefix}/{relative}", unit)
                        result.setdefault(path, f"unit:{name}:{key}")
            elif key == "ListenStream":
                for word in words:
                    path = expand_instance(word, unit)
                    if path.startswith("/"):
                        result.setdefault(path, f"socket:{name}")
    for name, config in tmpfiles.items():
        for line in logical_lines(config):
            try:
                fields = shlex.split(line, comments=True, posix=True)
            except ValueError as error:
                raise AuditError(f"cannot parse tmpfiles {config}: {error}") from error
            if len(fields) >= 2 and fields[1].startswith("/"):
                result.setdefault(fields[1], f"tmpfiles:{name}")
    return result


def verify_manifest(
    path: Path, units: dict[str, Path], tmpfiles: dict[str, Path]
) -> dict[str, str]:
    manifest = load_json(path)
    if manifest.get("schema") != SCHEMA:
        raise AuditError(f"unsupported producer schema in {path}")
    records = manifest.get("producers")
    optional = manifest.get("optional", [])
    if not isinstance(records, dict):
        raise AuditError(f"{path}: producers must be an object")
    if not isinstance(optional, list) or any(
        not isinstance(item, str) for item in optional
    ):
        raise AuditError(f"{path}: optional must be a string array")
    if optional:
        raise AuditError(
            f"{path}: optional producer exemptions are unsupported; "
            "mark optional systemd sources with '-'"
        )
    verified: dict[str, str] = {}
    errors: list[str] = []
    for produced_path, value in sorted(records.items()):
        if not isinstance(produced_path, str) or not produced_path.startswith("/"):
            errors.append(f"invalid producer path: {produced_path}")
            continue
        if produced_path.startswith("/dev/") or not isinstance(value, dict):
            errors.append(f"invalid producer record: {produced_path}")
            continue
        references = [key for key in ("unit", "socket", "tmpfiles") if key in value]
        if len(references) != 1:
            errors.append(
                "producer must name exactly one unit, socket, or tmpfiles entry: "
                f"{produced_path}"
            )
            continue
        kind = references[0]
        name = value[kind]
        if not isinstance(name, str) or not name:
            errors.append(f"invalid {kind} producer name: {produced_path}")
        elif kind in ("unit", "socket") and name not in units:
            errors.append(f"producer {kind} missing: {produced_path}: {name}")
        elif kind == "tmpfiles" and name not in tmpfiles:
            errors.append(f"producer tmpfiles missing: {produced_path}: {name}")
        else:
            verified[produced_path] = f"{kind}:{name}"
    if errors:
        raise AuditError("\n".join(errors))
    return verified


def installed_inventories(root: Path) -> list[Path]:
    directory = root / "usr/share/pocketforge/app-policy"
    return sorted(directory.glob("*.resources.json")) if directory.is_dir() else []


def installed_policy_units(root: Path) -> list[Path]:
    directory = root / "etc/systemd/system"
    if not directory.is_dir():
        return []
    units = [
        path
        for path in sorted(directory.glob("pf-app@*.service"))
        if path.name != "pf-app@.service" and path.is_file()
    ]
    units.extend(
        path
        for path in sorted(directory.glob("pf-app@*.service.d/*.conf"))
        if path.is_file()
    )
    return units


def add_inventory_consumers(path: Path, consumers: dict[str, list[str]]) -> None:
    inventory = load_json(path)
    resources = inventory.get("resources")
    if not isinstance(resources, dict):
        raise AuditError(f"{path}: resources must be an object")
    for resource, values in resources.items():
        if not isinstance(resource, str) or not isinstance(values, list) or any(
            not isinstance(value, str) for value in values
        ):
            raise AuditError(f"{path}: invalid resource {resource!r}")
        for value in values:
            if not value.startswith("/"):
                raise AuditError(f"{path}: resource path is not absolute: {value}")
            if not value.startswith("/dev/"):
                consumers.setdefault(value, []).append(f"{path}:resource:{resource}")


def strip_path_prefix(value: str) -> tuple[str, bool]:
    prefix_length = 0
    while prefix_length < len(value) and value[prefix_length] in "-+!":
        prefix_length += 1
    prefixes = value[:prefix_length]
    return value[prefix_length:], "-" in prefixes


def add_unit_consumers(path: Path, consumers: dict[str, list[str]]) -> None:
    for directive, words in assignments(path):
        if directive not in PATH_DIRECTIVES:
            continue
        for word in words:
            source = word.split(":", 1)[0] if directive.startswith("Bind") else word
            source, optional = strip_path_prefix(source)
            source = expand_instance(source, path)
            if optional:
                continue
            if not source.startswith("/"):
                raise AuditError(f"{path}:{directive}: source is not absolute: {source}")
            if not source.startswith("/dev/"):
                consumers.setdefault(source, []).append(f"{path}:{directive}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--inventory", type=Path, action="append", default=[])
    parser.add_argument("--unit", type=Path, action="append", default=[])
    parser.add_argument("--producers", type=Path, required=True)
    args = parser.parse_args()

    try:
        units = shipped_units(args.root)
        tmpfiles = shipped_tmpfiles(args.root)
        consumers: dict[str, list[str]] = {}
        inventories = list(
            dict.fromkeys([*args.inventory, *installed_inventories(args.root)])
        )
        policy_units = list(
            dict.fromkeys([*args.unit, *installed_policy_units(args.root)])
        )
        producer_units = dict(units)
        for policy_unit in policy_units:
            producer_units.setdefault(policy_unit.name, policy_unit)
        automatic = declarative_producers(producer_units, tmpfiles)
        declared = verify_manifest(args.producers, units, tmpfiles)
        for inventory in inventories:
            add_inventory_consumers(inventory, consumers)
        for unit in policy_units:
            add_unit_consumers(unit, consumers)

        errors: list[str] = []
        for source, source_consumers in sorted(consumers.items()):
            staged = args.root / source.lstrip("/")
            if staged.exists() or source in automatic or source in declared:
                continue
            for consumer in source_consumers:
                errors.append(f"missing producer: {source}: consumer={consumer}")
        if errors:
            raise AuditError("\n".join(errors))
    except AuditError as error:
        print(
            "\n".join(
                f"producer-audit: {line}" for line in str(error).splitlines()
            ),
            file=sys.stderr,
        )
        return 1

    print(
        "runtime-path-producer-audit=PASS "
        f"inventories={len(inventories)} units={len(policy_units)} paths={len(consumers)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
