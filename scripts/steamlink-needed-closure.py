#!/usr/bin/env python3
"""Mechanically compute the Steam Link NEEDED closure and bind it to the archive.

Verifies the Valve detached signature (repo keyring, via steamlink-fetch.py),
extracts the archive with the fetcher's safe extractor, runs `readelf -d` over
EVERY ELF in the tree and collects NEEDED / SONAME / RUNPATH / RPATH.  A NEEDED
soname is resolved when it is a base ABI soname (platform runtime config), or
is provided by a file in the tree (basename or SONAME) reachable through
RUNPATH/RPATH ($ORIGIN expanded) or the launcher's LD_LIBRARY_PATH dirs
(<top>/lib, <top>/Qt-5.14.1/lib).  Everything else is `unresolved` and carries
provenance (the ELFs that need it).  No hand lists.

Modes:
  generate: write build/steamlink-shell-needed-closure.json
  --check:  regenerate in memory and fail if it differs from the committed file
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FETCH = ROOT / "apps/steamlink/steamlink-fetch.py"
SEEDS = ROOT / "build/app-platform-runtime-a133-open-v1.json"
MANIFEST = ROOT / "build/steamlink-shell-needed-closure.json"
# The steamlink-ffmpeg59 runtime bind supplies these (fetcher EXPECTED_LIBRARIES).
RUNTIME_BINDS = ["libavcodec.so.59", "libavutil.so.57", "libswresample.so.4"]

NEEDED_RE = re.compile(r"\(NEEDED\).*\[([^]]+)\]")
SONAME_RE = re.compile(r"\(SONAME\).*\[([^]]+)\]")
RPATH_RE = re.compile(r"\((?:RUNPATH|RPATH)\).*\[([^]]+)\]")


def load_fetcher():
    spec = importlib.util.spec_from_file_location("steamlink_fetch", FETCH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def is_elf(path: Path) -> bool:
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as handle:
        return handle.read(4) == b"\x7fELF"


def dynamic(path: Path) -> tuple[list[str], list[str], list[str]]:
    out = subprocess.run(
        ["readelf", "-d", str(path)], text=True, capture_output=True, check=False
    ).stdout
    needed = NEEDED_RE.findall(out)
    sonames = SONAME_RE.findall(out)
    paths = [p for group in RPATH_RE.findall(out) for p in group.split(":") if p]
    return needed, sonames, paths


def compute(tree: Path, base_sonames: set[str]) -> dict:
    top = tree / "steamlink"
    elfs = sorted(p for p in tree.rglob("*") if is_elf(p))
    if not elfs:
        raise SystemExit("no ELF files found in archive tree")
    provided: dict[str, set[Path]] = {}
    info = {}
    for elf in elfs:
        needed, sonames, rpaths = dynamic(elf)
        info[elf] = (needed, rpaths)
        for name in {elf.name, *sonames}:
            provided.setdefault(name, set()).add(elf.parent)
    for link in tree.rglob("*"):
        if link.is_symlink() and link.resolve().is_file():
            provided.setdefault(link.name, set()).add(link.parent)
    launcher_dirs = {(top / "lib").resolve(), (top / "Qt-5.14.1/lib").resolve()}

    unresolved: dict[str, list[str]] = {}
    resolved_in_tree: set[str] = set()
    for elf, (needed, rpaths) in info.items():
        search = set(launcher_dirs)
        for entry in rpaths:
            search.add(Path(entry.replace("$ORIGIN", str(elf.parent))).resolve())
        for soname in needed:
            if soname in base_sonames:
                continue
            if any(d.resolve() in search for d in provided.get(soname, ())):
                resolved_in_tree.add(soname)
                continue
            unresolved.setdefault(soname, []).append(str(elf.relative_to(tree)))
    return {
        "elf_count": len(elfs),
        "unresolved": sorted(unresolved),
        "provenance": {k: sorted(set(v)) for k, v in sorted(unresolved.items())},
    }


def generate(archive: Path, signature: Path, expected_sha: str | None) -> dict:
    fetch = load_fetcher()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if expected_sha and digest != expected_sha:
        raise ValueError(f"archive sha256 {digest} != expected {expected_sha}")
    match = fetch.ARCHIVE_NAME_RE.fullmatch(archive.name)
    if not match:
        raise ValueError(f"non-canonical archive name: {archive.name}")
    version = match.group("version")
    fetch.verify_signature(
        archive,
        signature,
        fetch.__dict__["Path"](ROOT / "apps/steamlink/valve-steamlink-release-key.gpg"),
        fetch.DEFAULT_KEYRING_SHA256,
        fetch.DEFAULT_FINGERPRINT,
    )
    base = set(json.loads(SEEDS.read_text())["base_sonames"])
    with tempfile.TemporaryDirectory(prefix="steamlink-closure.") as scratch:
        tree = Path(scratch) / "tree"
        fetch.safe_extract(archive, tree, version)
        result = compute(tree, base)
    return {
        "schema_version": 1,
        "version": version,
        "archive_sha256": digest,
        "signature_verified": True,
        "elf_count": result["elf_count"],
        "unresolved": result["unresolved"],
        "runtime_binds": RUNTIME_BINDS,
        "provenance": result["provenance"],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--archive", type=Path, required=True)
    ap.add_argument("--signature", type=Path, required=True)
    ap.add_argument("--expected-sha256")
    ap.add_argument("--output", type=Path, default=MANIFEST)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    try:
        result = generate(args.archive, args.signature, args.expected_sha256)
    except Exception as error:  # Refusal carries .reason
        reason = getattr(error, "reason", "error")
        print(f"STEAMLINK-CLOSURE refused reason={reason} detail={error}", file=sys.stderr)
        return 70
    text = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.check:
        if args.output.read_text() != text:
            print("STEAMLINK-CLOSURE manifest is stale; regenerate", file=sys.stderr)
            return 1
        return 0
    args.output.write_text(text)
    print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
