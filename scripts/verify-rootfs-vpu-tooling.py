#!/usr/bin/env python3
"""Verify Cedrus strict-decode userspace directly from final ext4 bytes.

This gate is intentionally restricted to open-GPU development images. It uses
debugfs as a mountless reader and fails closed on unreadable filesystems,
missing paths, wrong modes, empty plugin files, or absent dpkg package records.
"""

import argparse
import os
import re
import shutil
import stat
import subprocess
import sys


COMMANDS = (
    "/usr/bin/v4l2-ctl",
    "/usr/bin/gst-launch-1.0",
    "/usr/bin/gst-inspect-1.0",
)
PLUGINS = (
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so",
        ("filesrc", "filesink"),
    ),
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoconvertscale.so",
        ("videoconvert",),
    ),
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoparsersbad.so",
        ("h264parse",),
    ),
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstv4l2codecs.so",
        ("v4l2slh264dec",),
    ),
)
PACKAGES = (
    "v4l-utils",
    "gstreamer1.0-tools",
    "gstreamer1.0-plugins-base",
    "gstreamer1.0-plugins-bad",
)
DPKG_STATUS = "/var/lib/dpkg/status"
TAG = "Cedrus strict-decode ext4 gate"


class Failure(Exception):
    """A fail-closed verification result."""


def run_debugfs(image, request):
    try:
        result = subprocess.run(
            ["debugfs", "-R", request, image],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise Failure(f"debugfs unavailable: {exc.strerror}") from exc
    diagnostic = (result.stdout + result.stderr).decode("utf-8", "replace")
    if result.returncode != 0:
        raise Failure(f"debugfs rejected image while running {request!r}: {diagnostic.strip()}")
    return result.stdout, diagnostic


def verify_ext4(image):
    try:
        image_stat = os.stat(image)
    except OSError as exc:
        raise Failure(f"not a readable ext4 filesystem: {image}: {exc.strerror}") from exc
    if not stat.S_ISREG(image_stat.st_mode):
        raise Failure(f"not a readable ext4 filesystem: {image}: not a regular file")
    output, diagnostic = run_debugfs(image, "stats")
    text = output.decode("utf-8", "replace")
    features = re.search(r"^Filesystem features:\s+(.+)$", text, re.MULTILINE)
    if (
        "Filesystem magic number:  0xEF53" not in text
        or not features
        or "extent" not in features.group(1).split()
    ):
        detail = (
            diagnostic.strip().splitlines()[-1]
            if diagnostic.strip()
            else "missing ext4 magic or extents feature"
        )
        raise Failure(f"not a readable ext4 filesystem: {image}: {detail}")


def inode_stat(image, path):
    output, diagnostic = run_debugfs(image, f"stat {path}")
    text = output.decode("utf-8", "replace")
    basename = path.rsplit("/", 1)[-1]
    if "Inode:" not in text or "File not found" in diagnostic:
        raise Failure(f"missing {basename} ({path})")
    kind = re.search(r"\bType:\s+(\S+)", text)
    mode = re.search(r"\bMode:\s+0*([0-7]+)", text)
    size = re.search(r"\bSize:\s+(\d+)", text)
    if not kind or not mode or not size:
        raise Failure(f"unparseable inode metadata for {path}")
    if kind.group(1) != "regular":
        raise Failure(f"not a regular file {basename} ({path})")
    return int(mode.group(1), 8), int(size.group(1))


def installed_packages(image):
    output, diagnostic = run_debugfs(image, f"cat {DPKG_STATUS}")
    if "File not found" in diagnostic:
        raise Failure(f"missing status ({DPKG_STATUS})")
    try:
        text = output.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Failure(f"unparseable dpkg status: invalid UTF-8 at byte {exc.start}") from exc
    found = set()
    for stanza in re.split(r"\n[ \t]*\n", text):
        fields = {}
        for line in stanza.splitlines():
            if not line or line[0].isspace():
                continue
            key, separator, value = line.partition(":")
            if separator:
                fields[key] = value.strip()
        package = fields.get("Package")
        if package and fields.get("Status") == "install ok installed":
            found.add(package)
    return found


def verify(image):
    verify_ext4(image)
    passes = []
    for path in COMMANDS:
        mode, _ = inode_stat(image, path)
        basename = path.rsplit("/", 1)[-1]
        if not mode & 0o111:
            raise Failure(f"not executable {basename} ({path}, mode={mode:#05o})")
        passes.append(f"PASS: executable {path} mode={mode:#05o}")

    for path, elements in PLUGINS:
        _, size = inode_stat(image, path)
        basename = path.rsplit("/", 1)[-1]
        if size <= 0:
            raise Failure(f"empty plugin {basename} ({path})")
        passes.append(
            f"PASS: plugin {path} bytes={size} provides elements={','.join(elements)}"
        )

    found_packages = installed_packages(image)
    for package in PACKAGES:
        if package not in found_packages:
            raise Failure(f"missing package stanza {package} ({DPKG_STATUS})")
        passes.append(f"PASS: package stanza {package} Status=install ok installed")
    return passes


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--gpu-model", required=True, choices=("ddk", "open", "none"))
    parser.add_argument("--variant", required=True, choices=("dev", "release"))
    parser.add_argument("image")
    args = parser.parse_args()

    if args.gpu_model != "open" or args.variant != "dev":
        print(
            f"{TAG}: FAIL refusing excluded scope "
            f"gpu_model={args.gpu_model} variant={args.variant}",
            file=sys.stderr,
        )
        return 1
    if shutil.which("debugfs") is None:
        print(f"{TAG}: FAIL debugfs unavailable", file=sys.stderr)
        return 1
    try:
        passes = verify(args.image)
    except Failure as exc:
        print(f"{TAG}: FAIL {exc}", file=sys.stderr)
        return 1
    for passed in passes:
        print(passed)
    print(
        "PASS: Cedrus strict-decode userspace verified from final ext4 bytes "
        f"commands={len(COMMANDS)} plugins={len(PLUGINS)} packages={len(PACKAGES)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
