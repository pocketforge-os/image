#!/usr/bin/env python3
"""Fail when an overlay file is neither installed nor explicitly retained.

The check is intentionally static and hermetic.  It follows install helpers
named by scripts/build-rootfs.sh, expands the small shell-list patterns used by
those installers, and compares both directions against rootfs-overlay.
"""

from __future__ import annotations

import argparse
import itertools
import re
import shlex
import sys
from collections import defaultdict
from pathlib import Path, PurePosixPath


OVERLAY_TOKEN = re.compile(
    r"(?:rootfs-overlay/|\$\{overlay\}/|\$\{src\}/)"
    r"([A-Za-z0-9_@.+/$\{\}-]+)"
)
VARIABLE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
SIMPLE_VALUE = re.compile(r"^[A-Za-z0-9_@.+/-]+$")
OWNER_DIR = "etc/systemd/system/pocketforge-foreground.target.d"
MANIFEST = "NOT-INSTALLED"


def code_without_comments(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def shell_words(body: str) -> list[str]:
    try:
        words = shlex.split(body.replace("\\\n", " "), comments=False)
    except ValueError:
        return []
    return [word for word in words if SIMPLE_VALUE.fullmatch(word)]


def variable_values(code: str) -> dict[str, set[str]]:
    values: dict[str, set[str]] = defaultdict(set)

    for match in re.finditer(
        r"(?m)^\s*(?:local\s+)?([A-Za-z_][A-Za-z0-9_]*)="
        r"[\"']?([A-Za-z0-9_@.+/-]+)[\"']?\s*$",
        code,
    ):
        values[match.group(1)].add(match.group(2))

    arrays: dict[str, set[str]] = defaultdict(set)
    for match in re.finditer(
        r"(?ms)^\s*([A-Za-z_][A-Za-z0-9_]*)=\(\s*(.*?)\s*\)", code
    ):
        arrays[match.group(1)].update(shell_words(match.group(2)))

    for match in re.finditer(
        r"(?ms)\bfor\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.*?)\s*;\s*do",
        code,
    ):
        name, body = match.groups()
        array_ref = re.fullmatch(r'"?\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}"?', body.strip())
        if array_ref:
            values[name].update(arrays.get(array_ref.group(1), set()))
        else:
            values[name].update(shell_words(body))

    # PF_PANEL_OWNER is a deliberately finite renderer.  Count only explicit
    # case labels; never infer coverage from a broad 10-owner-* filesystem glob.
    owner_case = re.search(
        r'(?ms)case\s+"?\$\{PF_PANEL_OWNER\}"?\s+in(.*?)\besac\b', code
    )
    if owner_case:
        for label in re.findall(r"(?m)^\s*([A-Za-z0-9_-]+)\s*\)", owner_case.group(1)):
            values["PF_PANEL_OWNER"].add(label)

    return values


def expand(expression: str, values: dict[str, set[str]]) -> set[str]:
    names = VARIABLE.findall(expression)
    if not names:
        return {expression}
    choices: list[list[str]] = []
    for name in names:
        choices.append(sorted(values.get(name, set())))
    if any(not choice for choice in choices):
        return set()
    expanded = set()
    for selected in itertools.product(*choices):
        result = expression
        for name, value in zip(names, selected):
            result = result.replace("${" + name + "}", value, 1)
        expanded.add(result)
    return expanded


def installer_sources(repo: Path) -> list[Path]:
    entry = repo / "scripts/build-rootfs.sh"
    if not entry.is_file():
        raise ValueError("missing installer entry scripts/build-rootfs.sh")

    sources = {entry}
    pending = [entry]
    helper_pattern = re.compile(r"scripts/(install-[A-Za-z0-9_.-]+\.sh)")
    source_pattern = re.compile(r"scripts/([A-Za-z0-9_.-]+\.sh)")
    while pending:
        current = pending.pop()
        code = code_without_comments(current.read_text(encoding="utf-8"))
        names = set(helper_pattern.findall(code))
        for line in code.splitlines():
            if re.search(r"(?:^|\s)(?:source|\.)\s", line):
                names.update(source_pattern.findall(line))
        for name in sorted(names):
            helper = repo / "scripts" / name
            if not helper.is_file():
                raise ValueError(
                    f"installer helper referenced by {current.relative_to(repo)} is missing: "
                    f"scripts/{name}"
                )
            if helper not in sources:
                sources.add(helper)
                pending.append(helper)
    return sorted(sources)


def references(repo: Path, sources: list[Path]) -> dict[str, set[str]]:
    found: dict[str, set[str]] = defaultdict(set)
    all_code = "\n".join(
        code_without_comments(source.read_text(encoding="utf-8")) for source in sources
    )

    for source in sources:
        rel_source = source.relative_to(repo).as_posix()
        code = code_without_comments(source.read_text(encoding="utf-8"))
        values = variable_values(code)
        src_is_overlay = bool(re.search(r"(?m)^\s*src=.*?/rootfs-overlay\s*$", code))
        for match in OVERLAY_TOKEN.finditer(code):
            expression = match.group(1)
            if match.group(0).startswith("${src}/") and not src_is_overlay:
                if not expression.startswith("rootfs-overlay/"):
                    continue
                expression = expression.removeprefix("rootfs-overlay/")
            if expression.startswith("../"):
                continue
            for path in expand(expression, values):
                found[path].add(rel_source)

    # install-default-app-support derives sibling drop-ins from the pf-app unit
    # directory passed by build-rootfs.sh.  Expand those concrete basenames,
    # but only when both halves of that data flow are present.
    combined = all_code
    unit_prefix = "rootfs-overlay/etc/systemd/system/pf-app@.service"
    if unit_prefix in combined and 'systemd_source="$(dirname -- "${unit}")"' in combined:
        for match in re.finditer(r'\$\{systemd_source\}/([A-Za-z0-9_@.+/-]+)', combined):
            found[f"etc/systemd/system/{match.group(1)}"].add(
                "scripts/install-default-app-support.sh"
            )

    return found


def read_manifest(overlay: Path) -> tuple[dict[str, str], list[str]]:
    path = overlay / MANIFEST
    if not path.is_file():
        return {}, [f"MANIFEST missing rootfs-overlay/{MANIFEST}"]

    entries: dict[str, str] = {}
    errors: list[str] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.startswith("#"):
            continue
        fields = raw.split("\t")
        if len(fields) != 2 or not fields[0] or not fields[1].strip():
            errors.append(
                f"MANIFEST {MANIFEST}:{number}: expected path<TAB>one-line reason"
            )
            continue
        rel, reason = fields[0], fields[1].strip()
        pure = PurePosixPath(rel)
        if pure.is_absolute() or ".." in pure.parts or rel == MANIFEST:
            errors.append(f"MANIFEST {MANIFEST}:{number}: invalid overlay path {rel}")
            continue
        if rel in entries:
            errors.append(f"MANIFEST {MANIFEST}:{number}: duplicate path {rel}")
            continue
        entries[rel] = reason
        if not (overlay / rel).is_file() and not (overlay / rel).is_symlink():
            errors.append(f"MANIFEST {MANIFEST}:{number}: path does not exist: {rel}")
    return entries, errors


def check(repo: Path) -> int:
    overlay = repo / "rootfs-overlay"
    if not overlay.is_dir():
        print("OVERLAY_COVERAGE ERROR missing rootfs-overlay", file=sys.stderr)
        return 2

    try:
        sources = installer_sources(repo)
        refs = references(repo, sources)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"OVERLAY_COVERAGE ERROR {error}", file=sys.stderr)
        return 2

    manifest, errors = read_manifest(overlay)
    files = {
        path.relative_to(overlay).as_posix()
        for path in overlay.rglob("*")
        if (path.is_file() or path.is_symlink()) and path.name != MANIFEST
    }

    for rel in sorted(files - refs.keys() - manifest.keys()):
        errors.append(f"ORPHAN {rel}")
    for rel in sorted(refs.keys() - files):
        for source in sorted(refs[rel]):
            errors.append(f"DANGLING {source}:{rel}")

    if errors:
        for error in errors:
            print(f"OVERLAY_COVERAGE {error}", file=sys.stderr)
        print(
            f"OVERLAY_COVERAGE FAIL files={len(files)} errors={len(errors)}",
            file=sys.stderr,
        )
        return 1

    referenced = len(files & refs.keys())
    print(
        f"OVERLAY_COVERAGE PASS files={len(files)} referenced={referenced} "
        f"not_installed={len(manifest)}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    return check(args.repo.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
