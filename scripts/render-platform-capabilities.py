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

# Contract schema 2 (runtime pf-app-manifest parse_platform_contract): these
# facts are required on every schema-2 contract; gles_max/vulkan_max are the
# only optional ones and are omitted unless the descriptor declares them.
# Platform descriptor schemas 2 and 3 carry the same source facts; descriptor
# v3's input_profile is owned by the input router and is not consumed here.
VOCABULARY_CONSTANTS = (
    "KNOWN_CAPABILITIES",
    "KNOWN_INPUTS",
    "KNOWN_GLES_VERSIONS",
    "KNOWN_VULKAN_VERSIONS",
)

# Descriptor [[inputs]] kinds (platform schemas/capabilities.schema.json). Rows
# with class="system" are ambient system authority, never app-bindable, and are
# excluded before derivation; any other unknown class or kind fails closed so a
# new control class can never silently under-declare the contract.
INPUT_CLASSES = ("gamepad", "system")
INPUT_KINDS = ("button", "hat", "stick", "stick-click", "trigger")

U32_MAX = 0xFFFFFFFF


def fatal(message: str) -> "NoReturn":
    print(f"FATAL: {message}", file=sys.stderr)
    raise SystemExit(1)


def runtime_vocabularies(runtime_source: Path) -> dict[str, list[str]]:
    """Parse every vocabulary from the pinned runtime source (single source of
    truth; a runtime predating contract schema 2 fails closed here)."""
    source_path = runtime_source / "crates/pf-app-manifest/src/lib.rs"
    try:
        source = source_path.read_text(encoding="utf-8")
    except OSError as error:
        fatal(f"cannot read runtime capability vocabulary at {source_path}: {error}")
    vocabularies: dict[str, list[str]] = {}
    for name in VOCABULARY_CONSTANTS:
        match = re.search(
            r"pub const %s: &\[&str\] = &\[(.*?)\];" % re.escape(name),
            source,
            flags=re.DOTALL,
        )
        if match is None:
            fatal(f"cannot locate runtime pf-app-manifest {name}")
        tokens = re.findall(r'"([^"]*)"', match.group(1))
        if not tokens or "" in tokens or len(tokens) != len(set(tokens)):
            fatal(f"runtime pf-app-manifest vocabulary {name} is empty or duplicated")
        vocabularies[name] = tokens
    return vocabularies


def positive_int(value: object, what: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        fatal(f"device descriptor {what} is not an integer: {value!r}")
    if value < 1 or value > U32_MAX:
        fatal(f"device descriptor {what} is out of range: {value!r}")
    return value


def load_descriptor(path: Path) -> dict:
    try:
        descriptor = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError, UnicodeDecodeError) as error:
        fatal(f"cannot read device descriptor at {path}: {error}")
    if descriptor.get("schema_version") not in (2, 3):
        fatal(
            "device descriptor schema_version must be 2 or 3 "
            f"([memory]/[graphics] are descriptor-v2 facts): "
            f"{descriptor.get('schema_version')!r}"
        )
    return descriptor


def descriptor_memory(descriptor: dict) -> tuple[int, int]:
    memory = descriptor.get("memory")
    if not isinstance(memory, dict):
        fatal("device descriptor is missing the [memory] table required by contract schema 2")
    facts = []
    for key in ("physical_mib", "app_budget_mib"):
        if key not in memory:
            fatal(f"device descriptor [memory] is missing {key}, required by contract schema 2")
        facts.append(positive_int(memory[key], f"[memory].{key}"))
    return facts[0], facts[1]


def descriptor_graphics(
    descriptor: dict, vocabularies: dict[str, list[str]]
) -> dict[str, str]:
    graphics = descriptor.get("graphics")
    if graphics is None:
        return {}
    if not isinstance(graphics, dict):
        fatal("device descriptor [graphics] must be a table")
    unknown = sorted(set(graphics) - {"gles_max", "vulkan_max"})
    if unknown:
        fatal("device descriptor [graphics] has unknown keys: " + ", ".join(unknown))
    facts = {}
    for key, constant in (
        ("gles_max", "KNOWN_GLES_VERSIONS"),
        ("vulkan_max", "KNOWN_VULKAN_VERSIONS"),
    ):
        if key not in graphics:
            continue
        value = graphics[key]
        if not isinstance(value, str) or value not in vocabularies[constant]:
            fatal(
                f"device descriptor [graphics].{key} is not in runtime {constant}: {value!r}"
            )
        facts[key] = value
    return facts


def descriptor_tables(descriptor: dict, key: str) -> list[dict]:
    rows = descriptor.get(key, [])
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        fatal(f"device descriptor [[{key}]] must be an array of tables")
    return rows


def descriptor_inputs(descriptor: dict, known_inputs: list[str]) -> list[str]:
    derived = set()
    sticks = 0
    for row in descriptor_tables(descriptor, "inputs"):
        input_class = row.get("class", "gamepad")
        if input_class not in INPUT_CLASSES:
            fatal(f"device descriptor [[inputs]] row has unknown class {input_class!r}")
        if input_class == "system":
            continue
        kind = row.get("kind")
        if kind not in INPUT_KINDS:
            fatal(f"device descriptor [[inputs]] row has unknown kind {kind!r}")
        if kind == "button":
            derived.add("buttons")
        elif kind == "hat":
            derived.add("dpad")
        elif kind == "stick":
            sticks += 1
    if sticks >= 1:
        derived.add("stick")
    if sticks >= 2:
        derived.add("two_sticks")
    for screen in descriptor_tables(descriptor, "screens"):
        touch = screen.get("touch")
        if touch is None:
            continue
        if not isinstance(touch, dict):
            fatal("device descriptor [[screens]] touch must be a table")
        derived.add("touch")
    unexpected = sorted(derived - set(known_inputs))
    if unexpected:
        fatal("derived input tokens are unknown to the runtime: " + ", ".join(unexpected))
    tokens = [token for token in known_inputs if token in derived]
    if not tokens:
        fatal(
            "device descriptor derives no app-facing inputs; "
            "contract schema 2 requires the inputs fact"
        )
    return tokens


def descriptor_display(descriptor: dict) -> tuple[int, int]:
    primaries = [
        screen
        for screen in descriptor_tables(descriptor, "screens")
        if screen.get("role") == "primary"
    ]
    if len(primaries) != 1:
        fatal(
            f"device descriptor must declare exactly one primary screen, got {len(primaries)}"
        )
    canvas = primaries[0].get("render_canvas")
    if not isinstance(canvas, dict):
        fatal("device descriptor primary screen is missing the render_canvas table")
    unknown = sorted(set(canvas) - {"w", "h"})
    if unknown:
        fatal("device descriptor render_canvas has unknown keys: " + ", ".join(unknown))
    for key in ("w", "h"):
        if key not in canvas:
            fatal(f"device descriptor primary render_canvas is missing {key}")
    return (
        positive_int(canvas["w"], "primary render_canvas.w"),
        positive_int(canvas["h"], "primary render_canvas.h"),
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--soc", required=True)
    parser.add_argument("--gpu-model", required=True)
    parser.add_argument(
        "--gamescope-mode", choices=("not-shipped", "g1"), default="not-shipped"
    )
    parser.add_argument("--runtime-source", required=True, type=Path)
    parser.add_argument(
        "--descriptor",
        required=True,
        help="staged device descriptor path (A133-open only; empty on every other profile)",
    )
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
        if args.descriptor:
            fatal(f"device descriptor is forbidden outside A133-open: {args.descriptor}")
        if args.output.exists():
            fatal(f"platform support file exists outside A133-open: {args.output}")
        return

    missing = [name for name, value in values.items() if not value]
    if missing:
        fatal("missing A133-open platform inputs: " + ", ".join(missing))
    if not args.descriptor:
        fatal("A133-open requires --descriptor with the staged device descriptor")
    descriptor_path = Path(args.descriptor)
    if not descriptor_path.is_file():
        fatal(f"A133-open device descriptor is not a regular file: {descriptor_path}")

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

    vocabularies = runtime_vocabularies(args.runtime_source)
    unknown = sorted(set(capabilities) - set(vocabularies["KNOWN_CAPABILITIES"]))
    if unknown:
        fatal("PF_APP_CAPABILITIES contains runtime-unknown values: " + ", ".join(unknown))
    if args.gamescope_mode == "g1":
        if "x11" not in vocabularies["KNOWN_CAPABILITIES"]:
            fatal("g1 requires the runtime x11 capability vocabulary")
        capabilities = sorted(set(capabilities) | {"x11"})

    descriptor = load_descriptor(descriptor_path)
    physical_memory_mib, app_memory_budget_mib = descriptor_memory(descriptor)
    graphics = descriptor_graphics(descriptor, vocabularies)
    inputs = descriptor_inputs(descriptor, vocabularies["KNOWN_INPUTS"])
    width, height = descriptor_display(descriptor)

    expected = {
        "schema_version": 2,
        "runtime_family": family,
        "runtime_abi": runtime_abi,
        "platform_version": platform_version,
        "supported_capabilities": capabilities,
        "physical_memory_mib": physical_memory_mib,
        "app_memory_budget_mib": app_memory_budget_mib,
        "inputs": inputs,
        "display": {"width": width, "height": height},
        "production": True,
        "landlock_mode": "required",
        "landlock_full_min_abi": 10,
        "landlock_browser_min_abi": 6,
    }
    expected.update(graphics)

    lines = [
        "schema_version = 2",
        f"runtime_family = {json.dumps(family)}",
        f"runtime_abi = {json.dumps(runtime_abi)}",
        f"platform_version = {json.dumps(platform_version)}",
        "supported_capabilities = ["
        + ", ".join(json.dumps(capability) for capability in capabilities)
        + "]",
        f"physical_memory_mib = {physical_memory_mib}",
        f"app_memory_budget_mib = {app_memory_budget_mib}",
        "production = true",
        'landlock_mode = "required"',
        "landlock_full_min_abi = 10",
        "landlock_browser_min_abi = 6",
    ]
    for key in ("gles_max", "vulkan_max"):
        if key in graphics:
            lines.append(f"{key} = {json.dumps(graphics[key])}")
    lines.append("inputs = [" + ", ".join(json.dumps(token) for token in inputs) + "]")
    lines.append(f"display = {{ width = {width}, height = {height} }}")
    rendered = "".join(line + "\n" for line in lines)

    try:
        parsed = tomllib.loads(rendered)
    except tomllib.TOMLDecodeError as error:
        fatal(f"generated platform support TOML does not parse: {error}")
    if parsed != expected:
        fatal(f"generated platform support TOML did not round-trip exactly: {parsed!r}")
    # Re-assert the runtime parser shape (parse_platform_contract schema 2): the
    # four required facts present, inputs inside the runtime vocabulary, display
    # exactly {width, height}. The renderer must never write a file the pinned
    # runtime would refuse.
    for key in ("physical_memory_mib", "app_memory_budget_mib", "inputs", "display"):
        if key not in parsed:
            fatal(f"generated platform support TOML lacks required schema-2 fact {key}")
    off_vocabulary = [token for token in parsed["inputs"] if token not in vocabularies["KNOWN_INPUTS"]]
    if not parsed["inputs"] or off_vocabulary:
        fatal(f"generated inputs are empty or runtime-unknown: {off_vocabulary!r}")
    if set(parsed["display"]) != {"width", "height"}:
        fatal(f"generated display is not exactly width/height: {parsed['display']!r}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
