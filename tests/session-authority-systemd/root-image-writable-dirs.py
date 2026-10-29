#!/usr/bin/env python3
"""Real read-only SquashFS namespace acceptance on an admitted ephemeral CI VM."""
from __future__ import annotations

import argparse
import grp
import os
from pathlib import Path
import pwd
import re
import shutil
import signal
import time
import socket
import subprocess
import tempfile
import uuid


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=check, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def executable(root: Path, name: str) -> None:
    source = Path(name)
    target = root / source.relative_to("/")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source.resolve(), target)
    target.chmod(0o755)
    for dependency in re.findall(r"/[^\s()]+", run("ldd", name).stdout):
        source = Path(dependency)
        target = root / source.relative_to("/")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source.resolve(), target)


def cleanup(unit: str, unit_path: Path, writable: list[Path], scope: Path,
            sockets: list[socket.socket], images: list[Path]) -> None:
    run("systemctl", "stop", unit, check=False)
    run("systemctl", "reset-failed", unit, check=False)
    unit_path.unlink(missing_ok=True)
    run("systemctl", "daemon-reload")
    for sock in sockets:
        sock.close()
    # systemd owns loops; allow its last namespace to exit before inspection.
    # Never erase backing bytes while an image is still attached.
    for image in images:
        attached = ""
        for _ in range(100):
            attached = run("losetup", "--associated", str(image), "--noheadings", "--output", "NAME").stdout.strip()
            if not attached:
                break
            time.sleep(0.05)
        if attached:
            raise RuntimeError(f"root-image cleanup: attached loop remains for {image}: {attached}")
    for directory in writable:
        shutil.rmtree(directory, ignore_errors=True)
    shutil.rmtree(scope)
    assert not unit_path.exists() and not scope.exists() and not any(path.exists() for path in writable), "root-image cleanup incomplete"
    print(f"evidence: rootimage cleanup=pass unit={unit} loops=none", flush=True)


def terminate(signum: int, _frame: object) -> None:
    raise SystemExit(128 + signum)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True, type=Path)
    args = parser.parse_args()
    # Defense in depth: the caller runs the unchanged interactive host guard
    # before sudo. No resource is created before these independent slot checks.
    if os.geteuid() != 0 or os.environ.get("GITHUB_ACTIONS") != "true" or not Path("/etc/pocketforge/ephemeral-runner.conf").is_file():
        raise SystemExit("root-image writable-dirs: REFUSE unapproved ephemeral host")
    if Path("/proc/1/comm").read_text().strip() != "systemd":
        raise SystemExit("root-image writable-dirs: REFUSE real systemd PID1 required")
    guard = Path(__file__).resolve().parents[1] / "test-session-authority-systemd.sh"
    run("bash", str(guard), "--check-host-guard", "/")
    account = pwd.getpwnam("nobody")
    group = grp.getgrgid(account.pw_gid).gr_name
    app_id = "org.pocketforge.rootimage-" + uuid.uuid4().hex
    unit = f"pf-app@{app_id}.service"
    unit_path = Path("/run/systemd/system") / unit
    writable = [Path(base) / app_id for base in ("/var/lib/pocketforge/apps", "/var/cache/pocketforge/apps", "/run/pf-app")]
    assert not unit_path.exists() and not any(path.exists() for path in writable), "run namespace already exists"
    scope = Path(tempfile.mkdtemp(prefix="pf-rootimage-", dir="/var/tmp"))
    scope.chmod(0o755)
    sockets: list[socket.socket] = []
    images: list[Path] = []
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        root = scope / "root"
        root.mkdir()
        for name in ("/bin/sh", "/bin/sleep"):
            executable(root, name)
        for path in [*writable, Path(f"/opt/pocketforge/apps/{app_id}"), Path("/run/pocketforge/session"), Path("/tmp/.X11-unix"), Path("/dev"), Path("/proc"), Path("/sys"), Path("/etc")]:
            (root / path.relative_to("/")).mkdir(parents=True, exist_ok=True)
        for path in ("run/pocketforge/session/environment", "run/pocketforge/session/wayland-0", "tmp/.X11-unix/X0"):
            (root / path).touch()
        (root / "payload.sh").write_text('''#!/bin/sh
set -eu
state=/var/lib/pocketforge/apps/$PF_APP_ID
cache=/var/cache/pocketforge/apps/$PF_APP_ID
runtime=/run/pf-app/$PF_APP_ID
printf 'payload\\n' >> "$state/payload"
printf 'payload\\n' >> "$cache/payload"
printf 'payload\\n' >> "$runtime/payload"
if (printf forbidden > /outside-permitted-mounts) 2>/dev/null; then exit 91; fi
printf 'readonly\\n' > "$runtime/readonly"
exec /bin/sleep infinity
''')
        # Four real immutable filesystems: baseline and each independent omission.
        for missing in [None, *writable]:
            if missing:
                (root / missing.relative_to("/")).rmdir()
            image = scope / ("complete.raw" if missing is None else f"missing-{len(images)}.raw")
            run("mksquashfs", str(root), str(image), "-noappend", "-no-progress", "-processors", "1", "-all-root")
            images.append(image)
            if missing:
                (root / missing.relative_to("/")).mkdir()
        session = scope / "session"
        session.mkdir()
        environment = session / "environment"
        environment.write_text("PF_ROOTIMAGE_FIXTURE=1\n")
        for name in ("wayland-0", "X0"):
            sock = socket.socket(socket.AF_UNIX)
            sock.bind(str(session / name))
            sockets.append(sock)
        template = args.template.read_text()
        service = template.split("[Service]\n", 1)[1]
        # Preserve production directory/lifetime/protection directives and %i
        # expansion. Only dependency graph, identity and fixture payload differ.
        body = "[Unit]\nDescription=Ephemeral RootImage directory acceptance\n[Service]\n" + service
        body += f'''
User={account.pw_name}
Group={group}
SupplementaryGroups=
Nice=0
RootImageOptions=ro
EnvironmentFile=
EnvironmentFile={environment}
Environment=PF_APP_ID=%i
ExecStartPre=
ExecStartPre=/bin/sh -ec 'printf prestart > /run/pf-app/%i/prestart'
ExecStart=
ExecStart=/bin/sh /payload.sh
BindReadOnlyPaths={environment}:/run/pocketforge/session/environment
BindPaths={session}/wayland-0:/run/pocketforge/session/wayland-0
BindPaths={session}/X0:/tmp/.X11-unix/X0
'''

        def stop() -> None:
            run("systemctl", "stop", unit, check=False)
            run("systemctl", "reset-failed", unit, check=False)

        def start(image: Path, expected: bool, label: str) -> None:
            stop()
            unit_path.write_text(body + f"RootImage={image}\n")
            run("systemctl", "daemon-reload")
            result = run("systemctl", "start", unit, check=False)
            if not expected:
                status = run("systemctl", "show", unit, "-p", "ExecStartPre").stdout
                assert result.returncode and "status=226" in status, (label, result.stderr, status)
                assert not (writable[2] / "prestart").exists(), label
                print(f"evidence: rootimage case={label} result=226 prestart=absent", flush=True)
                return
            if result.returncode:
                properties = run("systemctl", "show", unit, "-p", "Result", "-p", "ExecStartPre", check=False).stdout
                journal = run("journalctl", "--no-pager", "--output=cat", "--lines=12", "--unit", unit, check=False).stdout
                raise AssertionError((label, result.stderr, properties, journal))
            for _ in range(100):
                if (writable[2] / "readonly").exists():
                    break
                if run("systemctl", "is-failed", unit, check=False).returncode == 0:
                    break
                time.sleep(0.05)
            assert (writable[2] / "prestart").read_text() == "prestart", label
            assert (writable[2] / "readonly").read_text() == "readonly\n", label
            for directory in writable:
                assert (directory / "payload").is_file(), (label, directory)
            print(f"evidence: rootimage case={label} result=pass prestart=present payload=present outside=readonly", flush=True)

        for index, path in enumerate(writable, 1):
            start(images[index], False, "missing-" + ("state", "cache", "runtime")[index - 1])
        start(images[0], True, "all-destinations")
        stop()
        assert not writable[2].exists(), "production RuntimeDirectory was retained after stop"
        for directory in writable[:2]:
            assert (directory / "payload").read_text() == "payload\n"
        start(images[0], True, "restart")
        for directory in writable[:2]:
            assert (directory / "payload").read_text() == "payload\npayload\n"
        assert (writable[2] / "payload").read_text() == "payload\n", "runtime retained stale payload"
        stop()
        for name in ("wayland-0", "X0"):
            original = session / name
            saved = session / (name + ".saved")
            original.rename(saved)
            try:
                start(images[0], False, "required-source-" + name)
            finally:
                stop()
                saved.rename(original)
        print("evidence: rootimage lifetime state=preserved cache=preserved runtime=recreated", flush=True)
    finally:
        cleanup(unit, unit_path, writable, scope, sockets, images)
    print("root-image writable-dirs: PASS", flush=True)


if __name__ == "__main__":
    main()
