#!/usr/bin/env python3
"""Verify mount destinations in read-only app RootImages against effective units."""

from __future__ import annotations

import argparse
import pathlib
import re
import shlex
import shutil
import subprocess
import sys

BIND_KEYS = ("BindReadOnlyPaths", "BindPaths")
DIRECTORY_KEYS = {"StateDirectory": "/var/lib", "CacheDirectory": "/var/cache", "RuntimeDirectory": "/run"}
LIST_KEYS = (*BIND_KEYS, "ReadWritePaths", *DIRECTORY_KEYS)


def logical_lines(path: pathlib.Path) -> list[str]:
    lines: list[str] = []
    pending = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith(("#", ";")):
            continue
        pending += stripped
        if pending.endswith("\\"):
            pending = pending[:-1] + " "
            continue
        lines.append(pending)
        pending = ""
    if pending:
        raise ValueError(f"{path}: unterminated continuation")
    return lines


def instance_from_unit_path(path: pathlib.Path) -> str | None:
    name = path.name.removesuffix(".d")
    prefix, suffix = "pf-app@", ".service"
    if not name.startswith(prefix) or not name.endswith(suffix):
        return None
    return name[len(prefix) : -len(suffix)]


def unit_paths(systemd_dir: pathlib.Path) -> dict[str, list[pathlib.Path]]:
    # An instantiated unit replaces the template; drop-ins from both scopes are
    # merged by filename, with the instance winning a same-name collision.
    instances = {instance_from_unit_path(path) for pattern in
                 ("pf-app@*.service", "pf-app@*.service.d")
                 for path in systemd_dir.glob(pattern)}
    grouped = {}
    for instance in sorted(value for value in instances if value):
        name = f"pf-app@{instance}.service"
        unit = systemd_dir / name
        if not unit.exists():
            unit = systemd_dir / "pf-app@.service"
        paths = [unit] if unit.exists() else []
        dropins = {}
        for directory in (systemd_dir / "pf-app@.service.d", systemd_dir / (name + ".d")):
            for path in directory.glob("*.conf"):
                dropins[path.name] = path
        grouped[instance] = paths + [dropins[key] for key in sorted(dropins)]
    return grouped


def parse_unit(paths: list[pathlib.Path], instance: str) -> tuple[str | None, list[tuple[str, str]]]:
    root_image: str | None = None
    values: dict[str, list[str]] = {key: [] for key in LIST_KEYS}
    for path in paths:
        section = ""
        for line in logical_lines(path):
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
                continue
            if section != "Service" or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key not in ("RootImage", *LIST_KEYS):
                continue
            try:
                words = shlex.split(value, posix=True)
            except ValueError as error:
                raise ValueError(f"{path}: invalid {key}: {error}") from error
            words = [word.replace("%i", instance) for word in words]
            if key == "RootImage":
                if len(words) > 1:
                    raise ValueError(f"{path}: multiple RootImage paths")
                root_image = words[0] if words else None
            elif words:
                values[key].extend(words)
            else:
                values[key].clear()
    return root_image, [(key, word) for key in LIST_KEYS for word in values[key]]


def image_paths(image: pathlib.Path, unsquashfs: str) -> dict[str, str]:
    result = subprocess.run([unsquashfs, "-no-progress", "-lln", str(image)],
                            check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(f"unsquashfs failed for {image} (rc={result.returncode}): {result.stderr.strip()}")
    paths = {}
    for raw in result.stdout.splitlines():
        # Numeric ls format: mode uid/gid size date time path [-> target].
        match = re.match(r"^([dlcbps-])\S*\s+\S+\s+\d+\s+\S+\s+\S+\s+squashfs-root(?:/(.*))?$", raw)
        if match:
            relative = (match[2] or "").split(" -> ", 1)[0]
            paths["/" + relative] = match[1]
    if paths.get("/") != "d":
        raise RuntimeError(f"unsquashfs returned no typed root inventory for {image}")
    return paths


def absolute_path(value: str) -> str:
    path = pathlib.PurePosixPath(value)
    if not path.is_absolute() or ".." in path.parts or "%" in value:
        raise ValueError(f"expected a resolved absolute path, got {value!r}")
    return str(path)


def destination(directive: str, value: str) -> tuple[str, bool]:
    if directive in DIRECTORY_KEYS:
        relative = value.split(":", 1)[0]
        if not relative or pathlib.PurePosixPath(relative).is_absolute():
            raise ValueError(f"invalid {directive}: {value!r}")
        return absolute_path(DIRECTORY_KEYS[directive] + "/" + relative), True
    fields = value.lstrip("-+!").split(":", 2)
    target = fields[1] if directive in BIND_KEYS and len(fields) > 1 and fields[1] else fields[0]
    return absolute_path(target), False


def host_path(root: pathlib.Path, absolute: str) -> pathlib.Path:
    return root.joinpath(*pathlib.PurePosixPath(absolute_path(absolute)).parts[1:])


def audit(root: pathlib.Path, unsquashfs: str) -> list[str]:
    errors: list[str] = []
    rooted_units = checked_targets = 0
    for instance, paths in sorted(unit_paths(root / "etc/systemd/system").items()):
        try:
            root_image, targets = parse_unit(paths, instance)
            if root_image is None:
                continue
            rooted_units += 1
            image = host_path(root, root_image)
            if not image.is_file():
                raise ValueError(f"RootImage is missing: {image}")
            contents = image_paths(image, unsquashfs)
            for directive, value in targets:
                target, directory = destination(directive, value)
                checked_targets += 1
                if target not in contents:
                    errors.append(f"app={instance}: {directive} destination missing from RootImage: {target} (binding {value!r})")
                    continue
                if directory and contents[target] != "d":
                    errors.append(f"app={instance}: {directive} destination is not a directory: {target}")
                for parent in pathlib.PurePosixPath(target).parents:
                    if contents.get(str(parent)) != "d":
                        errors.append(f"app={instance}: {directive} parent is not a directory: {parent}")
        except (ValueError, RuntimeError) as error:
            errors.append(f"app={instance}: {error}")
    if not errors:
        print(f"app-root-bind-targets=PASS rooted_units={rooted_units} bind_targets={checked_targets}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--unsquashfs", default="unsquashfs")
    args = parser.parse_args()
    unsquashfs = shutil.which(args.unsquashfs)
    if unsquashfs is None:
        print(f"app-root-bind-targets: missing tool: {args.unsquashfs}", file=sys.stderr)
        return 2
    errors = audit(args.root.resolve(), unsquashfs)
    for error in errors:
        print(f"app-root-bind-targets: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
