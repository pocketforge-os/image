#!/usr/bin/env python3
"""The app-root builder's apt transport follows the cache (bd tsp-hqm1p.143, CVE-2026-109518).

owned-image-build run 42215946514 failed in `[rootfs 21/21]`: scripts/build-debian-app-root.sh
(the Debian 13 Steam Link root, run by install-steamlink-first-run.sh inside the rootfs RUN)
handed mmdebstrap an unconditional https://snapshot.debian.org mirror. The RUN carries
BuildKit's predefined `http_proxy` (the NAS apt-cacher-ng), and apt sends an https source
through `http_proxy` as a CONNECT tunnel; acng lets that through for the Debian hosts
(PassThroughPattern) but cannot cache it. So the root's 59 packages bypassed the cache and
paid snapshot.debian.org's cold-object 504s directly: 18 minutes, then 9 packages failed.

Contract under test (hermetic: stubbed mmdebstrap and mksquashfs, no network, no docker):
  1. with `http_proxy` set the mirror handed to mmdebstrap is plain http (the cache remaps it
     upstream over verified https); without it the mirror is https direct;
  2. the root's persisted apt sources are https in BOTH modes, in the one-line and deb822
     formats, so the root image bytes do not depend on the transport;
  3. a plain-http source that is not the rewritten snapshot (or a rewrite that did not run)
     fails the build closed (rc 65) instead of shipping the cache's scheme;
  4. red controls: the old unconditional-https builder is caught while proxied, and a builder
     without the persisted-source rewrite is caught by both the fail-closed check and, with
     that check also removed, by the root-image identity comparison;
  5. the A523 rootfs builder (scripts/build-rootfs-a523.sh) had the same unconditional https
     mirror and runs in the same proxied RUN: the real script, with a stubbed mmdebstrap that
     records its mirror and aborts, picks http while `http_proxy` is set and https without it,
     and the unconditional-https version is caught (its persisted-source rewrite and policy
     gate are the shared scripts, wired by tests/test-rootfs-apt-policy.sh).
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts" / "build-debian-app-root.sh"
A523_BUILDER = ROOT / "scripts" / "build-rootfs-a523.sh"
REWRITER = ROOT / "scripts" / "rewrite-rootfs-apt-sources-https.sh"
PROXY = "http://10.0.32.86:3142"
SNAPSHOT = "20261010T000000Z"
HTTP_MIRROR = f"http://snapshot.debian.org/archive/debian/{SNAPSHOT}/"
HTTPS_MIRROR = f"https://snapshot.debian.org/archive/debian/{SNAPSHOT}/"

# What mmdebstrap does with its mirror argument: it writes the mirror into the target's apt
# sources (one-line format, or deb822 in a sources.list.d file) and leaves the proxy out.
STUB_MMDEBSTRAP = r"""#!/bin/sh
set -eu
printf '%s\n' "$@" >"$PF_TEST_ARGS"
printf 'http_proxy=<%s> https_proxy=<%s>\n' "${http_proxy:-}" "${https_proxy:-}" >"$PF_TEST_ENV"
output= suite= mirror=
for argument in "$@"; do
    case "$argument" in *.tar) output=$argument ;; esac
    case "$argument" in bookworm|trixie) suite=$argument ;; esac
    case "$argument" in http://*|https://*) mirror=$argument ;; esac
done
[ -n "$output" ] && [ -n "$suite" ] && [ -n "$mirror" ]
tree="$PF_TEST_TREE"
rm -rf "$tree" && mkdir -p "$tree/etc/apt/sources.list.d" "$tree/usr/lib"
printf 'ID=debian\nVERSION_CODENAME=%s\n' "$suite" >"$tree/etc/os-release"
printf 'payload\n' >"$tree/usr/lib/libfixture.so"
case "${PF_TEST_SOURCES_FORMAT:-list}" in
    list)
        printf 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] %s %s main\n' "$mirror" "$suite" \
            >"$tree/etc/apt/sources.list" ;;
    deb822)
        printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n' \
            "$mirror" "$suite" >"$tree/etc/apt/sources.list.d/debian.sources" ;;
esac
if [ -n "${PF_TEST_EXTRA_SOURCE:-}" ]; then
    printf '%s\n' "$PF_TEST_EXTRA_SOURCE" >>"$tree/etc/apt/sources.list"
fi
tar -cf "$output" -C "$tree" .
"""
# The "image" is a deterministic tar of the root's apt directory plus its os-release, so the
# root.raw hash the builder records changes exactly when the persisted sources change.
STUB_MKSQUASHFS = r"""#!/bin/sh
set -eu
source=$1
output=$2
test -f "$source/etc/os-release"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$output" \
    -C "$source" etc/os-release etc/apt
"""


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


class Harness:
    """One scratch tree with the stubs on PATH; `build` runs a builder against it."""

    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="pf-app-root-transport.")
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        for name, text in (("mmdebstrap", STUB_MMDEBSTRAP), ("mksquashfs", STUB_MKSQUASHFS)):
            (self.bin / name).write_text(text, encoding="utf-8")
            (self.bin / name).chmod(0o755)
        self.count = 0

    def close(self) -> None:
        self.tmp.cleanup()

    def builder_copy(self, name: str, mutate=None) -> Path:
        """A copy of the builder and its sibling rewriter, optionally with its text changed."""
        scripts = self.dir / name / "scripts"
        scripts.mkdir(parents=True)
        text = BUILDER.read_text(encoding="utf-8")
        if mutate is not None:
            text = mutate(text)
        (scripts / BUILDER.name).write_text(text, encoding="utf-8")
        shutil.copy2(REWRITER, scripts / REWRITER.name)
        (scripts / BUILDER.name).chmod(0o755)
        return scripts / BUILDER.name

    def build(self, builder: Path, proxied: bool, fmt: str = "list", extra_source: str = "") -> dict:
        self.count += 1
        out = self.dir / f"out-{self.count}"
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.dir),
               "PF_TEST_ARGS": str(self.dir / f"args-{self.count}"),
               "PF_TEST_ENV": str(self.dir / f"env-{self.count}"),
               "PF_TEST_TREE": str(self.dir / f"tree-{self.count}"),
               "PF_TEST_SOURCES_FORMAT": fmt, "PF_TEST_EXTRA_SOURCE": extra_source}
        if proxied:
            env["http_proxy"] = PROXY
        result = subprocess.run(
            [str(builder), "--distribution", "debian-13", "--architecture", "arm64",
             "--snapshot", SNAPSHOT, "--output", str(out)],
            env=env, capture_output=True, text=True)
        record = {"rc": result.returncode, "stderr": result.stderr, "mirror": None, "env": "",
                  "sha256": None, "sources": None}
        args = Path(env["PF_TEST_ARGS"])
        if args.exists():
            record["mirror"] = next((a for a in args.read_text(encoding="utf-8").splitlines()
                                     if a.startswith(("http://", "https://"))), None)
            record["env"] = Path(env["PF_TEST_ENV"]).read_text(encoding="utf-8").strip()
        if result.returncode == 0:
            record["sha256"] = json.loads((out / "root.metadata.json").read_text(encoding="utf-8"))["sha256"]
            assert record["sha256"] == hashlib.sha256((out / "root.raw").read_bytes()).hexdigest()
            record["sources"] = subprocess.run(
                ["tar", "-xOf", str(out / "root.raw"), "--wildcards", "etc/apt/sources.list*"],
                capture_output=True, text=True, check=True).stdout
        return record


def violations(harness: Harness, builder: Path) -> list[str]:
    """Everything the contract says is wrong with `builder`, across both formats."""
    problems: list[str] = []
    for fmt in ("list", "deb822"):
        cached = harness.build(builder, True, fmt)
        direct = harness.build(builder, False, fmt)
        for mode, record in (("cache", cached), ("direct", direct)):
            if record["rc"] != 0:
                problems.append(f"{fmt}/{mode}: build failed rc={record['rc']}: {record['stderr'].strip()[-160:]}")
        if cached["rc"] != 0 or direct["rc"] != 0:
            continue
        if cached["mirror"] != HTTP_MIRROR:
            problems.append(f"{fmt}: mirror while proxied is {cached['mirror']!r}, want {HTTP_MIRROR!r}")
        if direct["mirror"] != HTTPS_MIRROR:
            problems.append(f"{fmt}: mirror without the cache is {direct['mirror']!r}, want {HTTPS_MIRROR!r}")
        if f"http_proxy=<{PROXY}>" not in cached["env"]:
            problems.append(f"{fmt}: mmdebstrap lost http_proxy, the cache would not be used")
        if "http_proxy=<>" not in direct["env"]:
            problems.append(f"{fmt}: the direct build still sees a proxy")
        for mode, record in (("cache", cached), ("direct", direct)):
            if "http://" in record["sources"] or HTTPS_MIRROR not in record["sources"]:
                problems.append(f"{fmt}/{mode}: persisted sources are not the https snapshot: {record['sources']!r}")
        if cached["sources"] != direct["sources"] or cached["sha256"] != direct["sha256"]:
            problems.append(f"{fmt}: the root image differs with and without the cache")
    return problems


STUB_A523_MMDEBSTRAP = r"""#!/bin/sh
printf '%s\n' "$@" >"$PF_TEST_ARGS"
printf 'http_proxy=<%s>\n' "${http_proxy:-}" >"$PF_TEST_ENV"
exit 97
"""


def a523_mirror(harness: Harness, builder: Path, proxied: bool) -> dict:
    """Run an A523 builder up to its mmdebstrap call; report the mirror it handed over."""
    harness.count += 1
    n = harness.count
    src = harness.dir / f"a523-src-{n}"
    fix = harness.dir / f"a523-fix-{n}"
    (src / "boards" / "tsp-s").mkdir(parents=True)
    fix.mkdir()
    for name in ("board.env", "fs-uuids.env"):
        shutil.copy2(ROOT / "boards" / "tsp-s" / name, src / "boards" / "tsp-s" / name)
    for name in ("snapshot-date.txt", "rootfs-packages-a523.txt", "rootfs-packages-a523-dev.txt"):
        shutil.copy2(ROOT / name, src / name)
    for name in ("apt_2.6.2_arm64.deb", "libapt-pkg6.0_2.6.2_arm64.deb"):
        (fix / name).write_bytes(b"")
    bin_dir = harness.dir / f"a523-bin-{n}"
    bin_dir.mkdir()
    (bin_dir / "mmdebstrap").write_text(STUB_A523_MMDEBSTRAP, encoding="utf-8")
    (bin_dir / "mmdebstrap").chmod(0o755)
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(harness.dir),
           "SRC_DIR": str(src), "OUT_DIR": str(harness.dir / f"a523-out-{n}"),
           "PF_APT_FIX_DIR": str(fix), "SOURCE_DATE_EPOCH": "1700000000",
           "PF_TEST_ARGS": str(harness.dir / f"a523-args-{n}"),
           "PF_TEST_ENV": str(harness.dir / f"a523-env-{n}")}
    if proxied:
        env["http_proxy"] = PROXY
    result = subprocess.run(["bash", str(builder), "--variant", "release"],
                            env=env, capture_output=True, text=True)
    record = {"rc": result.returncode, "stderr": result.stderr, "mirror": None, "env": ""}
    args = Path(env["PF_TEST_ARGS"])
    if args.exists():
        record["mirror"] = next((a for a in args.read_text(encoding="utf-8").splitlines()
                                 if a.startswith(("http://", "https://"))), None)
        record["env"] = Path(env["PF_TEST_ENV"]).read_text(encoding="utf-8").strip()
    return record


def a523_violations(harness: Harness, builder: Path) -> list[str]:
    problems: list[str] = []
    date = (ROOT / "snapshot-date.txt").read_text(encoding="utf-8").strip()
    base = f"snapshot.debian.org/archive/debian/{date}/"
    for mode, proxied, want in (("cache", True, f"http://{base}"), ("direct", False, f"https://{base}")):
        record = a523_mirror(harness, builder, proxied)
        if record["rc"] != 97 or record["mirror"] is None:
            problems.append(f"a523/{mode}: the builder did not reach mmdebstrap: rc={record['rc']} {record['stderr'].strip()[-160:]!r}")
            continue
        if record["mirror"] != want:
            what = "while proxied" if proxied else "without the cache"
            problems.append(f"a523: mirror {what} is {record['mirror']!r}, want {want!r}")
        want_env = f"http_proxy=<{PROXY}>" if proxied else "http_proxy=<>"
        if record["env"] != want_env:
            problems.append(f"a523/{mode}: mmdebstrap saw {record['env']!r}, want {want_env!r}")
    return problems


def mutate_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        fail(f"mutation anchor not found exactly once: {old!r}")
    return text.replace(old, new)


harness = Harness()
try:
    real = BUILDER
    # 1 + 2: the real builder satisfies the contract in both transports and both formats.
    problems = violations(harness, real)
    if problems:
        fail("the app-root builder breaks the transport contract: " + "; ".join(problems))
    print("ok 1 - the mirror is http through the cache and https direct")
    print("ok 2 - the persisted sources and the root image are identical either way (list + deb822)")

    # 3: a foreign plain-http source, or a rewrite that never ran, is refused.
    for mode, proxied in (("cache", True), ("direct", False)):
        record = harness.build(real, proxied, extra_source="deb http://deb.example.invalid/debian trixie main")
        if record["rc"] != 65 or "plain-http apt source" not in record["stderr"]:
            fail(f"{mode}: a foreign plain-http apt source was not refused with rc 65: {record['rc']} {record['stderr'][-160:]!r}")
    print("ok 3 - a plain-http apt source in the root fails the build closed (rc 65)")

    # 4: red controls. Each mutated builder must be caught, or the checks above prove nothing.
    old_https = harness.builder_copy(
        "old-https", lambda text: mutate_once(text, "mirror_scheme=http\n", "mirror_scheme=https\n"))
    caught = violations(harness, old_https)
    if not any("while proxied" in problem for problem in caught):
        fail(f"negative control: the unconditional-https builder was not caught while proxied: {caught}")

    rewrite_call = '"${script_dir}/rewrite-rootfs-apt-sources-https.sh" "${stage}/rootfs"\n'
    no_rewrite = harness.builder_copy("no-rewrite", lambda text: mutate_once(text, rewrite_call, ""))
    record = harness.build(no_rewrite, True)
    if record["rc"] != 65:
        fail(f"negative control: a builder without the rewrite shipped the cache's scheme (rc={record['rc']})")

    def drop_rewrite_and_guard(text: str) -> str:
        text = mutate_once(text, rewrite_call, "")
        return mutate_once(text, 'exit 65\nfi\nos_release=', 'true\nfi\nos_release=')

    unguarded = harness.builder_copy("unguarded", drop_rewrite_and_guard)
    caught = violations(harness, unguarded)
    if not any("differs with and without the cache" in problem for problem in caught):
        fail(f"negative control: the root-image identity check missed a transport-dependent root: {caught}")
    print("ok 4 - red controls: unconditional https, a missing rewrite, and a transport-dependent root are all caught")

    # 5: the A523 rootfs builder follows the same transport rule.
    problems = a523_violations(harness, A523_BUILDER)
    if problems:
        fail("the A523 rootfs builder breaks the transport contract: " + "; ".join(problems))
    print("ok 5 - the A523 rootfs mirror is http through the cache and https direct")
    a523_text = A523_BUILDER.read_text(encoding="utf-8")
    old_a523 = harness.dir / "old-a523" / "build-rootfs-a523.sh"
    old_a523.parent.mkdir()
    old_a523.write_text(mutate_once(a523_text, "SNAPSHOT_SCHEME=http\n", "SNAPSHOT_SCHEME=https\n"), encoding="utf-8")
    caught = a523_violations(harness, old_a523)
    if not any("while proxied" in problem for problem in caught):
        fail(f"negative control: the unconditional-https A523 builder was not caught while proxied: {caught}")
    print("ok 6 - red control: the unconditional-https A523 builder is caught")
finally:
    harness.close()

print("app-root-apt-transport=PASS")
