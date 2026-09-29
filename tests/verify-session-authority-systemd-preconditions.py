#!/usr/bin/env python3
"""Verify that installed test units have recipe-provided path prerequisites."""

from __future__ import annotations

import argparse
import re
import shlex
from pathlib import Path


CONDITION = re.compile(
    r"^\s*(ConditionPathExists|ConditionPathIsDirectory|AssertPathExists)\s*=\s*(.*?)\s*$"
)
DIRECTORY_TYPES = {"d", "D", "v", "q", "Q"}
SAFE_PROVIDER_TYPES = DIRECTORY_TYPES | {"f", "F", "L", "L+", "p", "p+"}


def fail(message: str) -> None:
    raise SystemExit(f"session-authority path-preconditions: FAIL: {message}")


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parent.parent
    fixtures = root / "tests/session-authority-systemd"
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--containerfile",
        type=Path,
        default=fixtures / "Containerfile",
    )
    parser.add_argument(
        "--provider-config",
        type=Path,
        default=fixtures / "session-authority-test-tmpfiles.conf",
    )
    parser.add_argument("--unit", action="append", type=Path)
    args = parser.parse_args()
    if args.unit is None:
        args.unit = [
            root / "rootfs-overlay/etc/systemd/system/pf-app@.service",
            fixtures / "pocketforge-foreground.target",
            root
            / "rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf",
            fixtures / "pf-shell-selected.service",
            fixtures / "session-authority-test.target",
        ]
    return args


def tmpfiles_providers(path: Path) -> dict[str, str]:
    providers: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        fields = shlex.split(raw_line, comments=True)
        if not fields:
            continue
        if len(fields) < 2 or not fields[1].startswith("/"):
            fail(f"invalid tmpfiles entry {path}:{line_number}: {raw_line}")
        entry_type, provided_path = fields[:2]
        if entry_type not in SAFE_PROVIDER_TYPES:
            fail(
                f"unsafe or unsupported tmpfiles provider type={entry_type} "
                f"path={provided_path} at {path}:{line_number}"
            )
        providers[provided_path] = entry_type
    return providers


def positive_condition_path(value: str) -> str | None:
    value = value.strip()
    if not value:
        return None
    value = value.removeprefix("|")
    if value.startswith("!"):
        return None
    if not value.startswith("/"):
        fail(f"unsupported non-absolute path condition: {value}")
    return value


def main() -> None:
    args = parse_args()
    recipe = args.containerfile.read_text()
    expected_copy = (
        f"COPY {args.provider_config.name} "
        "/usr/lib/tmpfiles.d/session-authority-test.conf"
    )
    if expected_copy not in recipe:
        fail(f"recipe does not install provider config: {expected_copy}")

    providers = tmpfiles_providers(args.provider_config)
    fb0_fields = next(
        (
            shlex.split(line, comments=True)
            for line in args.provider_config.read_text().splitlines()
            if shlex.split(line, comments=True)[1:2] == ["/dev/fb0"]
        ),
        None,
    )
    if fb0_fields != ["f", "/dev/fb0", "0600", "root", "root", "-"]:
        fail("/dev/fb0 must be an empty regular file owned by root with mode 0600")

    conditions = 0
    for unit in args.unit:
        for line_number, line in enumerate(unit.read_text().splitlines(), start=1):
            match = CONDITION.match(line)
            if match is None:
                continue
            directive, value = match.groups()
            conditioned_path = positive_condition_path(value)
            if conditioned_path is None:
                continue
            conditions += 1
            provider_type = providers.get(conditioned_path)
            if provider_type is None:
                fail(
                    f"unprovided {directive}={conditioned_path} "
                    f"at {unit}:{line_number}"
                )
            if directive == "ConditionPathIsDirectory" and provider_type not in DIRECTORY_TYPES:
                fail(
                    f"non-directory provider type={provider_type} for "
                    f"{directive}={conditioned_path} at {unit}:{line_number}"
                )

    print(
        "session-authority path-preconditions: PASS "
        f"conditions={conditions} providers={len(providers)} fb0=regular units={len(args.unit)}"
    )


if __name__ == "__main__":
    main()
