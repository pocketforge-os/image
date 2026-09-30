#!/usr/bin/env python3
"""Rootfs guard for the dev-only bench USB network (bd tsp-mc9m.41.984.34.2).

The bench USB network switches USB0 to peripheral, so it must never ship in a
release image. scripts/build-rootfs.sh runs this on the extracted rootfs of
EVERY build, before ext4 assembly.

The unit is expected iff --variant is dev AND --kernel-repo is
kernel-sunxi-7.x (install_usbnet_bench in the customize hook uses the same
rule).

The whole tree is walked without following symlinks. An entry is a HIT when:
  - its basename is one of the artifact names or the unit name;
  - it is a symlink whose target's basename is the unit or the script; or
  - it is a regular file whose content digest equals a committed artifact
    (so a renamed copy is still caught).

Expected absent: there must be no hit at all.
Expected present: the hits must be exactly
  - the four artifacts, each at its exact path, as a regular file with the
    committed digest and mode;
  - one enablement symlink, usb-gadget.target.wants/<unit> ->
    /etc/systemd/system/<unit>.
The unit's [Install] section must also parse to exactly
WantedBy=usb-gadget.target.

Anything this cannot read or parse FAILS; nothing is skipped.
Exit status: 0 PASS, 1 FAIL, 2 usage error.
"""
import argparse
import hashlib
import os
import stat
import sys

TAG = "usbnet-bench rootfs guard"
SHIPPING_KERNEL = "kernel-sunxi-7.x"
UNIT = "pocketforge-usbnet-bench.service"
SCRIPT = "usbnet-bench.sh"
# (path in the rootfs, path in the source tree, mode)
ARTIFACTS = (
    ("usr/lib/pocketforge/" + SCRIPT, "rootfs-overlay/usr/lib/pocketforge/" + SCRIPT, 0o755),
    ("etc/systemd/system/" + UNIT, "rootfs-overlay/etc/systemd/system/" + UNIT, 0o644),
    ("etc/udev/rules.d/80-pocketforge-usbnet-bench.rules",
     "rootfs-overlay/etc/udev/rules.d/80-pocketforge-usbnet-bench.rules", 0o644),
    ("etc/systemd/network/30-usb0.network", "rootfs-overlay/etc/systemd/network/30-usb0.network", 0o644),
)
ENABLE_LINK = "etc/systemd/system/usb-gadget.target.wants/" + UNIT
ENABLE_TARGET = "/etc/systemd/system/" + UNIT
WANTED_BY = ["usb-gadget.target"]
NAMES = {os.path.basename(path) for path, _, _ in ARTIFACTS} | {UNIT}
LINK_TARGET_NAMES = {UNIT, SCRIPT}


class Failure(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                digest.update(chunk)
    except OSError as exc:
        raise Failure(f"unreadable {path}: {exc.strerror}") from exc
    return digest.hexdigest()


def load_sources(src):
    digests = {}
    for rel, source, mode in ARTIFACTS:
        path = os.path.join(src, source)
        try:
            st = os.stat(path)
        except OSError as exc:
            raise Failure(f"source_artifact_missing {source}: {exc.strerror}") from exc
        if not stat.S_ISREG(st.st_mode):
            raise Failure(f"source_artifact_not_regular {source}")
        digests[rel] = (sha256_file(path), st.st_size, mode)
    return digests


def walk_hits(rootfs, digests):
    """Every entry under rootfs that names, links to, or copies an artifact."""
    by_digest = {digest: rel for rel, (digest, _, _) in digests.items()}
    sizes = {size for _, size, _ in digests.values()}
    hits = {}
    errors = []

    def onerror(exc):
        errors.append(f"unreadable {exc.filename}: {exc.strerror}")

    for top, dirs, files in os.walk(rootfs, topdown=True, onerror=onerror, followlinks=False):
        for name in dirs + files:
            path = os.path.join(top, name)
            rel = os.path.relpath(path, rootfs)
            kinds = set()
            try:
                st = os.lstat(path)
            except OSError as exc:
                errors.append(f"unreadable {rel}: {exc.strerror}")
                continue
            if name in NAMES:
                kinds.add("name")
            if stat.S_ISLNK(st.st_mode):
                try:
                    target = os.readlink(path)
                except OSError as exc:
                    errors.append(f"unreadable link {rel}: {exc.strerror}")
                    continue
                if os.path.basename(target.rstrip("/")) in LINK_TARGET_NAMES:
                    kinds.add("link")
            elif stat.S_ISREG(st.st_mode) and st.st_size in sizes:
                copied = by_digest.get(sha256_file(path))
                if copied is not None:
                    kinds.add("content")
            if kinds:
                hits[rel] = kinds
    if errors:
        raise Failure("; ".join(errors))
    return hits


def install_values(text):
    """Parse systemd unit syntax; return {key: [tokens]} from [Install]."""
    section = None
    values = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        if line.endswith("\\"):
            raise Failure(f"unit_unparseable line {number}: continuation lines are not expected")
        if line.startswith("["):
            if not line.endswith("]") or len(line) < 3:
                raise Failure(f"unit_unparseable line {number}: {line!r}")
            section = line[1:-1]
            continue
        key, sep, value = line.partition("=")
        if not sep or not key.strip() or section is None:
            raise Failure(f"unit_unparseable line {number}: {line!r}")
        if section == "Install":
            values.setdefault(key.strip(), []).extend(value.split())
    return values


def verify_present(rootfs, digests, hits):
    failures = []
    for rel, (digest, _, mode) in digests.items():
        path = os.path.join(rootfs, rel)
        try:
            st = os.lstat(path)
        except OSError:
            failures.append(f"missing {rel}")
            continue
        if not stat.S_ISREG(st.st_mode):
            failures.append(f"not_regular {rel}")
            continue
        if stat.S_IMODE(st.st_mode) != mode:
            failures.append(f"mode {rel} {oct(stat.S_IMODE(st.st_mode))} != {oct(mode)}")
        if sha256_file(path) != digest:
            failures.append(f"content_mismatch {rel}")
    link = os.path.join(rootfs, ENABLE_LINK)
    if not os.path.islink(link):
        failures.append(f"not_enabled {ENABLE_LINK} is not a symlink")
    elif os.readlink(link) != ENABLE_TARGET:
        failures.append(f"enable_link_target {ENABLE_LINK} -> {os.readlink(link)} != {ENABLE_TARGET}")
    unit_path = os.path.join(rootfs, "etc/systemd/system", UNIT)
    if os.path.isfile(unit_path) and not os.path.islink(unit_path):
        with open(unit_path, encoding="utf-8") as stream:
            install = install_values(stream.read())
        if install != {"WantedBy": WANTED_BY}:
            failures.append(f"install_section {install} != {{'WantedBy': {WANTED_BY}}}")
    expected = {rel: {"name", "content"} for rel in digests}
    expected[ENABLE_LINK] = {"name", "link"}
    for rel, kinds in sorted(hits.items()):
        if expected.get(rel) != kinds:
            failures.append(f"unexpected {rel} ({','.join(sorted(kinds))})")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--variant", required=True, choices=("dev", "release"))
    parser.add_argument("--kernel-repo", required=True)
    parser.add_argument("--src", required=True)
    parser.add_argument("rootfs")
    args = parser.parse_args()
    if not os.path.isdir(args.rootfs) or os.path.islink(args.rootfs):
        print(f"{TAG}: FAIL rootfs_not_a_directory {args.rootfs}", file=sys.stderr)
        return 1
    ship = args.variant == "dev" and args.kernel_repo == SHIPPING_KERNEL
    try:
        digests = load_sources(args.src)
        hits = walk_hits(args.rootfs, digests)
        if ship:
            failures = verify_present(args.rootfs, digests, hits)
        else:
            failures = [f"shipped_in_excluded_rootfs {rel} ({','.join(sorted(kinds))})"
                        for rel, kinds in sorted(hits.items())]
    except Failure as exc:
        failures = [str(exc)]
    context = f"variant={args.variant} kernel={args.kernel_repo or '<none>'} expected={'present' if ship else 'absent'}"
    if failures:
        for failure in failures:
            print(f"{TAG}: FAIL {failure}", file=sys.stderr)
        print(f"{TAG}: FAIL {context}", file=sys.stderr)
        return 1
    detail = f"artifacts={len(ARTIFACTS)} enabled_by={WANTED_BY[0]}" if ship else "hits=0"
    print(f"{TAG}: PASS {context} {detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
