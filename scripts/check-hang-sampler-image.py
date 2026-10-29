#!/usr/bin/env python3
"""Fail-closed static policy check for the production hang sampler integration."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SAMPLER_SOCKET = "/run/pocketforge/hang-sampler/hang-sampler.sock"
AUTHORITY_SAMPLER_SUFFIX = f" --hang-sampler-socket {SAMPLER_SOCKET}"


def read(path: Path, errors: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        errors.append(f"missing or unreadable policy file: {path}: {error}")
        return ""


def unit_value(text: str, key: str) -> list[str]:
    prefix = f"{key}="
    return [line[len(prefix) :] for line in text.splitlines() if line.startswith(prefix)]


def require_exact_line(text: str, line: str, label: str, errors: list[str]) -> None:
    if line not in text.splitlines():
        errors.append(f"{label}: missing exact line: {line}")


def effective_service_user(unit: Path, errors: list[str]) -> str:
    text = read(unit, errors)
    users = unit_value(text, "User")
    if len(users) > 1:
        errors.append(f"runtime unit has multiple User= directives: {unit}")
    return users[-1] if users else "root"


def validate(root: Path, runtime_root: Path | None = None) -> list[str]:
    errors: list[str] = []
    overlay = root / "rootfs-overlay"
    systemd = overlay / "etc/systemd/system"
    sampler_service_path = systemd / "pf-hang-sampler.service"
    sampler_socket_path = systemd / "pf-hang-sampler.socket"
    authority_dropin_path = (
        systemd / "pf-session-authorityd.service.d/20-hang-sampler.conf"
    )
    sysusers_path = overlay / "usr/lib/sysusers.d/pf-hang-sampler.conf"
    tmpfiles_path = overlay / "usr/lib/tmpfiles.d/pf-hang-sampler.conf"

    sysusers = read(sysusers_path, errors)
    for line in (
        "g pf-hang-sampler -",
        'u pf-hang-sampler - "PocketForge hang sampler" /nonexistent /usr/sbin/nologin',
        "g pf-hang-trigger -",
    ):
        require_exact_line(sysusers, line, "sysusers identity", errors)
    trigger_members = sorted(
        line
        for line in sysusers.splitlines()
        if re.fullmatch(r"m\s+\S+\s+pf-hang-trigger", line)
    )
    if trigger_members != ["m root pf-hang-trigger"]:
        errors.append(
            "trigger group membership must be exactly the authority/broker service user "
            f"root, got {trigger_members}"
        )
    for forbidden in ("gamer", "pf-ime", "pf-osk", "pf-fcitx5", "pf-hang-sampler"):
        if f"m {forbidden} pf-hang-trigger" in sysusers.splitlines():
            errors.append(f"forbidden trigger-group member: {forbidden}")

    tmpfiles = read(tmpfiles_path, errors)
    require_exact_line(
        tmpfiles,
        "d /run/pocketforge/hang-sampler 0711 root root -",
        "tmpfiles socket directory",
        errors,
    )

    socket_unit = read(sampler_socket_path, errors)
    for line in (
        f"ListenSequentialPacket={SAMPLER_SOCKET}",
        "SocketUser=root",
        "SocketGroup=pf-hang-trigger",
        "SocketMode=0660",
    ):
        require_exact_line(socket_unit, line, "sampler socket unit", errors)
    if unit_value(socket_unit, "ListenStream"):
        errors.append("sampler socket unit must never use ListenStream=")

    service = read(sampler_service_path, errors)
    required_service_lines = (
        "User=pf-hang-sampler",
        "Group=pf-hang-sampler",
        "ExecStart=/usr/bin/pf-hang-sampler --systemd-socket",
        "CapabilityBoundingSet=CAP_SYS_PTRACE",
        "AmbientCapabilities=CAP_SYS_PTRACE",
        "NoNewPrivileges=yes",
        "LimitCORE=0",
        "PrivateNetwork=yes",
        "RestrictAddressFamilies=AF_UNIX",
        "IPAddressDeny=any",
        "PrivateDevices=yes",
        "PrivateTmp=yes",
        "ProtectSystem=strict",
        "ProtectHome=yes",
        "ProtectKernelTunables=yes",
        "ProtectKernelModules=yes",
        "ProtectControlGroups=yes",
        "LockPersonality=yes",
        "RestrictRealtime=yes",
        "SystemCallArchitectures=native",
        "SystemCallFilter=@system-service ptrace process_vm_readv",
        "SystemCallErrorNumber=EPERM",
    )
    for line in required_service_lines:
        require_exact_line(service, line, "sampler service", errors)
    if re.search(r"(?:^|\s)--socket(?:\s|$)", service, flags=re.MULTILINE):
        errors.append("production sampler service must never use path-bind --socket")
    if unit_value(service, "CapabilityBoundingSet") != ["CAP_SYS_PTRACE"]:
        errors.append("sampler CapabilityBoundingSet must contain only CAP_SYS_PTRACE")
    if unit_value(service, "AmbientCapabilities") != ["CAP_SYS_PTRACE"]:
        errors.append("sampler AmbientCapabilities must contain only CAP_SYS_PTRACE")

    authority_dropin = read(authority_dropin_path, errors)
    require_exact_line(
        authority_dropin,
        "Wants=pf-hang-sampler.socket",
        "authority sampler ordering",
        errors,
    )
    require_exact_line(
        authority_dropin,
        "After=pf-hang-sampler.socket",
        "authority sampler ordering",
        errors,
    )
    require_exact_line(authority_dropin, "ExecStart=", "authority command reset", errors)
    expected_authority_command = (
        "ExecStart=/usr/bin/pf-session-authorityd "
        "--state-dir /var/lib/pocketforge/session-authority "
        "--socket /run/pocketforge/session-authority.sock "
        "--compositor-user pf-gamescope "
        "--compositor-unit pocketforge-gamescope.service "
        f"--hang-sampler-socket {SAMPLER_SOCKET}"
    )
    require_exact_line(
        authority_dropin,
        expected_authority_command,
        "authority sampler socket wiring",
        errors,
    )

    for path in [systemd / "pf-app@.service", *sorted((systemd / "pf-app@.service.d").glob("*"))]:
        text = read(path, errors)
        for value in unit_value(text, "Slice"):
            if value != r"system-pf\x2dapp.slice":
                errors.append(f"pf-app unit must keep default dedicated slice placement: {path}: Slice={value}")

    for path in sorted(systemd.rglob("*")):
        if not path.is_file() or ".service" not in path.as_posix():
            continue
        text = read(path, errors)
        if "CAP_SYS_PTRACE" in text and path != sampler_service_path:
            errors.append(f"CAP_SYS_PTRACE granted outside sampler service: {path}")

    build_rootfs = read(root / "scripts/build-rootfs.sh", errors)
    for artifact in (
        "bin/pf-hang-sampler",
        "usr/lib/sysusers.d/pf-hang-sampler.conf",
        "usr/lib/tmpfiles.d/pf-hang-sampler.conf",
        "etc/systemd/system/pf-hang-sampler.socket",
        "etc/systemd/system/pf-hang-sampler.service",
        "etc/systemd/system/pf-session-authorityd.service.d/20-hang-sampler.conf",
    ):
        if artifact not in build_rootfs:
            errors.append(f"rootfs installer does not install sampler artifact: {artifact}")
    if "sockets.target.wants/pf-hang-sampler.socket" not in build_rootfs:
        errors.append("sampler socket is not enabled at boot through sockets.target")
    if re.search(r"\.wants/pf-hang-sampler\.service", build_rootfs):
        errors.append("sampler service must be socket-activated, not enabled at boot")

    dockerfile = read(root / "build/Dockerfile.pf", errors)
    for build_line in (
        '-p pf-hang-sampler --bin pf-hang-sampler',
        'install -D -m 0755 "${HANG_SAMPLER_BIN}" /out/bin/pf-hang-sampler',
    ):
        if build_line not in dockerfile:
            errors.append(f"runtime stage does not build/install sampler binary: {build_line}")
    sysctl_root = overlay / "etc/sysctl.d"
    for path in sorted(sysctl_root.glob("*.conf")):
        text = read(path, errors)
        if re.search(r"^\s*kernel\.yama\.ptrace_scope\s*=", text, flags=re.MULTILINE):
            errors.append(f"image must not set or lower kernel.yama.ptrace_scope: {path}")

    if runtime_root is not None:
        runtime_authority_path = runtime_root / "systemd/pf-session-authorityd.service"
        runtime_authority = read(runtime_authority_path, errors)
        authority_user = effective_service_user(runtime_authority_path, errors)
        broker_user = effective_service_user(
            runtime_root / "crates/pf-input-broker/systemd/pf-input-broker.service",
            errors,
        )
        allowed_users = sorted({authority_user, broker_user})
        if allowed_users != ["root"]:
            errors.append(
                "pf-hang-trigger membership is pinned to root but paired runtime caller "
                f"users are {allowed_users}"
            )
        runtime_commands = unit_value(runtime_authority, "ExecStart")
        image_commands = unit_value(authority_dropin, "ExecStart")
        if len(runtime_commands) != 1:
            errors.append(
                "paired runtime authority must have exactly one ExecStart, got "
                f"{runtime_commands}"
            )
        elif image_commands != ["", runtime_commands[0] + AUTHORITY_SAMPLER_SUFFIX]:
            errors.append(
                "authority ExecStart drift: image drop-in must equal paired runtime "
                "ExecStart plus exact hang-sampler suffix"
            )
        for path in sorted(runtime_root.rglob("*.service")):
            if "CAP_SYS_PTRACE" in read(path, errors):
                errors.append(f"paired runtime unit grants CAP_SYS_PTRACE: {path}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--runtime-root", type=Path)
    args = parser.parse_args()
    errors = validate(args.root.resolve(), args.runtime_root.resolve() if args.runtime_root else None)
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "PASS: hang sampler image policy has exact identities, socket activation, "
        "capability isolation, app placement, ExecStart pairing, and no Yama override"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
