#!/usr/bin/env python3
"""Render the proposed runtime-root extension as a pf-app@ service fragment.

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
import subprocess
import sys
import tempfile
import tomllib
from typing import NoReturn


DIGEST_RE = re.compile(r"sha256:([0-9a-f]{64})\Z")
PLATFORM_RE = re.compile(r"[a-z0-9]+(?:[./-][a-z0-9]+)*\Z")

ROOT_KEYS = {
    "schema",
    "format",
    "distribution",
    "digest",
    "platform-runtime",
    "platform-runtime-abi",
    "platform-runtime-version",
    "library-paths",
}

PLATFORM_BASE_ABI_SONAMES = {
    "ld-linux-aarch64.so.1",
    "libc.so.6",
    "libdl.so.2",
    "libgcc_s.so.1",
    "libm.so.6",
    "libpthread.so.0",
    "librt.so.1",
    "libstdc++.so.6",
}

PLATFORM_REQUIRED_SONAMES = {
    "dri_gbm.so": "usr/local/lib/gbm/dri_gbm.so",
    "libEGL.so.1": "usr/lib/aarch64-linux-gnu/libEGL.so.1",
    "libEGL_mesa.so.0": "usr/local/lib/libEGL_mesa.so.0",
    "libGLESv2.so.2": "usr/lib/aarch64-linux-gnu/libGLESv2.so.2",
    "libdril_dri.so": "usr/local/lib/dri/libdril_dri.so",
    "libdrm.so.2": "usr/lib/aarch64-linux-gnu/libdrm.so.2",
    "libgbm.so.1": "usr/local/lib/libgbm.so.1",
    "libvulkan.so.1": "usr/lib/aarch64-linux-gnu/libvulkan.so.1",
    "libvulkan_powervr_mesa.so": "usr/local/lib/libvulkan_powervr_mesa.so",
    "libwayland-client.so.0": "usr/lib/aarch64-linux-gnu/libwayland-client.so.0",
    "libwayland-egl.so.1": "usr/lib/aarch64-linux-gnu/libwayland-egl.so.1",
    "libxkbcommon.so.0": "usr/lib/aarch64-linux-gnu/libxkbcommon.so.0",
}

PLATFORM_DISCOVERY_PATHS = {
    "usr/share/glvnd/egl_vendor.d/50_mesa.json": (
        "/run/pocketforge/platform-runtime/usr/local/lib/libEGL_mesa.so.0"
    ),
    "usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json": (
        "/run/pocketforge/platform-runtime/usr/local/lib/"
        "libvulkan_powervr_mesa.so"
    ),
}

PLATFORM_REQUIRED_DATA = {
    "usr/local/lib/dri/zink_dri.so",
    "usr/local/share/drirc.d/10-pocketforge-zink.conf",
    *PLATFORM_DISCOVERY_PATHS,
}

RESOURCE_PREFIXES = {
    "audio-devices": ("/dev/snd/",),
    "audio-sockets": ("/run/pocketforge/session/",),
    "broker-sockets": ("/run/pocketforge/",),
    "display-devices": ("/dev/fb",),
    "display-sockets": ("/run/pocketforge/session/",),
    "input-devices": ("/dev/input/",),
    "media-devices": ("/dev/media",),
    "render-devices": ("/dev/dri/renderD",),
    "session-environment": ("/run/pocketforge/session/environment",),
    "video-decode-devices": ("/dev/video",),
    "x11-environment": ("/run/pocketforge/session/capabilities/x11/environment",),
    "x11-socket": ("/run/pocketforge/session/capabilities/x11/X0",),
}

REFUSAL_EXIT = {
    "runtime_root_missing": 66,
    "runtime_root_metadata_missing": 66,
    "platform_runtime_missing": 66,
    "required_resource_missing": 66,
    "policy_render_failed": 65,
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


def sha256_file(path: Path, missing_reason: str = "runtime_root_missing") -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        refuse(missing_reason, str(error))
    return digest.hexdigest()


def platform_manifest_digest(platform_root: Path) -> str:
    """Recompute the builder's canonical manifest over the installed tree."""
    lines: list[str] = []
    try:
        entries = sorted(
            platform_root.rglob("*"),
            key=lambda path: path.relative_to(platform_root).as_posix(),
        )
    except OSError as error:
        refuse("platform_runtime_missing", str(error))
    for path in entries:
        relative = path.relative_to(platform_root).as_posix()
        if relative == ".manifest-sha256":
            continue
        if path.is_symlink():
            refuse(
                "platform_runtime_digest_mismatch",
                f"platform runtime contains a symlink: {relative}",
            )
        if path.is_dir():
            continue
        if not path.is_file():
            refuse(
                "platform_runtime_digest_mismatch",
                f"platform runtime contains a non-regular object: {relative}",
            )
        lines.append(
            f"{sha256_file(path, 'platform_runtime_missing')}  {relative}\n"
        )
    return hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()


def require_platform_abi(platform_root: Path) -> None:
    abi_path = platform_root / "abi.json"
    if not abi_path.is_file() or abi_path.is_symlink():
        refuse(
            "platform_runtime_incompatible",
            f"Debian 13 platform ABI manifest is absent or not regular: {abi_path}",
        )
    try:
        value = json.loads(abi_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        refuse("platform_runtime_incompatible", f"invalid platform ABI manifest: {error}")
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        refuse("platform_runtime_incompatible", "platform ABI schema_version must be 1")
    if value.get("host_distribution") != "debian-12":
        refuse(
            "platform_runtime_incompatible",
            "platform ABI host_distribution must be debian-12",
        )

    base = value.get("base_abi_sonames")
    if (
        not isinstance(base, list)
        or any(not isinstance(item, str) for item in base)
        or set(base) != PLATFORM_BASE_ABI_SONAMES
        or len(base) != len(PLATFORM_BASE_ABI_SONAMES)
    ):
        refuse(
            "platform_runtime_incompatible",
            "platform ABI base SONAME ownership differs",
        )

    sonames = value.get("sonames")
    if not isinstance(sonames, dict) or any(
        not isinstance(soname, str) or not isinstance(relative, str)
        for soname, relative in sonames.items()
    ):
        refuse("platform_runtime_incompatible", "platform ABI sonames map is invalid")
    if PLATFORM_BASE_ABI_SONAMES.intersection(sonames):
        refuse(
            "platform_runtime_incompatible",
            "platform ABI slice claims an app-root base SONAME",
        )
    for soname, relative in sonames.items():
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts or str(path) != relative:
            refuse(
                "platform_runtime_incompatible",
                f"platform ABI has a non-canonical SONAME path: {soname}",
            )
        provider = platform_root / relative
        if not provider.is_file() or provider.is_symlink():
            refuse(
                "platform_runtime_incompatible",
                f"platform ABI SONAME provider is absent or not regular: {relative}",
            )
    for soname, expected in PLATFORM_REQUIRED_SONAMES.items():
        if sonames.get(soname) != expected:
            refuse(
                "platform_runtime_incompatible",
                f"platform ABI SONAME ownership differs: {soname}",
            )

    discovery = value.get("json_library_paths")
    if not isinstance(discovery, dict) or any(
        not isinstance(relative, str) or not isinstance(runtime_path, str)
        for relative, runtime_path in discovery.items()
    ):
        refuse(
            "platform_runtime_incompatible",
            "platform ABI discovery-path map is invalid",
        )
    for relative, expected in PLATFORM_DISCOVERY_PATHS.items():
        if discovery.get(relative) != expected:
            refuse(
                "platform_runtime_incompatible",
                f"platform ABI discovery ownership differs: {relative}",
            )
        discovery_file = platform_root / relative
        if not discovery_file.is_file() or discovery_file.is_symlink():
            refuse(
                "platform_runtime_incompatible",
                f"platform ABI discovery file is absent or not regular: {relative}",
            )

    data = value.get("data")
    if not isinstance(data, dict) or any(
        not isinstance(relative, str)
        or not isinstance(digest, str)
        or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        for relative, digest in data.items()
    ):
        refuse("platform_runtime_incompatible", "platform ABI data map is invalid")
    for relative in PLATFORM_REQUIRED_DATA:
        data_file = platform_root / relative
        if (
            not data_file.is_file()
            or data_file.is_symlink()
            or data.get(relative)
            != sha256_file(data_file, "platform_runtime_missing")
        ):
            refuse(
                "platform_runtime_incompatible",
                f"platform ABI data ownership differs: {relative}",
            )


def require_artifacts(
    *,
    app_id: str,
    app_digest: str,
    platform: str,
    platform_digest: str,
    app_root_store: Path,
    platform_runtime_store: Path,
    distribution: str,
) -> None:
    root_image = app_root_store / app_id / f"sha256-{app_digest}.raw"
    if not root_image.is_file() or root_image.is_symlink():
        refuse("runtime_root_missing", f"runtime root is absent or not a regular file: {root_image}")
    if sha256_file(root_image) != app_digest:
        refuse("runtime_root_digest_mismatch", f"runtime root digest differs: {root_image}")

    metadata_path = root_image.with_suffix(".metadata.json")
    if metadata_path.exists():
        if not metadata_path.is_file() or metadata_path.is_symlink():
            refuse(
                "runtime_root_metadata_missing",
                f"runtime root metadata is not a regular file: {metadata_path}",
            )
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            refuse("runtime_root_invalid", f"invalid runtime root metadata: {error}")
        if not isinstance(metadata, dict) or metadata.get("schema_version") != 1:
            refuse("runtime_root_invalid", "runtime root metadata schema_version must be 1")
        if metadata.get("sha256") != app_digest:
            refuse("runtime_root_digest_mismatch", "runtime root metadata digest differs")
        if metadata.get("distribution") != distribution:
            refuse(
                "runtime_root_distribution_mismatch",
                "runtime root metadata distribution differs",
            )
        expected_suite = {"debian-12": "bookworm", "debian-13": "trixie"}[
            distribution
        ]
        if metadata.get("suite") != expected_suite or metadata.get("architecture") != "arm64":
            refuse(
                "runtime_root_distribution_mismatch",
                "runtime root suite/architecture differs",
            )
    elif distribution != "debian-12":
        refuse(
            "runtime_root_metadata_missing",
            f"runtime root metadata is absent: {metadata_path}",
        )

    platform_dir = platform.replace("/", "-")
    platform_root = platform_runtime_store / platform_dir / f"sha256-{platform_digest}"
    if not platform_root.is_dir() or platform_root.is_symlink():
        refuse(
            "platform_runtime_missing",
            f"platform runtime is absent or not a directory: {platform_root}",
        )
    identity = platform_root / ".manifest-sha256"
    if not identity.is_file() or identity.is_symlink():
        refuse(
            "platform_runtime_missing",
            f"platform runtime identity is absent or not a regular file: {identity}",
        )
    try:
        recorded = identity.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as error:
        refuse("platform_runtime_missing", str(error))
    if recorded != platform_digest:
        refuse(
            "platform_runtime_digest_mismatch",
            f"platform runtime identity differs: {platform_root}",
        )
    if distribution == "debian-13":
        require_platform_abi(platform_root)
    if platform_manifest_digest(platform_root) != platform_digest:
        refuse(
            "platform_runtime_digest_mismatch",
            f"platform runtime content differs: {platform_root}",
        )


def compile_policy(
    *,
    renderer: Path,
    manifest: Path,
    platform_contract: Path,
    inventory: dict[str, object],
    app_id: str,
) -> tuple[dict[str, object], list[str]]:
    with tempfile.TemporaryDirectory(prefix="pf-app-policy-") as temp:
        policy_inventory = Path(temp) / "resources.json"
        policy_inventory.write_text(
            json.dumps(
                {
                    "platform_runtime": "/run/pocketforge/platform-runtime",
                    "resources": inventory["resources"],
                },
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n",
            encoding="utf-8",
        )
        base = [
            str(renderer),
            "--manifest",
            str(manifest),
            "--platform-contract",
            str(platform_contract),
            "--resource-inventory",
            str(policy_inventory),
            "--app-dir",
            f"/opt/pocketforge/apps/{app_id}",
            "--platform-runtime",
            "/run/pocketforge/platform-runtime",
            "--xdg-config",
            f"/var/lib/pocketforge/apps/{app_id}/config",
            "--xdg-state",
            f"/var/lib/pocketforge/apps/{app_id}/state",
            "--xdg-cache",
            f"/var/cache/pocketforge/apps/{app_id}",
        ]

        def run(output_format: str) -> str:
            try:
                result = subprocess.run(
                    [*base, "--format", output_format],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
            except OSError as error:
                refuse("policy_render_failed", str(error))
            if result.returncode != 0:
                detail = result.stderr.strip() or f"renderer exited {result.returncode}"
                reason = (
                    "required_resource_missing"
                    if "required resource " in detail and " is missing" in detail
                    else "descriptor_invalid"
                    if "invalid or duplicate capability" in detail
                    else "policy_render_failed"
                )
                refuse(reason, detail)
            return result.stdout

        try:
            decision = json.loads(run("json"))
        except json.JSONDecodeError as error:
            refuse("policy_render_failed", f"policy JSON is invalid: {error}")
        if not isinstance(decision, dict) or decision.get("app_id") != app_id:
            refuse("policy_render_failed", "policy JSON app identity differs")
        fragment = run("systemd-dropin").splitlines()
        if not fragment or fragment[0] != "[Service]":
            refuse("policy_render_failed", "policy service fragment lacks [Service]")
        return decision, fragment[1:]


def render(
    descriptor: dict[str, object],
    inventory: dict[str, object],
    app_root_store: Path,
    platform_runtime_store: Path,
    *,
    manifest_path: Path,
    platform_contract: Path,
    policy_renderer: Path,
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
    distribution = root.get("distribution", "debian-12")
    if distribution not in {"debian-12", "debian-13"}:
        refuse(
            "runtime_root_invalid",
            "runtime.root distribution must be debian-12 or debian-13",
        )

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
        distribution=distribution,
    )

    policy, policy_lines = compile_policy(
        renderer=policy_renderer,
        manifest=manifest_path,
        platform_contract=platform_contract,
        inventory=inventory,
        app_id=app_id,
    )

    platform_dir = platform.replace("/", "-")
    platform_root = (
        f"/usr/lib/pocketforge/platform-runtimes/{platform_dir}/sha256-{platform_hex}"
    )
    app_root = f"/opt/pocketforge/apps/{app_id}"
    app_ld_paths = [f"{app_root}/{item}" for item in lib_paths]
    platform_ld_paths = [
        "/run/pocketforge/platform-runtime/usr/local/lib",
        "/run/pocketforge/platform-runtime/usr/lib/aarch64-linux-gnu",
    ]
    root_ld_paths = ["/usr/lib/aarch64-linux-gnu", "/lib/aarch64-linux-gnu"]
    if distribution == "debian-13":
        ld_paths = platform_ld_paths + app_ld_paths + root_ld_paths
    else:
        ld_paths = app_ld_paths + platform_ld_paths + root_ld_paths

    lines = [
        "# Generated by render-app-runtime-root.py; DO NOT EDIT.",
        f"# runtime root distribution: {distribution} "
        f"({'trixie' if distribution == 'debian-13' else 'bookworm'})",
        "[Service]",
        f"RootImage=/var/lib/pocketforge/app-roots/{app_id}/sha256-{app_digest}.raw",
        "RootImageOptions=ro",
        "ProtectSystem=strict",
        "ProtectHome=yes",
        "PrivateUsers=yes",
        "PrivateDevices=yes",
        "DevicePolicy=closed",
        # Reset image/template groups, retaining only access to the canonical
        # compositor session. The policy fragment below adds capability-derived
        # audio/input/video groups; X11 is a separate manifest-gated projection.
        "SupplementaryGroups=pf-session",
        "NoNewPrivileges=yes",
        "PrivateTmp=yes",
        "InaccessiblePaths=/run/pocketforge/prefsd.sock",
        f"ReadWritePaths=/var/lib/pocketforge/apps/{app_id}",
        f"BindReadOnlyPaths={platform_root}:/run/pocketforge/platform-runtime",
        "BindReadOnlyPaths=/usr/bin/pf-app-launch",
        "BindReadOnlyPaths=/usr/share/pocketforge/platform-capabilities.toml",
        f"BindReadOnlyPaths=/usr/share/pocketforge/app-policy/{app_id}.resources.json",
        f"BindReadOnlyPaths={app_root}/app.toml",
        f'Environment="LD_LIBRARY_PATH={":".join(ld_paths)}"',
    ]
    if distribution == "debian-13":
        lines.extend(
            [
                'Environment="VK_DRIVER_FILES=/run/pocketforge/platform-runtime/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"',
                'Environment="__EGL_VENDOR_LIBRARY_FILENAMES=/run/pocketforge/platform-runtime/usr/share/glvnd/egl_vendor.d/50_mesa.json"',
                'Environment="LIBGL_DRIVERS_PATH=/run/pocketforge/platform-runtime/usr/local/lib/dri"',
                'Environment="GBM_BACKENDS_PATH=/run/pocketforge/platform-runtime/usr/local/lib/gbm"',
            ]
        )
    lines.append(f"# policy schema={policy.get('schema_version')} manifest_sha256={policy.get('manifest_sha256')}")
    lines.extend(policy_lines)
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
    parser.add_argument("--platform-contract", required=True, type=Path)
    parser.add_argument("--policy-renderer", required=True, type=Path)
    parser.add_argument("--policy-output", required=True, type=Path)
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
                remove_output(args.policy_output)
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
            manifest_path=args.manifest,
            platform_contract=args.platform_contract,
            policy_renderer=args.policy_renderer,
        )
        assert value is not None
        try:
            resources = json.dumps(
                {
                    "platform_runtime": "/run/pocketforge/platform-runtime",
                    "resources": inventory["resources"],
                },
                sort_keys=True,
                separators=(",", ":"),
            ) + "\n"
            write_atomic(args.policy_output, resources)
            write_atomic(args.output, value)
        except OSError as error:
            try:
                remove_output(args.policy_output)
                if not args.output.is_dir():
                    remove_output(args.output)
            except OSError as cleanup_error:
                error = cleanup_error
            refuse("sandbox_render_failed", str(error))
        print(
            f"runtime_root=present output={args.output} policy={args.policy_output}"
        )
        return 0
    except Refusal as error:
        try:
            remove_output(args.output)
            remove_output(args.policy_output)
        except OSError as cleanup_error:
            error = Refusal("sandbox_render_failed", str(cleanup_error))
        print(f"refused reason={error.reason} detail={error.detail}", file=sys.stderr)
        return REFUSAL_EXIT.get(error.reason, 65)


if __name__ == "__main__":
    raise SystemExit(main())
