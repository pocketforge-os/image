#!/usr/bin/env python3
"""Every apt-running Dockerfile.pf stage can use the transport apt cache (tsp-hqm1p.135).

Owned image builds failed whenever snapshot.debian.org was down: `pf build` handed the
apt cache over as `--build-arg PF_APT_PROXY`, which only the rootfs stage consumed, so
every other stage (wpa, sdl, cloud-init, gpu-um-build, steamlink-ffmpeg59, debuginfo, ...)
ran apt-get straight against the frozen snapshot.

The route is BuildKit's PREDEFINED `http_proxy` build-arg (platform core/pf-build.sh
pf_apt_cache_buildargs). It reaches every RUN without an ARG line and is excluded from
the layer cache key and from `docker history`. The one catch this test pins: every build
stage starts from a sanitising SHELL wrapper that UNSETS every environment variable not
on an allowlist, so without `http_proxy` on that allowlist the arg never reaches apt.

Contract under test (hermetic: no docker, no network; the BuildKit half of the cache-key
claim is proved against a real builder in tests/test-build-stage-environment.sh):
  1. the sanitising SHELL is one text, and it admits `http_proxy` and NO other proxy
     variable (https/all/ftp/no_proxy stay stripped, so the https fetches stay direct);
     with the proxy on, the environment a RUN sees differs by exactly that variable;
  2. every stage that runs apt (directly or through a helper script) runs under that
     SHELL, and the set of apt stages is the reviewed set below;
  3. cache-key neutrality: no stage declares the proxy as an ARG or ENV (an ARG value
     enters the cache key of every later RUN), and the rootfs stage reads the cache
     from `http_proxy`, not from its own ARG;
  4. non-apt HTTP fetches inside RUN steps are inventoried: each is https-only or
     bypasses the proxy (`--noproxy '*'`, `env -u http_proxy`), so the proxy cannot
     break them;
  5. the steamlink-ffmpeg59 source fetch (https from snapshot.debian.org) is unaffected by
     the proxy: it stays https-only and never takes the plain-http cache path. The live
     cache cannot serve debian-security snapshot pool objects (504/500), so routing this
     fetch through it would turn a working build into a failing one; it stays a known
     outage-vulnerable direct fetch until the cache can carry it;
  6. CVE-2026-109518 (bd tsp-hqm1p.143): every stage whose base ships a vulnerable apt
     (pf-build-base, gpu-um-toolchain, poolsuite-toolchain) runs every apt before its
     pf-assert-apt-fixed with Acquire::Retries=0, and the two live-archive toolchains move
     their sources to https before any later fetch. pf-build-base's self-upgrade source
     takes the transport the cache dictates, run through the real SHELL: plain http with
     the proxy (the cache never carries https), https without it.
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = ROOT / "build" / "Dockerfile.pf"
FFMPEG_BUILD = ROOT / "build" / "platform-runtimes" / "steamlink-ffmpeg59" / "v1" / "build.sh"
TEXT = DOCKERFILE.read_text(encoding="utf-8")
PROXY = "http://10.0.32.86:3142"

# The stages that run apt, reviewed against Dockerfile.pf. A new apt stage fails here until
# a reviewer has confirmed it runs under the proxy-admitting SHELL and belongs on the list.
EXPECTED_APT_STAGES = {
    "pf-build-base",  # CVE-2026-109518 apt self-upgrade, frozen debian-security snapshot
    "gpu-um-toolchain",  # Ubuntu 24.04 live archive + apt.llvm.org (no snapshot exists)
    "gpu-um-build",  # frozen Debian snapshot (arm64 cross sysroot)
    "sdl",  # prepare-sdl-kmsdrm-sysroot -> apt-get, frozen snapshot
    "wpa",  # frozen snapshot
    "cloud-init",  # frozen snapshot
    "platform-runtime-steamlink-ffmpeg59-v1",  # frozen snapshot (+ the source fetch, see 5)
    "poolsuite-toolchain",  # debian:bookworm-slim live archive
    "debuginfo",  # frozen snapshot
    "rootfs",  # build-rootfs.sh -> mmdebstrap, frozen snapshot
}
APT_MARKERS = re.compile(
    r"(?<![\w./-])(?:apt-get|apt|mmdebstrap|debootstrap)(?![\w-])"
    r"|prepare-sdl-kmsdrm-sysroot|scripts/build-rootfs\.sh"
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def code_lines(block: str) -> list[str]:
    return [line for line in block.splitlines() if not line.lstrip().startswith("#")]


def parse_stages(text: str) -> dict[str, dict]:
    pattern = re.compile(r"^FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?\s*$", re.M)
    found = list(pattern.finditer(text))
    stages: dict[str, dict] = {}
    for index, match in enumerate(found):
        end = found[index + 1].start() if index + 1 < len(found) else len(text)
        block = text[match.start() : end]
        name = match.group(2)
        if name is None:
            continue
        shell = None
        for line in block.splitlines():
            shell_match = re.match(r"^SHELL\s+(\[.*\])\s*$", line)
            if shell_match:
                shell = json.loads(shell_match.group(1))
        stages[name] = {"parent": match.group(1), "shell": shell, "block": block}
    return stages


STAGES = parse_stages(TEXT)


def effective_shell(name: str) -> list[str] | None:
    seen: set[str] = set()
    while name in STAGES and name not in seen:
        seen.add(name)
        if STAGES[name]["shell"] is not None:
            return STAGES[name]["shell"]
        name = STAGES[name]["parent"]
    return None  # an external base image without a SHELL: the default shell passes everything


# ---------------------------------------------------------------- 1. the SHELL wrapper
shells = {tuple(s["shell"]) for s in STAGES.values() if s["shell"] is not None}
if len(shells) != 1:
    fail(f"expected exactly one sanitising SHELL text across stages, found {len(shells)}")
SHELL = list(next(iter(shells)))
if SHELL[:2] != ["/bin/sh", "-c"] or len(SHELL) != 3:
    fail(f"unexpected SHELL form: {SHELL!r}")
WRAPPER = SHELL[2]


def run_through_shell(extra_env: dict[str, str]) -> dict[str, str]:
    """Run `env` the way BuildKit runs a RUN under this SHELL: sh -c <wrapper> <command>."""
    env = {"PATH": "/usr/bin:/bin", "HOME": "/root", "PF_KEPT": "kept", "FOO": "stripped",
           "TRACEPARENT": "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"}
    env.update(extra_env)
    result = subprocess.run(
        ["/bin/sh", "-c", WRAPPER, "env"], env=env, check=True, capture_output=True, text=True
    )
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


other_proxies = {
    "https_proxy": "http://other.invalid:1", "HTTPS_PROXY": "http://other.invalid:2",
    "HTTP_PROXY": "http://other.invalid:3", "no_proxy": "example.invalid",
    "NO_PROXY": "example.invalid", "all_proxy": "http://other.invalid:4",
    "ALL_PROXY": "http://other.invalid:5", "ftp_proxy": "http://other.invalid:6",
}
direct = run_through_shell(dict(other_proxies))
proxied = run_through_shell({"http_proxy": PROXY, **other_proxies})

if proxied.get("http_proxy") != PROXY:
    fail("the sanitising SHELL strips http_proxy, so the BuildKit proxy build-arg never reaches "
         "apt in any stage (add http_proxy to the allowlist)")
if proxied.get("PF_KEPT") != "kept":
    fail("the sanitising SHELL must keep its PF_* allowlist")
for name in ("FOO", "TRACEPARENT", *other_proxies):
    if name in proxied or name in direct:
        fail(f"the sanitising SHELL must keep stripping {name}")
without_proxy = {k: v for k, v in proxied.items() if k != "http_proxy"}
if without_proxy != direct:
    fail("the proxy changes the RUN environment by more than http_proxy itself")
print("ok 1 - the SHELL admits http_proxy only; the RUN environment differs by that one variable")

# ---------------------------------------------------------------- 2. apt stages are covered
detected = set()
for name, stage in STAGES.items():
    body = "\n".join(code_lines(stage["block"]))
    if APT_MARKERS.search(body):
        detected.add(name)
if detected != EXPECTED_APT_STAGES:
    fail(
        "the set of apt-running stages changed: new="
        f"{sorted(detected - EXPECTED_APT_STAGES)} gone={sorted(EXPECTED_APT_STAGES - detected)}; "
        "confirm each new stage runs under the proxy-admitting SHELL, then update the list"
    )
for name in sorted(detected):
    shell = effective_shell(name)
    if shell is not None and shell != SHELL:
        fail(f"{name}: runs under an unexpected SHELL {shell!r}")
    if shell is None:
        continue  # the default shell passes the proxy through
    if not re.search(r"\|http_proxy[|)]", shell[2]):
        fail(f"{name}: SHELL does not admit http_proxy")
print(f"ok 2 - all {len(detected)} apt-running stages run under the proxy-admitting SHELL")

# ---------------------------------------------------------------- 3. cache-key neutrality
for name, stage in STAGES.items():
    for line in code_lines(stage["block"]):
        if re.match(r"^\s*(ARG|ENV)\s+(PF_APT_PROXY|http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY)\b", line):
            fail(f"{name}: `{line.strip()}` puts the proxy into the cache key of every later RUN")
rootfs = "\n".join(code_lines(STAGES["rootfs"]["block"]))
if "${PF_APT_PROXY" in rootfs:
    fail("rootfs reads PF_APT_PROXY from its own ARG; read the predefined http_proxy instead")
if 'PF_APT_PROXY="${http_proxy:-}"' not in rootfs:
    fail("rootfs must hand build-rootfs.sh the cache from the predefined http_proxy")
print("ok 3 - no stage lets the proxy value into a cache key; rootfs reads http_proxy")

# ---------------------------------------------------------------- 4. non-apt HTTP fetches
logical = []
for stage_name, stage in STAGES.items():
    joined = re.sub(r"\\\n\s*", " ", "\n".join(code_lines(stage["block"])))
    for line in joined.splitlines():
        logical.append((stage_name, line.strip()))

fetchers = 0
for stage_name, line in logical:
    if re.match(r"^(DEBIAN_FRONTEND=\S+\s+)?apt(-get)?\s", line):
        continue  # package lists mention curl/wget as package names
    if not re.search(r"(?:^|[\s;&|(])(?:curl|wget)\s+-", line):
        continue
    fetchers += 1
    if "--noproxy" in line:
        continue
    if "--proto '=https'" in line and "http://" not in line:
        continue
    fail(f"{stage_name}: fetch can hit the proxy; make it https-only or pass --noproxy '*': {line[:120]}")
if fetchers < 2:
    fail(f"fetch inventory found {fetchers} curl/wget uses; expected the CTS bundle and rustup")
cts = [line for stage, line in logical if stage == "cts-bundle-v1" and re.search(r"\bcurl\s+-", line)]
if len(cts) != 1 or "--noproxy '*'" not in cts[0]:
    fail("cts-bundle-v1: the plain-http artifact-store fetch must bypass the proxy (--noproxy '*')")

plain_http = 0
for stage_name, line in logical:
    for match in re.finditer(r"http://[^\s'\"]+", line):
        url = match.group(0)
        host = re.match(r"http://([^/\s'\"#]+)/", url)
        if re.match(r"^sed\s", line) and host and f"https://{host.group(1)}/" in line:
            continue  # a reviewed http -> https apt source rewrite (CVE-2026-109518)
        if url.startswith("http://127.0.0.1:") and stage_name == "debuginfo":
            plain_http += 1
            if "env -u http_proxy" not in line:
                fail("debuginfo: the loopback debuginfod client must not go through the proxy "
                     "(env -u http_proxy)")
            continue
        fail(f"{stage_name}: unreviewed plain-http reference {url}; classify it (proxy or bypass)")
if plain_http < 1:
    fail("debuginfo: the loopback debuginfod fetch disappeared; refresh the inventory")
for stage_name, line in logical:
    if stage_name == "debuginfo" and "debuginfod-find" in line and "env -u http_proxy" not in line:
        fail("debuginfo: every debuginfod-find must run with env -u http_proxy")
print("ok 4 - every non-apt HTTP fetch is https-only or bypasses the proxy")

# ---------------------------------------------------------------- 5. ffmpeg59 source fetch
build_text = FFMPEG_BUILD.read_text(encoding="utf-8")
match = re.search(r"^fetch_one\(\) \{\n.*?^\}\n", build_text, re.M | re.S)
if not match:
    fail("steamlink-ffmpeg59 build.sh has no fetch_one function")
fetch_one = match.group(0)
with tempfile.TemporaryDirectory(prefix="apt-cache-transport.") as tmp:
    tmp_path = Path(tmp)
    (tmp_path / "bin").mkdir()
    fake_curl = tmp_path / "bin" / "curl"
    fake_curl.write_text(
        '#!/bin/sh\nprintf "%s\\n" "$*" >>"$FAKE_CURL_LOG"\n'
        'while [ "$#" -gt 0 ]; do [ "$1" = --output ] && { shift; printf x >"$1"; }; shift; done\n',
        encoding="utf-8",
    )
    fake_curl.chmod(0o755)
    harness = tmp_path / "harness.sh"
    harness.write_text(
        "set -euo pipefail\n"
        "require_equal() { :; }\n"
        "FFMPEG_SNAPSHOT_BASE='https://snapshot.debian.org/archive/debian-security/"
        "20251210T222759Z/pool/updates/main/f/ffmpeg'\n"
        f"src_objects={tmp_path}/objects\nmkdir -p \"$src_objects\"\n"
        f"{fetch_one}\n"
        "fetch_one ffmpeg_5.1.8.orig.tar.xz 1 deadbeef\n",
        encoding="utf-8",
    )

    def fetch(env_extra: dict[str, str]) -> str:
        log = tmp_path / "curl.log"
        log.write_text("", encoding="utf-8")
        env = {"PATH": f"{tmp_path}/bin:/usr/bin:/bin", "FAKE_CURL_LOG": str(log), **env_extra}
        subprocess.run(["bash", str(harness)], env=env, check=True, capture_output=True, text=True)
        return log.read_text(encoding="utf-8").strip()

    direct_call = fetch({})
    proxied_call = fetch({"http_proxy": PROXY})

if direct_call != proxied_call:
    fail(f"the proxy changed the ffmpeg59 source fetch:\n  direct:  {direct_call}\n  proxied: {proxied_call}")
if "--proto =https" not in direct_call or "https://snapshot.debian.org/" not in direct_call:
    fail(f"the ffmpeg59 source fetch must stay https-only: {direct_call}")
print("ok 5 - the ffmpeg59 source fetch is identical with and without the proxy (https, direct)")

# ---------------------------------------------------------------- 6. CVE-2026-109518
RETRY_SENSITIVE = ("pf-build-base", "gpu-um-toolchain", "poolsuite-toolchain")
for name in RETRY_SENSITIVE:
    lines = [line for stage, line in logical if stage == name]
    asserts = [i for i, line in enumerate(lines) if line == "pf-assert-apt-fixed"]
    if not asserts:
        fail(f"{name}: no pf-assert-apt-fixed gate after its apt self-upgrade")
    before = lines[: asserts[0]]
    apt_runs = [line for line in before if re.search(r"(?:^|[\s;&|(])apt-get\s", line)]
    if not apt_runs:
        fail(f"{name}: no apt self-upgrade before pf-assert-apt-fixed")
    for line in apt_runs:
        if "-o Acquire::Retries=0" not in line:
            fail(f"{name}: apt runs before the fix is asserted with retries on: {line[:120]}")
    if name == "pf-build-base":
        continue
    after = lines[asserts[0] + 1 :]
    first_apt = next((i for i, line in enumerate(after) if re.search(r"\bapt-get\b", line)), None)
    rewrite = next((i for i, line in enumerate(after) if re.match(r"^sed\s", line) and "https://" in line), None)
    if rewrite is None or first_apt is None or rewrite > first_apt:
        fail(f"{name}: the archive sources must move to https before the next apt fetch")
block = "\n".join(code_lines(STAGES["gpu-um-toolchain"]["block"]))
if "s#http://apt.llvm.org/#https://apt.llvm.org/#" not in block:
    fail("gpu-um-toolchain: apt.llvm.org must be rewritten to https in install-mesa-buildenv.sh")
if "URIs: https://ports.ubuntu.com/ubuntu-ports" not in block:
    fail("gpu-um-toolchain: the arm64 ports source must be https")

base_block = STAGES["pf-build-base"]["block"]
heredoc = re.search(r"^RUN <<'APTCVE2026109518'\n(.*?)^APTCVE2026109518$", base_block, re.M | re.S)
if not heredoc:
    fail("pf-build-base: the CVE-2026-109518 self-upgrade RUN is missing")
body = heredoc.group(1)
if re.search(r">\s*/etc/apt/sources\.list|/etc/apt/sources\.list\.d/", body):
    fail("pf-build-base: the self-upgrade must not edit the persisted base sources")
selector = re.search(r"^if \[ -n \"\$\{http_proxy:-\}\" \];.*?\n(printf .*?sources\.list\"\n)", body, re.M | re.S)
if not selector:
    fail("pf-build-base: the self-upgrade source must select its scheme from http_proxy")
with tempfile.TemporaryDirectory(prefix="apt-cve-scheme.") as tmp:
    script = f"pf_apt_tmp={tmp}\n{selector.group(0)}cat {tmp}/sources.list\n"

    def source_line(extra_env: dict[str, str]) -> str:
        env = {"PATH": "/usr/bin:/bin", "HOME": "/root", **extra_env}
        result = subprocess.run(["/bin/sh", "-c", WRAPPER, script], env=env, check=True,
                                capture_output=True, text=True)
        return result.stdout.strip()

    snapshot = "snapshot.debian.org/archive/debian-security/20261105T000000Z/ bookworm-security main"
    if source_line({}) != f"deb [arch=amd64,arm64 check-valid-until=no] https://{snapshot}":
        fail(f"pf-build-base: direct self-upgrade source is not https: {source_line({})}")
    if source_line({"http_proxy": PROXY}) != f"deb [arch=amd64,arm64 check-valid-until=no] http://{snapshot}":
        fail("pf-build-base: cache-mode self-upgrade source is not plain http through the cache")
print("ok 6 - vulnerable-apt stages self-upgrade with retries off; transport follows the cache")

print("PASS: every apt-running stage can use the transport cache, transport only")
sys.exit(0)
