#!/usr/bin/env python3
"""Render and verify the image-owned platform support contract."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
from pathlib import Path


APP_INPUTS = (
    "PF_APP_RUNTIME_FAMILY",
    "PF_APP_RUNTIME_ABI",
    "PF_APP_PLATFORM_VERSION",
    "PF_APP_CAPABILITIES",
)


def fatal(message: str) -> "NoReturn":
    print(f"FATAL: {message}", file=sys.stderr)
    raise SystemExit(1)


def runtime_capabilities(runtime_source: Path) -> set[str]:
    source_path = runtime_source / "crates/pf-app-manifest/src/lib.rs"
    try:
        source = source_path.read_text(encoding="utf-8")
    except OSError as error:
        fatal(f"cannot read runtime capability vocabulary at {source_path}: {error}")
    match = re.search(
        r"pub const KNOWN_CAPABILITIES: &\[&str\] = &\[(.*?)\];",
        source,
        flags=re.DOTALL,
    )
    if match is None:
        fatal("cannot locate runtime pf-app-manifest KNOWN_CAPABILITIES")
    capabilities = re.findall(r'"([a-z0-9-]+)"', match.group(1))
    if not capabilities or len(capabilities) != len(set(capabilities)):
        fatal("runtime pf-app-manifest capability vocabulary is empty or duplicated")
    return set(capabilities)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--soc", required=True)
    parser.add_argument("--gpu-model", required=True)
    parser.add_argument("--runtime-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    values = {name: os.environ.get(name, "") for name in APP_INPUTS}
    enabled = args.soc == "sun50iw10p1" and args.gpu_model == "open"
    if not enabled:
        present = [name for name, value in values.items() if value]
        if present:
            fatal(
                "PF_APP_* inputs are forbidden outside A133-open: "
                + ", ".join(present)
            )
        if args.output.exists():
            fatal(f"platform support file exists outside A133-open: {args.output}")
        return

    missing = [name for name, value in values.items() if not value]
    if missing:
        fatal("missing A133-open platform inputs: " + ", ".join(missing))

    family = values["PF_APP_RUNTIME_FAMILY"]
    runtime_abi = values["PF_APP_RUNTIME_ABI"]
    platform_version = values["PF_APP_PLATFORM_VERSION"]
    capabilities = values["PF_APP_CAPABILITIES"].split()
    if re.fullmatch(r"pocketforge/[a-z0-9-]+", family) is None:
        fatal(f"invalid PF_APP_RUNTIME_FAMILY: {family!r}")
    for name, value in (
        ("PF_APP_RUNTIME_ABI", runtime_abi),
        ("PF_APP_PLATFORM_VERSION", platform_version),
    ):
        if re.fullmatch(r"[1-9][0-9]*", value) is None:
            fatal(f"invalid {name}: {value!r}")
    if not capabilities:
        fatal("PF_APP_CAPABILITIES must contain at least one capability")
    if capabilities != sorted(capabilities):
        fatal("PF_APP_CAPABILITIES must be sorted")
    if len(capabilities) != len(set(capabilities)):
        fatal("PF_APP_CAPABILITIES must be unique")
    unknown = sorted(set(capabilities) - runtime_capabilities(args.runtime_source))
    if unknown:
        fatal("PF_APP_CAPABILITIES contains runtime-unknown values: " + ", ".join(unknown))

    expected = {
        "schema_version": 1,
        "runtime_family": family,
        "runtime_abi": runtime_abi,
        "platform_version": platform_version,
        "supported_capabilities": capabilities,
    }
    rendered = (
        "schema_version = 1\n"
        f"runtime_family = {json.dumps(family)}\n"
        f"runtime_abi = {json.dumps(runtime_abi)}\n"
        f"platform_version = {json.dumps(platform_version)}\n"
        "supported_capabilities = ["
        + ", ".join(json.dumps(capability) for capability in capabilities)
        + "]\n"
    )
    try:
        parsed = tomllib.loads(rendered)
    except tomllib.TOMLDecodeError as error:
        fatal(f"generated platform support TOML does not parse: {error}")
    if parsed != expected:
        fatal(f"generated platform support TOML did not round-trip exactly: {parsed!r}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
