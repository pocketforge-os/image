#!/usr/bin/env python3
"""Render the proposed runtime-root extension into a pf-app@ drop-in.

This is an offline, source-owned contract prototype.  It deliberately does
not install a second launcher or modify the production manifest parser while
the one-launch-path contract is landing upstream.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import tomllib
from typing import NoReturn


DIGEST_RE = re.compile(r"sha256:([0-9a-f]{64})\Z")
PLATFORM_RE = re.compile(r"[a-z0-9]+(?:[./-][a-z0-9]+)*\Z")

KNOWN_CAPABILITIES = {
    "accelerometer",
    "audio",
    "entropy",
    "egress",
    "gnss",
    "gyroscope",
    "imu",
    "input",
    "leds",
    "location",
    "magnetometer",
    "rumble",
    "settings",
    "vibration",
    "video-decode",
}

ROOT_KEYS = {
    "schema",
    "format",
    "digest",
    "platform-runtime",
    "platform-runtime-abi",
    "platform-runtime-version",
    "library-paths",
}

RESOURCE_PREFIXES = {
    "audio-devices": ("/dev/snd/",),
    "audio-sockets": ("/run/pocketforge/session/",),
    "broker-sockets": ("/run/pocketforge/",),
    "display-sockets": ("/run/pocketforge/session/",),
    "input-devices": ("/dev/input/",),
    "media-devices": ("/dev/media",),
    "render-devices": ("/dev/dri/renderD",),
    "session-environment": ("/run/pocketforge/session/environment",),
    "video-decode-devices": ("/dev/video",),
}

CAPABILITY_OUTCOMES = {
    "accelerometer": "broker socket only; no raw sensor node",
    "audio": "audio socket and minimum ALSA nodes",
    "entropy": "private namespace urandom only",
    "egress": "declaration only; network policy remains host-owned",
    "gnss": "broker socket only; no raw serial node",
    "gyroscope": "broker socket only; no raw sensor node",
    "imu": "broker socket only; no raw sensor node",
    "input": "minimum evdev nodes read-only",
    "leds": "broker socket only; no sysfs bind",
    "location": "broker socket only; no raw serial node",
    "magnetometer": "broker socket only; no raw sensor node",
    "rumble": "minimum evdev nodes read-write",
    "settings": "per-app XDG state only",
    "vibration": "minimum evdev nodes read-write",
    "video-decode": "codec video and media nodes",
}

REFUSAL_EXIT = {
    "runtime_root_missing": 66,
    "platform_runtime_missing": 66,
    "required_resource_missing": 66,
    "sandbox_render_failed": 74,
}


class Refusal(Exception):
    def __init__(self, reason: str, detail: str) -> None:
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


def refuse(reason: str, detail: str) -> NoReturn:
    raise Refusal(reason, detail)


def require_string(value: object, name: str) -> str:
    if not isinstance(value, str) or not value:
        refuse("runtime_root_invalid", f"{name} must be a non-empty string")
    return value


def valid_app_id(value: str) -> bool:
    """Match the current shared parser's reverse-DNS app-id grammar."""
    if not 3 <= len(value) <= 200 or not value.isascii():
        return False
    labels = value.split(".")
    if len(labels) < 2:
        return False
    for label in labels:
        if not label or not (label[0].islower() or label[0].isdigit()):
            return False
        if not (label[-1].islower() or label[-1].isdigit()):
            return False
        if any(
            not (character.islower() or character.isdigit() or character in "_-")
            for character in label
        ):
            return False
    return True


def capability_requirements(value: object) -> dict[str, bool]:
    """Return normalized capability bases mapped to their optional bit."""
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        refuse("descriptor_invalid", "app.use must be a string array")
    result: dict[str, bool] = {}
    for raw in value:
        token = raw.strip()
        optional = token.endswith("?")
        if token.endswith("?"):
            token = token[:-1]
        base, separator, modifier = token.partition(":")
        base = base.strip().lower()
        modifier = modifier.strip()
        if not base or base in result:
            refuse("descriptor_invalid", "app.use has an invalid or duplicate capability")
        if separator:
            valid_modifier = (
                (base == "egress" and bool(modifier))
                or (base in {"location", "gnss"} and modifier in {"approximate", "precise"})
            )
            if not valid_modifier:
                refuse("descriptor_invalid", f"invalid capability modifier: {raw!r}")
        elif base == "egress":
            refuse("descriptor_invalid", "egress requires a non-empty modifier")
        if base not in KNOWN_CAPABILITIES:
            refuse("unsupported_capability", f"unsupported capability: {base}")
        result[base] = optional
    return result


def digest_hex(value: object, name: str, reason: str = "runtime_root_invalid") -> str:
    text = require_string(value, name)
    match = DIGEST_RE.fullmatch(text)
    if not match:
        refuse(reason, f"{name} must be lowercase sha256:<64 hex>")
    return match.group(1)


def library_paths(value: object) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        refuse("runtime_root_invalid_library_path", "library-paths must be a string array")
    result: list[str] = []
    for item in value:
        path = PurePosixPath(item)
        if (
            not item
            or path.is_absolute()
            or ".." in path.parts
            or "." in path.parts
            or str(path) != item
        ):
            refuse(
                "runtime_root_invalid_library_path",
                f"library path is not canonical and relative: {item!r}",
            )
        if item in result:
            refuse("runtime_root_invalid_library_path", f"duplicate library path: {item}")
        result.append(item)
    return result


def load_toml(path: Path) -> dict[str, object]:
    try:
        with path.open("rb") as handle:
            value = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        refuse("descriptor_parse", str(error))
    if not isinstance(value, dict):
        refuse("descriptor_parse", "descriptor is not a TOML table")
    return value


def load_inventory(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        refuse("platform_runtime_invalid", str(error))
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        refuse("platform_runtime_invalid", "inventory schema_version must be 1")
    resources = value.get("resources")
    if not isinstance(resources, dict):
        refuse("platform_runtime_invalid", "inventory resources must be an object")
    unknown = sorted(set(resources) - set(RESOURCE_PREFIXES))
    if unknown:
        refuse("platform_runtime_invalid", f"unknown inventory resources: {', '.join(unknown)}")
    for name, paths in resources.items():
        if not isinstance(paths, list) or not paths or any(not isinstance(item, str) for item in paths):
            refuse("platform_runtime_invalid", f"resource {name} must be a non-empty string array")
        if paths != sorted(set(paths)):
            refuse("platform_runtime_invalid", f"resource {name} must be sorted and unique")
        prefixes = RESOURCE_PREFIXES[name]
        for item in paths:
            if not item.startswith(prefixes) or ".." in PurePosixPath(item).parts:
                refuse("platform_runtime_invalid", f"resource {name} has forbidden path: {item}")
    return value


def resource_paths(
    resources: dict[str, object], name: str, *, optional: bool = False
) -> list[str]:
    value = resources.get(name)
    if not isinstance(value, list) or not value:
        if optional:
            return []
        refuse("required_resource_missing", f"required resource set is absent or empty: {name}")
    return [str(item) for item in value]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        refuse("runtime_root_missing", str(error))
    return digest.hexdigest()


def require_artifacts(
    *,
    app_id: str,
    app_digest: str,
    platform: str,
    platform_digest: str,
    app_root_store: Path,
    platform_runtime_store: Path,
) -> None:
    root_image = app_root_store / app_id / f"sha256-{app_digest}.raw"
    if not root_image.is_file() or root_image.is_symlink():
        refuse("runtime_root_missing", f"runtime root is absent or not a regular file: {root_image}")
    if sha256_file(root_image) != app_digest:
        refuse("runtime_root_digest_mismatch", f"runtime root digest differs: {root_image}")

    platform_dir = platform.replace("/", "-")
    platform_root = platform_runtime_store / platform_dir / f"sha256-{platform_digest}"
    if not platform_root.is_dir() or platform_root.is_symlink():
        refuse(
            "platform_runtime_missing",
            f"platform runtime is absent or not a directory: {platform_root}",
        )
    identity = platform_root / ".manifest-sha256"
    try:
        recorded = identity.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as error:
        refuse("platform_runtime_missing", str(error))
    if recorded != platform_digest:
        refuse(
            "platform_runtime_digest_mismatch",
            f"platform runtime identity differs: {platform_root}",
        )


def render(
    descriptor: dict[str, object],
    inventory: dict[str, object],
    app_root_store: Path,
    platform_runtime_store: Path,
) -> str | None:
    app = descriptor.get("app")
    runtime = descriptor.get("runtime")
    launch = descriptor.get("launch")
    if not isinstance(app, dict) or not isinstance(runtime, dict) or not isinstance(launch, dict):
        refuse("descriptor_invalid", "app, runtime, and launch tables are required")

    root = runtime.get("root")
    if root is None:
        return None
    if not isinstance(root, dict):
        refuse("runtime_root_invalid", "runtime.root must be a table")
    unknown = sorted(set(root) - ROOT_KEYS)
    if unknown:
        refuse("runtime_root_invalid", f"unknown runtime.root fields: {', '.join(unknown)}")
    if root.get("schema") != 1:
        refuse("runtime_root_invalid", "runtime.root schema must be 1")
    if root.get("format") != "squashfs":
        refuse("runtime_root_invalid", "only squashfs runtime roots are accepted")

    app_id = require_string(app.get("id"), "app.id")
    if not valid_app_id(app_id):
        refuse("runtime_root_invalid", "app.id is not canonical")
    app_digest = digest_hex(root.get("digest"), "runtime.root.digest")
    platform = require_string(root.get("platform-runtime"), "runtime.root.platform-runtime")
    if not PLATFORM_RE.fullmatch(platform):
        refuse("runtime_root_invalid", "platform-runtime is not canonical")
    platform_abi = require_string(
        root.get("platform-runtime-abi"), "runtime.root.platform-runtime-abi"
    )
    platform_version = require_string(
        root.get("platform-runtime-version"), "runtime.root.platform-runtime-version"
    )
    platform_hex = digest_hex(
        platform_version,
        "runtime.root.platform-runtime-version",
        "runtime_root_invalid",
    )
    lib_paths = library_paths(root.get("library-paths"))

    if inventory.get("platform_runtime") != platform:
        refuse("platform_runtime_incompatible", "platform runtime id differs")
    if inventory.get("platform_runtime_abi") != platform_abi:
        refuse("platform_runtime_incompatible", "platform runtime ABI differs")
    if inventory.get("platform_runtime_version") != platform_version:
        refuse("platform_runtime_incompatible", "platform runtime version differs")
    require_artifacts(
        app_id=app_id,
        app_digest=app_digest,
        platform=platform,
        platform_digest=platform_hex,
        app_root_store=app_root_store,
        platform_runtime_store=platform_runtime_store,
    )

    requirements = capability_requirements(app.get("use", []))
    capabilities = set(requirements)

    resources = inventory["resources"]
    assert isinstance(resources, dict)
    ro_paths: set[str] = set()
    rw_paths: set[str] = set()
    devices: dict[str, str] = {}

    def add_devices(resource: str, mode: str, *, optional: bool = False) -> None:
        for path in resource_paths(resources, resource, optional=optional):
            if devices.get(path) == "rw" or mode == "rw":
                devices[path] = "rw"
                ro_paths.discard(path)
                rw_paths.add(path)
            else:
                devices[path] = "r"
                ro_paths.add(path)

    def add_sockets(resource: str, *, optional: bool = False) -> None:
        rw_paths.update(resource_paths(resources, resource, optional=optional))

    takes_display = launch.get("takes_display", False)
    if not isinstance(takes_display, bool):
        refuse("descriptor_invalid", "launch.takes_display must be boolean")
    if takes_display:
        add_sockets("display-sockets")
        ro_paths.update(resource_paths(resources, "session-environment"))
        add_devices("render-devices", "rw")

    wants_audio = launch.get("audio", False)
    if not isinstance(wants_audio, bool):
        refuse("descriptor_invalid", "launch.audio must be boolean")
    if wants_audio or "audio" in capabilities:
        optional = not wants_audio and requirements.get("audio", False)
        add_sockets("audio-sockets", optional=optional)
        ro_paths.update(resource_paths(resources, "session-environment", optional=optional))
        add_devices("audio-devices", "rw", optional=optional)

    if "input" in capabilities:
        add_devices("input-devices", "r", optional=requirements["input"])
    if "rumble" in capabilities or "vibration" in capabilities:
        names = set(requirements) & {"rumble", "vibration"}
        add_devices(
            "input-devices", "rw", optional=all(requirements[name] for name in names)
        )
    if "video-decode" in capabilities:
        optional = requirements["video-decode"]
        add_devices("video-decode-devices", "rw", optional=optional)
        add_devices("media-devices", "rw", optional=optional)
    brokered = {
        "accelerometer",
        "gnss",
        "gyroscope",
        "imu",
        "leds",
        "location",
        "magnetometer",
    }
    if set(capabilities) & brokered:
        names = set(requirements) & brokered
        add_sockets(
            "broker-sockets", optional=all(requirements[name] for name in names)
        )

    platform_dir = platform.replace("/", "-")
    platform_root = (
        f"/usr/lib/pocketforge/platform-runtimes/{platform_dir}/sha256-{platform_hex}"
    )
    app_root = f"/opt/pocketforge/apps/{app_id}"
    ld_paths = [f"{app_root}/{item}" for item in lib_paths]
    ld_paths.extend(
        [
            "/run/pocketforge/platform-runtime/usr/local/lib",
            "/run/pocketforge/platform-runtime/usr/lib/aarch64-linux-gnu",
            "/usr/lib/aarch64-linux-gnu",
            "/lib/aarch64-linux-gnu",
        ]
    )

    lines = [
        "# Generated by render-app-runtime-root.py; DO NOT EDIT.",
        "[Service]",
        f"RootImage=/var/lib/pocketforge/app-roots/{app_id}/sha256-{app_digest}.raw",
        "RootImageOptions=ro",
        "ProtectSystem=strict",
        "ProtectHome=yes",
        "PrivateUsers=yes",
        "PrivateDevices=yes",
        "DevicePolicy=closed",
        "SupplementaryGroups=",
        "NoNewPrivileges=yes",
        "PrivateTmp=yes",
        f"ReadWritePaths=/var/lib/pocketforge/apps/{app_id}",
        f"BindReadOnlyPaths={platform_root}:/run/pocketforge/platform-runtime",
        "BindReadOnlyPaths=/usr/bin/pf-app-launch",
        "BindReadOnlyPaths=/usr/share/pocketforge/platform-capabilities.toml",
        f"BindReadOnlyPaths={app_root}/app.toml",
        f'Environment="LD_LIBRARY_PATH={":".join(ld_paths)}"',
    ]
    needs_network = launch.get("needs_network", False)
    if not isinstance(needs_network, bool):
        refuse("descriptor_invalid", "launch.needs_network must be boolean")
    if needs_network:
        lines.append("# declaration needs_network: host network namespace retained")
    else:
        lines.append("PrivateNetwork=yes")
    for capability in sorted(capabilities):
        lines.append(f"# capability {capability}: {CAPABILITY_OUTCOMES[capability]}")
    if takes_display:
        lines.append("# declaration takes_display: display sockets and render node")
    if wants_audio:
        lines.append("# declaration audio: audio socket and minimum ALSA nodes")
    for path in sorted(ro_paths):
        lines.append(f"BindReadOnlyPaths={path}")
    for path in sorted(rw_paths):
        lines.append(f"BindPaths={path}")
    for path in sorted(devices):
        lines.append(f"DeviceAllow={path} {devices[path]}")
    return "\n".join(lines) + "\n"


def write_atomic(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, 0o644)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def remove_output(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--app-root-store",
        type=Path,
        default=Path("/var/lib/pocketforge/app-roots"),
    )
    parser.add_argument(
        "--platform-runtime-store",
        type=Path,
        default=Path("/usr/lib/pocketforge/platform-runtimes"),
    )
    args = parser.parse_args()

    try:
        descriptor = load_toml(args.manifest)
        runtime = descriptor.get("runtime")
        if isinstance(runtime, dict) and runtime.get("root") is None:
            try:
                remove_output(args.output)
            except OSError as error:
                refuse("sandbox_render_failed", str(error))
            print("runtime_root=absent action=unchanged")
            return 0
        inventory = load_inventory(args.inventory)
        value = render(
            descriptor,
            inventory,
            args.app_root_store,
            args.platform_runtime_store,
        )
        assert value is not None
        try:
            write_atomic(args.output, value)
        except OSError as error:
            refuse("sandbox_render_failed", str(error))
        print(f"runtime_root=present output={args.output}")
        return 0
    except Refusal as error:
        try:
            remove_output(args.output)
        except OSError as cleanup_error:
            error = Refusal("sandbox_render_failed", str(cleanup_error))
        print(f"refused reason={error.reason} detail={error.detail}", file=sys.stderr)
        return REFUSAL_EXIT.get(error.reason, 65)


if __name__ == "__main__":
    raise SystemExit(main())
