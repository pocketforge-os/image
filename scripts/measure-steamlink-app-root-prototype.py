#!/usr/bin/env python3
"""Measure the Steam Link root prototype under host QEMU user emulation.

The result is development evidence only.  It is not an A133 performance
measurement and must never be presented as one.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time


VENDOR_ARCHIVE_SHA256 = (
    "6e1e431265da01b85a7a2fb2ef652f822eb16c5b78aca03f0d0d500dc29b93d3"
)
STARTUP_MARKER = b"Connected to Remote Client service"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(path: Path, description: str) -> None:
    if not path.is_file():
        raise SystemExit(f"FATAL: {description} is missing: {path}")


def tool_version(path: Path) -> str:
    result = subprocess.run(
        [str(path), "--version"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.splitlines()[0]


def read_receipt(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition("=")
        if not separator or not key:
            raise SystemExit(f"FATAL: malformed receipt line: {line!r}")
        values[key] = value
    return values


def descendant_pids(root_pid: int) -> set[int]:
    parents: dict[int, int] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / "stat").read_text(encoding="ascii")
            # The comm field is parenthesized and may contain spaces.  State
            # and PPID are the first two fields after its final right paren.
            fields = stat[stat.rfind(")") + 2 :].split()
            parents[int(entry.name)] = int(fields[1])
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError):
            continue
    members = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, parent in parents.items():
            if parent in members and pid not in members:
                members.add(pid)
                changed = True
    return members


def memory_for_tree(root_pid: int) -> tuple[int, int]:
    rss = 0
    pss = 0
    for pid in descendant_pids(root_pid):
        entry = Path("/proc") / str(pid)
        try:
            lines = (entry / "smaps_rollup").read_text(encoding="ascii").splitlines()
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        for line in lines:
            if line.startswith("Rss:"):
                rss += int(line.split()[1])
            elif line.startswith("Pss:"):
                pss += int(line.split()[1])
    return rss, pss


def terminate_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def run_once(command: list[str], stderr_path: Path, timeout: float) -> dict[str, object]:
    started = time.monotonic_ns()
    process: subprocess.Popen[bytes] | None = None
    reached = False
    startup_ms: float | None = None
    rss_kib = 0
    pss_kib = 0
    try:
        with stderr_path.open("wb") as error_file, open(os.devnull, "wb") as null:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=null,
                stderr=error_file,
                start_new_session=True,
            )
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                error_file.flush()
                try:
                    data = stderr_path.read_bytes()
                except FileNotFoundError:
                    data = b""
                if STARTUP_MARKER in data:
                    reached = True
                    startup_ms = (time.monotonic_ns() - started) / 1_000_000
                    # Let page-fault accounting settle without measuring an
                    # arbitrary long-running idle client.
                    time.sleep(0.10)
                    rss_kib, pss_kib = memory_for_tree(process.pid)
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.01)
    finally:
        if process is not None:
            terminate_group(process)

    tail = stderr_path.read_text(encoding="utf-8", errors="replace").splitlines()[-12:]
    return {
        "startup_marker_reached": reached,
        "startup_ms": round(startup_ms, 1) if startup_ms is not None else None,
        "rss_kib": rss_kib,
        "pss_kib": pss_kib,
        "stderr_tail": tail,
    }


def base_bwrap() -> list[str]:
    return [
        "bwrap",
        "--unshare-all",
        "--share-net",
        "--die-with-parent",
        "--new-session",
        "--clearenv",
        "--setenv",
        "LANG",
        "C.UTF-8",
        "--setenv",
        "QT_QPA_PLATFORM",
        "offscreen",
    ]


def app_root_command(
    prototype: Path, qemu: Path, state: Path, host_resolv: Path
) -> list[str]:
    app = "/opt/pocketforge/apps/org.pocketforge.steamlink"
    return base_bwrap() + [
        "--bind",
        str(prototype / "app-root"),
        "/",
        "--ro-bind",
        str(prototype / "platform-runtime"),
        "/run/pocketforge/platform-runtime",
        "--ro-bind",
        str(qemu),
        "/qemu",
        "--ro-bind",
        str(host_resolv),
        "/etc/resolv.conf",
        "--dir",
        "/state",
        "--bind",
        str(state),
        "/state",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--tmpfs",
        "/tmp",
        "--remount-ro",
        "/",
        "--setenv",
        "HOME",
        "/state/home",
        "--setenv",
        "XDG_CONFIG_HOME",
        "/state/config",
        "--setenv",
        "XDG_CACHE_HOME",
        "/state/cache",
        "--setenv",
        "XDG_DATA_HOME",
        "/state/data",
        "--setenv",
        "QT_PLUGIN_PATH",
        f"{app}/Qt-5.14.1/plugins",
        "--setenv",
        "LD_LIBRARY_PATH",
        ":".join(
            [
                f"{app}/lib",
                f"{app}/Qt-5.14.1/lib",
                "/run/pocketforge/platform-runtime/usr/local/lib",
                "/run/pocketforge/platform-runtime/usr/lib/aarch64-linux-gnu",
                "/usr/lib/aarch64-linux-gnu",
                "/lib/aarch64-linux-gnu",
            ]
        ),
        "--setenv",
        "SSL_CERT_FILE",
        "/etc/ssl/certs/ca-certificates.crt",
        "/qemu",
        "-L",
        "/",
        f"{app}/bin/shell",
    ]


def baseline_command(
    sysroot: Path, vendor: Path, qemu: Path, state: Path, host_resolv: Path
) -> list[str]:
    app = "/opt/steamlink"
    return base_bwrap() + [
        "--bind",
        str(sysroot),
        "/",
        "--dir",
        "/run/systemd",
        "--dir",
        "/run/systemd/resolve",
        "--ro-bind",
        str(host_resolv),
        "/run/systemd/resolve/stub-resolv.conf",
        "--dir",
        app,
        "--ro-bind",
        str(vendor),
        app,
        "--ro-bind",
        str(qemu),
        "/qemu",
        "--dir",
        "/state",
        "--bind",
        str(state),
        "/state",
        "--proc",
        "/proc",
        "--dev",
        "/dev",
        "--tmpfs",
        "/tmp",
        "--remount-ro",
        "/",
        "--setenv",
        "HOME",
        "/state/home",
        "--setenv",
        "XDG_CONFIG_HOME",
        "/state/config",
        "--setenv",
        "XDG_CACHE_HOME",
        "/state/cache",
        "--setenv",
        "XDG_DATA_HOME",
        "/state/data",
        "--setenv",
        "QT_PLUGIN_PATH",
        f"{app}/Qt-5.14.1/plugins",
        "--setenv",
        "LD_LIBRARY_PATH",
        ":".join(
            [
                f"{app}/lib",
                f"{app}/Qt-5.14.1/lib",
                "/usr/local/lib",
                "/usr/lib/aarch64-linux-gnu",
                "/lib/aarch64-linux-gnu",
            ]
        ),
        "--setenv",
        "SSL_CERT_FILE",
        "/etc/ssl/certs/ca-certificates.crt",
        "/qemu",
        "-L",
        "/",
        f"{app}/bin/shell",
    ]


def summarize(runs: list[dict[str, object]]) -> dict[str, object]:
    if not runs or not all(run["startup_marker_reached"] for run in runs):
        raise SystemExit("FATAL: at least one run did not reach the startup marker")
    return {
        "runs": len(runs),
        "startup_ms_median": statistics.median(float(run["startup_ms"]) for run in runs),
        "rss_kib_median": int(statistics.median(int(run["rss_kib"]) for run in runs)),
        "pss_kib_median": int(statistics.median(int(run["pss_kib"]) for run in runs)),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prototype", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=25)
    parser.add_argument(
        "--vendor-dir",
        type=Path,
        default=Path("/home/matt/recovery/steamlink-vendor/rpi-bookworm-arm64-1.3.32.316"),
    )
    parser.add_argument(
        "--qemu-dir",
        type=Path,
        default=Path("/home/matt/recovery/steamlink-qemu/rb2g"),
    )
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")

    for tool in ("bwrap", "qemu-aarch64-static", "tar"):
        if shutil.which(tool) is None:
            raise SystemExit(f"FATAL: required tool is unavailable: {tool}")

    prototype = args.prototype.resolve()
    receipt_path = prototype / "prototype.receipt"
    archive = args.vendor_dir / "steamlink-rpi-bookworm-arm64-1.3.32.316.tar.gz"
    sysroot = args.qemu_dir / "sysroot"
    qemu = Path(shutil.which("qemu-aarch64-static") or "")
    bwrap = Path(shutil.which("bwrap") or "")
    host_resolv = Path("/etc/resolv.conf").resolve()
    for path, description in (
        (receipt_path, "prototype receipt"),
        (prototype / "steam-link.root.raw", "app root image"),
        (prototype / "app.toml", "prototype descriptor"),
        (archive, "preserved vendor archive"),
        (qemu, "QEMU static binary"),
        (bwrap, "bubblewrap binary"),
        (host_resolv, "host resolver file"),
    ):
        require_file(path, description)
    if not sysroot.is_dir():
        raise SystemExit(f"FATAL: preserved sysroot is missing: {sysroot}")
    if sha256(archive) != VENDOR_ARCHIVE_SHA256:
        raise SystemExit("FATAL: preserved vendor archive digest mismatch")

    receipt = read_receipt(receipt_path)
    if receipt.get("measurement_class") != "QEMU/host-development; not A133 performance":
        raise SystemExit("FATAL: prototype receipt has no non-A133 measurement label")
    if sha256(prototype / "steam-link.root.raw") != receipt.get("app_root_sha256"):
        raise SystemExit("FATAL: app root image differs from prototype receipt")

    with tempfile.TemporaryDirectory(prefix="pf-steamlink-measure-") as raw:
        work = Path(raw)
        subprocess.run(
            ["tar", "--extract", "--gzip", "--file", str(archive), "--directory", raw],
            check=True,
        )
        vendor = work / "steamlink"
        baseline_runs: list[dict[str, object]] = []
        root_runs: list[dict[str, object]] = []
        variants = {
            "baseline": (baseline_runs, baseline_command),
            "app_root": (root_runs, app_root_command),
        }
        for index in range(1, args.runs + 1):
            order = ("baseline", "app_root") if index % 2 else ("app_root", "baseline")
            for name in order:
                results, command_factory = variants[name]
                state = work / f"{name}-state-{index}"
                for child in ("home", "config", "cache", "data"):
                    (state / child).mkdir(parents=True, exist_ok=True)
                if name == "baseline":
                    command = command_factory(sysroot, vendor, qemu, state, host_resolv)
                else:
                    command = command_factory(prototype, qemu, state, host_resolv)
                result = run_once(command, work / f"{name}-{index}.stderr", args.timeout)
                results.append(result)
                print(
                    f"{name} run={index} marker={result['startup_marker_reached']} "
                    f"startup_ms={result['startup_ms']} rss_kib={result['rss_kib']} "
                    f"pss_kib={result['pss_kib']}",
                    flush=True,
                )

    baseline = summarize(baseline_runs)
    app_root = summarize(root_runs)
    result = {
        "schema": "pocketforge.steamlink-app-root-measurement/v1",
        "measurement_class": "QEMU/host-development; not A133 performance",
        "startup_marker": STARTUP_MARKER.decode("ascii"),
        "method": (
            "alternating variant order; fresh state; host network; offscreen Qt; "
            "sample 100 ms after marker"
        ),
        "host": {
            "machine": os.uname().machine,
            "kernel_release": os.uname().release,
        },
        "host_tools": {
            "qemu_aarch64_static": {
                "version": tool_version(qemu),
                "sha256": sha256(qemu),
            },
            "bubblewrap": {
                "version": tool_version(bwrap),
                "sha256": sha256(bwrap),
            },
        },
        "runs_per_variant": args.runs,
        "prototype": {
            "app_root_sha256": receipt["app_root_sha256"],
            "platform_runtime_sha256": receipt["platform_runtime_sha256"],
            "app_root_squashfs_bytes": int(receipt["app_root_squashfs_bytes"]),
            "app_root_unpacked_bytes": int(receipt["app_root_bytes"]),
            "platform_runtime_unpacked_bytes": int(receipt["platform_runtime_bytes"]),
        },
        "baseline_summary": baseline,
        "app_root_summary": app_root,
        "delta_app_root_minus_baseline": {
            "startup_ms_median": round(
                float(app_root["startup_ms_median"]) - float(baseline["startup_ms_median"]), 1
            ),
            "rss_kib_median": int(app_root["rss_kib_median"]) - int(baseline["rss_kib_median"]),
            "pss_kib_median": int(app_root["pss_kib_median"]) - int(baseline["pss_kib_median"]),
        },
        "baseline_runs": baseline_runs,
        "app_root_runs": root_runs,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"measurement=PASS output={args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
