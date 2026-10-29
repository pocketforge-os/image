#!/usr/bin/env python3
"""Read-only final-byte gate for the assembled A133 app platform runtime."""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import runpy
import sys


RENDERER = runpy.run_path(str(Path(__file__).with_name("render-app-runtime-root.py")))


def verify(rootfs: Path) -> None:
    # Use the renderer's canonical identity and artifact checks. The final
    # build gate must enforce the same identity that the app consumes.
    renderer = RENDERER
    refuse = renderer["refuse"]
    store = rootfs / "usr/lib/pocketforge/platform-runtimes"
    platforms = list((store / "pocketforge-bookworm-aarch64").glob("sha256-*"))
    if len(platforms) != 1:
        refuse("platform_runtime_missing", "expected exactly one sealed app platform runtime")
    platform = platforms[0]
    digest = platform.name.removeprefix("sha256-")
    if platform.is_symlink() or not platform.is_dir() or not re.fullmatch(r"[0-9a-f]{64}", digest):
        refuse("platform_runtime_digest_mismatch", "invalid sealed runtime path")
    renderer["require_platform_abi"](platform)
    abi = json.loads((platform / "abi.json").read_text())
    # Check every recorded ELF and data hash, including ELF-valued aliases in
    # data. The renderer's required ABI ownership check is intentionally narrower.
    for section in ("files", "data"):
        entries = abi.get(section)
        if not isinstance(entries, dict) or not entries:
            refuse("platform_runtime_incompatible", f"invalid ABI {section} map")
        for relative, metadata in entries.items():
            path = PurePosixPath(relative)
            expected = metadata.get("sha256") if isinstance(metadata, dict) else metadata
            if (path.is_absolute() or ".." in path.parts or str(path) != relative
                    or not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected)):
                refuse("platform_runtime_incompatible", f"invalid ABI hash entry: {relative}")
            actual = platform / relative
            if (actual.is_symlink() or not actual.is_file()
                    or renderer["sha256_file"](actual) != expected):
                refuse("platform_runtime_digest_mismatch", f"ABI {section} hash differs: {relative}")
    identity = platform / ".manifest-sha256"
    if (identity.is_symlink() or not identity.is_file()
            or identity.read_text().strip() != digest
            or renderer["platform_manifest_digest"](platform) != digest):
        refuse("platform_runtime_digest_mismatch", "sealed runtime content/identity differs")

    # Steam Link is optional; if installed, verify its final descriptor refers
    # to these exact artifacts using the same read-only checks as the renderer.
    app_id = "org.pocketforge.steamlink"
    manifest = rootfs / f"opt/pocketforge/apps/{app_id}/app.toml"
    if manifest.exists():
        runtime = renderer["load_toml"](manifest)["runtime"]["root"]
        renderer["require_artifacts"](
            app_id=app_id,
            app_digest=renderer["digest_hex"](runtime["digest"], "digest"),
            platform=runtime["platform-runtime"],
            platform_digest=renderer["digest_hex"](runtime["platform-runtime-version"], "platform-runtime-version"),
            app_root_store=rootfs / "var/lib/pocketforge/app-roots",
            platform_runtime_store=store,
            distribution=runtime.get("distribution", "debian-12"),
        )
    print(f"app-platform-runtime-seal=PASS digest={digest} files={len(abi['files'])} data={len(abi['data'])}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rootfs", type=Path)
    try:
        verify(parser.parse_args().rootfs)
    except RENDERER["Refusal"] as error:
        print(f"app-platform-runtime-seal=FAIL reason={error.reason} detail={error}", file=sys.stderr)
        raise SystemExit(1)
