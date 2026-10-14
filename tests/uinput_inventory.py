#!/usr/bin/env python3
"""Reject unclassified kernel-input creation or exposure occurrences."""

import argparse
from collections import Counter, defaultdict
import hashlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "tests/uinput-inventory.txt"
PATTERN = re.compile(
    r"/dev/uinput|\bUI_(?:DEV_)?CREATE\b|\bUInput\s*\(|"
    r"\bVirtualDevice(?:::\w+)?\s*\(|(?:--device|-v|--mount)[^\n]*/dev/input"
)


def fingerprint(path, line):
    digest = hashlib.sha256(line.strip().encode()).hexdigest()
    return f"{path}\t{digest}"


def tracked():
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return [Path(raw.decode("utf-8")) for raw in result.stdout.split(b"\0") if raw]


def occurrences(extra=None):
    found = []
    for rel in tracked():
        if rel in {MANIFEST.relative_to(ROOT), Path(__file__).relative_to(ROOT)}:
            continue
        raw = (ROOT / rel).read_bytes()
        if b"\0" in raw:
            continue
        try:
            lines = raw.decode("utf-8").splitlines()
        except UnicodeDecodeError as exc:
            raise RuntimeError(
                f"tracked non-NUL file is not UTF-8 and cannot be inventoried: {rel}"
            ) from exc
        for number, line in enumerate(lines, 1):
            if PATTERN.search(line):
                found.append(
                    (fingerprint(rel.as_posix(), line), rel.as_posix(), number, line.strip())
                )
    if extra:
        for path, line in extra:
            found.append((fingerprint(path, line), path, 1, line))
    return found


def load_manifest():
    return Counter(
        line.split("\t#", 1)[0]
        for line in MANIFEST.read_text().splitlines()
        if line and not line.startswith("#")
    )


def check(extra=None, quiet=False, allowed=None):
    allowed = load_manifest() if allowed is None else allowed
    items = occurrences(extra)
    live = Counter(item[0] for item in items)
    by_key = defaultdict(list)
    for item in items:
        by_key[item[0]].append(item)
    unclassified = live - allowed
    stale = allowed - live
    if not quiet:
        for key, count in unclassified.items():
            for _, path, number, line in by_key[key][-count:]:
                print(
                    f"unclassified uinput occurrence: {path}:{number}: {line}",
                    file=sys.stderr,
                )
        for key, count in stale.items():
            print(f"stale uinput inventory entry ({count}): {key}", file=sys.stderr)
    return not unclassified and not stale


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--emit", action="store_true")
    args = parser.parse_args()
    if args.emit:
        for key, path, number, line in occurrences():
            print(f"{key}\t# {path}:{number} {line}")
        return 0
    required_occurrences = {
        "apps/hello-pocketforge/slice.conf",
        "rootfs-overlay/etc/systemd/system/pf-input-broker.service.d/10-app-session.conf",
        "tests/session-authority-systemd/session-authority-test-tmpfiles.conf",
        "tests/session-authority-systemd/fixture",
    }
    observed_paths = {item[1] for item in occurrences()}
    missing_classes = sorted(required_occurrences - observed_paths)
    tracked_paths = {path.as_posix() for path in tracked()}
    if "build/Dockerfile.pf" not in tracked_paths:
        missing_classes.append("build/Dockerfile.pf (not scanned)")
    if args.self_test and missing_classes:
        print(
            "inventory self-test failed: source/policy classes were skipped: "
            + ", ".join(missing_classes),
            file=sys.stderr,
        )
        return 2
    known = occurrences()[0]
    if args.self_test and check([(known[1], known[3])], quiet=True):
        print(
            "inventory self-test failed: duplicate live occurrence was accepted",
            file=sys.stderr,
        )
        return 2
    stale = load_manifest()
    stale[f"seeded/stale.c\t{'0' * 64}"] += 1
    if args.self_test and check(quiet=True, allowed=stale):
        print(
            "inventory self-test failed: stale manifest entry was accepted",
            file=sys.stderr,
        )
        return 2
    seeded_classes = (
        ("seeded/violation.conf", "DeviceAllow=/dev/uinput rw"),
        ("seeded/fixture", 'open("/dev/uinput", O_RDWR);'),
        ("seeded/Dockerfile", "RUN test -e /dev/uinput"),
        ("build/seeded-policy", "--device /dev/input/event0"),
    )
    for path, line in seeded_classes:
        if args.self_test and check([(path, line)], quiet=True):
            print(
                f"inventory self-test failed: seeded violation was accepted: {path}",
                file=sys.stderr,
            )
            return 2
    if not check():
        return 1
    print(
        "uinput-inventory: PASS seeded_classes=conf,extensionless,Dockerfile,build:red "
        "duplicate_live=red stale_manifest=red clean_tree=green"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
