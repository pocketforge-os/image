#!/usr/bin/env python3
"""Verify that rooted app unit bind destinations exist in each RootImage."""

from __future__ import annotations

import argparse
import pathlib
import shlex
import shutil
import subprocess
import sys


BIND_KEYS = ("BindReadOnlyPaths", "BindPaths")


def logical_lines(path: pathlib.Path) -> list[str]:
    lines: list[str] = []
    pending = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        pending += stripped
        if pending.endswith("\\"):
            pending = pending[:-1] + " "
            continue
        lines.append(pending)
        pending = ""
    if pending:
        lines.append(pending)
    return lines


def instance_from_unit_path(path: pathlib.Path) -> str | None:
    name = path.parent.name[:-2] if path.parent.name.endswith(".d") else path.name
    prefix = "pf-app@"
    suffix = ".service"
    if not name.startswith(prefix) or not name.endswith(suffix):
        return None
    return name[len(prefix) : -len(suffix)]


def unit_paths(systemd_dir: pathlib.Path) -> dict[str, list[pathlib.Path]]:
    grouped: dict[str, list[pathlib.Path]] = {}
    for path in sorted(systemd_dir.glob("pf-app@*.service")):
        instance = instance_from_unit_path(path)
        if instance:
            grouped.setdefault(instance, []).append(path)
    for directory in sorted(systemd_dir.glob("pf-app@*.service.d")):
        instance = instance_from_unit_path(directory / "placeholder")
        if instance:
            grouped.setdefault(instance, []).extend(sorted(directory.glob("*.conf")))
    return grouped


def parse_unit(paths: list[pathlib.Path], instance: str) -> tuple[str | None, list[tuple[str, str]]]:
    root_image: str | None = None
    binds: dict[str, list[str]] = {key: [] for key in BIND_KEYS}
    for path in paths:
        for line in logical_lines(path):
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            if key not in ("RootImage", *BIND_KEYS):
                continue
            try:
                words = shlex.split(value, posix=True)
            except ValueError as error:
                raise ValueError(f"{path}: invalid {key}: {error}") from error
            words = [word.replace("%i", instance) for word in words]
            if key == "RootImage":
                root_image = words[-1] if words else None
            elif words:
                binds[key].extend(words)
            else:
                binds[key].clear()
    return root_image, [(key, word) for key in BIND_KEYS for word in binds[key]]


def image_paths(image: pathlib.Path, unsquashfs: str) -> set[str]:
    result = subprocess.run(
        [unsquashfs, "-no-progress", "-ls", str(image)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(
            f"unsquashfs failed for {image} (rc={result.returncode}): {result.stderr.strip()}"
        )
    paths = {"/"}
    for raw in result.stdout.splitlines():
        value = raw.strip()
        if value == "squashfs-root":
            paths.add("/")
        elif value.startswith("squashfs-root/"):
            paths.add("/" + value.removeprefix("squashfs-root/"))
    return paths


def bind_destination(value: str) -> str:
    value = value.lstrip("-+!")
    fields = value.split(":", 2)
    destination = fields[1] if len(fields) > 1 and fields[1] else fields[0]
    return str(pathlib.PurePosixPath(destination))


def host_path(root: pathlib.Path, absolute: str) -> pathlib.Path:
    path = pathlib.PurePosixPath(absolute.lstrip("-+!"))
    if not path.is_absolute():
        raise ValueError(f"expected an absolute path, got {absolute!r}")
    return root.joinpath(*path.parts[1:])


def audit(root: pathlib.Path, unsquashfs: str) -> list[str]:
    systemd_dir = root / "etc/systemd/system"
    errors: list[str] = []
    rooted_units = 0
    checked_targets = 0
    for instance, paths in sorted(unit_paths(systemd_dir).items()):
        try:
            root_image, binds = parse_unit(paths, instance)
        except ValueError as error:
            errors.append(str(error))
            continue
        if root_image is None:
            continue
        rooted_units += 1
        try:
            image = host_path(root, root_image)
        except ValueError as error:
            errors.append(f"app={instance}: {error}")
            continue
        if not image.is_file():
            errors.append(f"app={instance}: RootImage is missing: {image}")
            continue
        try:
            contents = image_paths(image, unsquashfs)
        except RuntimeError as error:
            errors.append(f"app={instance}: {error}")
            continue
        for directive, value in binds:
            destination = bind_destination(value)
            checked_targets += 1
            if destination not in contents:
                errors.append(
                    f"app={instance}: {directive} destination missing from RootImage: "
                    f"{destination} (binding {value!r})"
                )
    if errors:
        return errors
    print(
        f"app-root-bind-targets=PASS rooted_units={rooted_units} "
        f"bind_targets={checked_targets}"
    )
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--unsquashfs", default="unsquashfs")
    args = parser.parse_args()
    root = args.root.resolve()
    unsquashfs = shutil.which(args.unsquashfs)
    if unsquashfs is None:
        print(f"app-root-bind-targets: missing tool: {args.unsquashfs}", file=sys.stderr)
        return 2
    errors = audit(root, unsquashfs)
    for error in errors:
        print(f"app-root-bind-targets: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
