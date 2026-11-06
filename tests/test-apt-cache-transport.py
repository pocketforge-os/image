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
     the proxy (the cache never carries https), https without it;
  6b. the two live-archive toolchains (gpu-um-toolchain, poolsuite-toolchain) pick the same
     transport for their own sources. Their real RUN bodies run under the real SHELL with
     apt stubbed: with the cache no apt fetch may read an https source (the old unconditional
     rewrite made the cache answer "403 CONNECT denied"), without it every fetch after the
     fix is https, and both modes persist byte-identical https sources;
  7. the temporary-list `apt-get update` fails closed: run for real (stubbed apt-get and
     helpers) under the real SHELL, a failed index fetch stops the RUN at the update with
     no install, whereas the same body without --error-on=any (apt 2.6.1 exits 0 on a
     failed fetch, measured in the pinned build image) runs on into the install;
  8. every CI workflow that builds build/Dockerfile.pf hands it the cache as the predefined
     http_proxy build-arg: a RUN on a build-VM runner's pf-insecure builder cannot resolve
     public names (its DNS is fenced to the guest gateway), so the https-direct self-upgrade
     source cannot work there (payload run 42154043539).
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
        if re.match(r"^sed\s", line) and host and (
            f"https://{host.group(1)}/" in line or "${pf_apt_scheme}://" + host.group(1) + "/" in line
        ):
            continue  # a reviewed apt source scheme rewrite (CVE-2026-109518; see 6b)
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
APT_SCHEME_SELECTOR = 'if [ -n "${http_proxy:-}" ]; then pf_apt_scheme=http; else pf_apt_scheme=https; fi'
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
    selectors = [i for i, line in enumerate(lines) if line == APT_SCHEME_SELECTOR]
    first_apt_any = next((i for i, line in enumerate(lines) if re.search(r"\bapt-get\b", line)), None)
    if len(selectors) != 1 or first_apt_any is None or selectors[0] > first_apt_any:
        fail(f"{name}: the apt scheme must be selected from http_proxy, with pf-build-base's exact "
             f"selection, before the first apt fetch: {APT_SCHEME_SELECTOR}")
    after = lines[asserts[0] + 1 :]
    first_apt = next((i for i, line in enumerate(after) if re.search(r"\bapt-get\b", line)), None)
    rewrite = next((i for i, line in enumerate(after)
                    if re.match(r"^sed\s", line) and "${pf_apt_scheme}://" in line), None)
    if rewrite is None or first_apt is None or rewrite > first_apt:
        fail(f"{name}: the archive sources must take the selected scheme before the next apt fetch")
block = "\n".join(code_lines(STAGES["gpu-um-toolchain"]["block"]))
if 'sed -i "s#http://apt.llvm.org/#${pf_apt_scheme}://apt.llvm.org/#"' not in block:
    fail("gpu-um-toolchain: apt.llvm.org must take the selected scheme in install-mesa-buildenv.sh")
if 'URIs: ${pf_apt_scheme}://ports.ubuntu.com/ubuntu-ports' not in block:
    fail("gpu-um-toolchain: the arm64 ports source must take the selected scheme")

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

# ---------------------------------------------------------------- 6b. no unconditional https
# The two live-archive toolchains start from a bare base image and persist their archive
# sources, so they pick the transport themselves. Run the REAL RUN bodies (stubbed apt and
# helpers, every path moved under a temp root) with and without the cache and watch the
# sources each apt-get actually reads: with `http_proxy` set the cache cannot carry https (it
# remaps these hosts upstream and answers "403 CONNECT denied" to an https source; owned image
# run 42205566394), so any https source an apt-get sees while proxied is the old bug. Without
# the cache every post-fix fetch must be https. Both modes must persist the same https sources.
LIVE_ARCHIVE_STAGES = {
    "gpu-um-toolchain": ("GPUUMTOOLCHAIN", {
        "etc/apt/sources.list.d/ubuntu.sources":
            "Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble noble-updates noble-backports\n"
            "Components: main restricted universe multiverse\n\n"
            "Types: deb\nURIs: http://security.ubuntu.com/ubuntu\nSuites: noble-security\n"
            "Components: main restricted universe multiverse\n",
        "etc/apt/sources.list": "# See /etc/apt/sources.list.d/ubuntu.sources\n",
        # What gpu-um-tsp's installer does: it writes the LLVM source as plain http.
        "usr/local/src/install-mesa-buildenv.sh":
            "#!/bin/sh\napt-get update\nmkdir -p %ROOT%/etc/apt/sources.list.d\n"
            "cat >%ROOT%/etc/apt/sources.list.d/llvm-20.list <<'LLVM'\n"
            "deb [signed-by=/etc/apt/keyrings/apt.llvm.org.gpg] http://apt.llvm.org/noble/ "
            "llvm-toolchain-noble-20 main\nLLVM\napt-get update\napt-get install -y llvm-20\n",
    }),
    "poolsuite-toolchain": ("POOLSUITETOOLCHAIN", {
        "etc/apt/sources.list.d/debian.sources":
            "Types: deb\nURIs: http://deb.debian.org/debian\nSuites: bookworm bookworm-updates\n"
            "Components: main\n\nTypes: deb\nURIs: http://deb.debian.org/debian-security\n"
            "Suites: bookworm-security\nComponents: main\n",
    }),
}
# A stage that runs apt off a bare base image (not pf-build-base's frozen snapshot) persists
# live archive sources and so needs this behavioural test: make adding one a conscious act.
for name in sorted(EXPECTED_APT_STAGES):
    chain: set[str] = set()
    current = name
    while current in STAGES and current not in chain:
        chain.add(current)
        current = STAGES[current]["parent"]
    if "pf-build-base" not in chain and name not in LIVE_ARCHIVE_STAGES:
        fail(f"{name}: a new live-archive apt stage; add it to LIVE_ARCHIVE_STAGES so the proxied "
             "and direct source schemes are exercised")

STUB_APT_GET = r"""#!/bin/sh
# Records every apt-get with the scheme of each source it would read at that moment.
cmd=''
for a in "$@"; do case "$a" in update|install|download|dist-upgrade) cmd=$a ;; esac; done
printf 'apt-get %s http_proxy=<%s>\n' "$cmd" "${http_proxy:-}" >>"$PF_STAGE_LOG"
for f in "$PF_STAGE_ROOT"/etc/apt/sources.list "$PF_STAGE_ROOT"/etc/apt/sources.list.d/*; do
    [ -f "$f" ] || continue
    sed -n -e 's/^URIs: \([a-z]*\):.*/src \1/p' -e 's/^deb .* \([a-z]*\):\/\/.*/src \1/p' "$f" >>"$PF_STAGE_LOG"
done
"""
STUB_CURL = r"""#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then printf '#!/bin/sh\nexit 0\n' >"$2"; shift; fi
    shift
done
"""
STUB_RUSTC = '#!/bin/sh\necho "rustc 1.91.0 (stub)"\n'


def run_live_archive_stage(stage: str, extra_env: dict[str, str], mutate=None) -> tuple[int, list[str], dict[str, str], str]:
    """Run the stage's RUN body for real under the SHELL wrapper. Returns rc, apt log, the
    persisted apt sources, and stderr."""
    heredoc_name, seed = LIVE_ARCHIVE_STAGES[stage]
    found = re.search(rf"^RUN <<'{heredoc_name}'\n(.*?)^{heredoc_name}$", STAGES[stage]["block"], re.M | re.S)
    if not found:
        fail(f"{stage}: the {heredoc_name} RUN is missing")
    script = found.group(1)
    if mutate is not None:
        script = mutate(script)
    with tempfile.TemporaryDirectory(prefix="apt-live-stage.") as tmp:
        root = Path(tmp)
        for prefix in ("/etc/apt/", "/usr/local/src/", "/var/lib/apt/lists/", "/tmp/rustup-init"):
            script = script.replace(prefix, f"{root}{prefix}")
        script = script.replace("/toolchain-packages.txt", f"{root}/toolchain-packages.txt")
        # The body deletes and rewrites files: refuse to run it unless every absolute path it
        # touches is inside the temp root (the three non-paths are sed expressions and file text).
        for path in re.findall(r"(?<![\w.:/$}-])/[A-Za-z][\w./*-]*", "\n".join(code_lines(script))):
            if not path.startswith(f"{root}/") and path not in ("/d", "/deb", "/usr/share/keyrings/ubuntu-archive-keyring.gpg"):
                fail(f"{stage}: the test harness would run on a real path ({path}); map it under the temp root")
        for rel in ("etc/apt/sources.list.d", "usr/local/src", "var/lib/apt/lists", "tmp"):
            (root / rel).mkdir(parents=True)
        for rel, text in seed.items():
            target = root / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text.replace("%ROOT%", str(root)), encoding="utf-8")
            if rel.endswith(".sh"):
                target.chmod(0o755)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        log = root / "stage.log"
        log.write_text("", encoding="utf-8")
        stubs = {"apt-get": STUB_APT_GET, "curl": STUB_CURL, "rustc": STUB_RUSTC,
                 "dpkg": "#!/bin/sh\nexit 0\n", "dpkg-query": "#!/bin/sh\necho stub 1\n",
                 "sha256sum": "#!/bin/sh\nexit 0\n", "rustup": "#!/bin/sh\nexit 0\n",
                 "cargo": "#!/bin/sh\necho cargo\n", "aarch64-linux-gnu-gcc": "#!/bin/sh\necho gcc\n",
                 "pf-assert-apt-fixed": '#!/bin/sh\necho ASSERT >>"$PF_STAGE_LOG"\n'}
        for name, text in stubs.items():
            (bin_dir / name).write_text(text, encoding="utf-8")
            (bin_dir / name).chmod(0o755)
        env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": "/root", "PF_STAGE_LOG": str(log),
               "PF_STAGE_ROOT": str(root), "RUST_VERSION": "1.91.0", "RUSTUP_VERSION": "1.28.2",
               "RUSTUP_INIT_SHA256": "0" * 64, **extra_env}
        result = subprocess.run(["/bin/sh", "-c", WRAPPER, script], env=env, capture_output=True, text=True)
        persisted = {rel: (root / rel).read_text(encoding="utf-8") for rel in seed
                     if rel.startswith("etc/apt/sources.list.d/")}
        for extra in (root / "etc/apt/sources.list.d").iterdir():
            persisted[f"etc/apt/sources.list.d/{extra.name}"] = extra.read_text(encoding="utf-8")
        return result.returncode, log.read_text(encoding="utf-8").splitlines(), persisted, result.stderr


def scheme_violations(lines: list[str], proxied: bool) -> list[str]:
    """Sources an apt-get read in the wrong scheme for the transport: while proxied, https is
    the bug; direct, http after pf-assert-apt-fixed is."""
    problems: list[str] = []
    asserted = False
    current = ""
    fetches_after_fix = 0
    for line in lines:
        if line == "ASSERT":
            asserted = True
        elif line.startswith("apt-get "):
            current = line
            fetches_after_fix += asserted
        elif line.startswith("src "):
            scheme = line.split()[1]
            if proxied and scheme != "http":
                problems.append(f"{scheme} source read while proxied by `{current}`")
            if not proxied and asserted and scheme != "https":
                problems.append(f"{scheme} source read after the fix by `{current}`")
    if not fetches_after_fix:
        problems.append("no apt fetch ran after pf-assert-apt-fixed")
    return problems


persisted_by_mode: dict[str, dict[str, dict[str, str]]] = {}
for stage in LIVE_ARCHIVE_STAGES:
    for mode, env in (("cache", {"http_proxy": PROXY}), ("direct", {})):
        rc, log_lines, persisted, stderr = run_live_archive_stage(stage, env)
        if rc != 0:
            fail(f"{stage}: the {mode}-mode RUN body failed (rc={rc}): {stderr.strip()[-300:]}")
        problems = scheme_violations(log_lines, proxied=(mode == "cache"))
        if problems:
            fail(f"{stage}: {mode} mode reads sources in the wrong scheme: {problems}")
        if any(proxy != PROXY for proxy in re.findall(r"http_proxy=<(.*)>", "\n".join(log_lines)) if mode == "cache"):
            fail(f"{stage}: the cache-mode apt fetches lost http_proxy")
        if any(re.search(r"^(?!#).*http://", text, re.M) for text in persisted.values()):
            fail(f"{stage}: {mode} mode persisted a plain-http source")
        persisted_by_mode.setdefault(stage, {})[mode] = persisted
    if persisted_by_mode[stage]["cache"] != persisted_by_mode[stage]["direct"]:
        fail(f"{stage}: the persisted sources differ with and without the cache; the layer must be "
             "byte-identical either way")
    # Red controls: the old unconditional-https recipe must be caught while proxied, and an
    # unconditional-http one without the cache, or this check no longer discriminates.
    rc, log_lines, _, _ = run_live_archive_stage(stage, {"http_proxy": PROXY},
                                                 mutate=lambda body: body.replace("${pf_apt_scheme}", "https"))
    if not any("https source read while proxied" in problem for problem in scheme_violations(log_lines, True)):
        fail(f"negative control: {stage} rewriting to https unconditionally while proxied was not detected")
    rc, log_lines, _, _ = run_live_archive_stage(stage, {}, mutate=lambda body: body.replace("${pf_apt_scheme}", "http"))
    if not any("http source read after the fix" in problem for problem in scheme_violations(log_lines, False)):
        fail(f"negative control: {stage} staying http after the fix without the cache was not detected")
print("ok 6b - the live-archive toolchains take http through the cache and https direct, and persist "
      "identical https sources either way (unconditional-https red control proves it)")

# ---------------------------------------------------------------- 7. update fails closed
update_calls = re.findall(r'^apt-get -o Acquire::Retries=0 "\$@" update([^\n]*)$', body, re.M)
if len(update_calls) != 1 or "--error-on=any" not in update_calls[0].split():
    fail("pf-build-base: the temporary-list `apt-get update` must run with --error-on=any "
         f"(a failed index fetch exits 0 otherwise): {update_calls!r}")

FAKE_APT_GET = r"""#!/bin/sh
# Stand-in for apt 2.6.1, modelled on what that apt does offline (measured in the pinned
# build image): `update` with a failed fetch warns and exits 0, and exits 100 with
# --error-on=any.
cmd=''; error_on=0; dl=0; cache=''; list=''
for a in "$@"; do
    case "$a" in
        update|install|download) cmd=$a ;;
        --error-on=any) error_on=1 ;;
        --download-only) dl=1 ;;
        Dir::Cache=*) cache=${a#Dir::Cache=} ;;
        Dir::Etc::SourceList=*) list=${a#Dir::Etc::SourceList=} ;;
    esac
done
printf 'apt-get %s error_on=%s download_only=%s http_proxy=<%s>\n' "$cmd" "$error_on" "$dl" "${http_proxy:-}" >>"$PF_FAKE_LOG"
case "$cmd" in
    update)
        printf 'sources %s\n' "$(cat "$list")" >>"$PF_FAKE_LOG"
        printf '%s\n' "$(dirname "$list")" >>"$PF_FAKE_LOG.tmpdirs"
        if [ -n "${PF_FAKE_FETCH_FAIL:-}" ]; then
            echo "W: Failed to fetch InRelease  Temporary failure resolving 'snapshot.debian.org'" >&2
            [ "$error_on" = 1 ] || exit 0
            echo "E: Some index files failed to download. They have been ignored, or old ones used instead." >&2
            exit 100
        fi
        ;;
    install)
        if [ "$dl" = 1 ]; then
            : >"$cache/archives/apt_2.6.2_amd64.deb"
            : >"$cache/archives/libapt-pkg6.0_2.6.2_amd64.deb"
        fi
        ;;
    download)
        : >apt_2.6.2_arm64.deb
        : >libapt-pkg6.0_2.6.2_arm64.deb
        ;;
esac
"""
FAKE_INSTALL = r"""#!/bin/sh
# `install -d [-o u] [-g g] [-m mode] DIR...` without needing root or the _apt user.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -d) ;;
        -o|-g|-m) shift ;;
        *) mkdir -p "$1" ;;
    esac
    shift
done
"""
FAKE_NOTE = '#!/bin/sh\nprintf "%s\\n" "{name}" >>"$PF_FAKE_LOG"\n'


def run_self_upgrade(script_body: str, extra_env: dict[str, str]) -> tuple[int, list[str]]:
    """Run the RUN body for real under the SHELL wrapper, with apt and root-only helpers stubbed."""
    with tempfile.TemporaryDirectory(prefix="apt-cve-run.") as tmp:
        tmp_path = Path(tmp)
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        stubs = {"apt-get": FAKE_APT_GET, "install": FAKE_INSTALL, "dpkg-query": "#!/bin/sh\nexit 1\n"}
        for name in ("chown", "sha256sum", "pf-assert-apt-fixed"):
            stubs[name] = FAKE_NOTE.format(name=name)
        for name, text in stubs.items():
            (bin_dir / name).write_text(text, encoding="utf-8")
            (bin_dir / name).chmod(0o755)
        log = tmp_path / "calls.log"
        log.write_text("", encoding="utf-8")
        env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": "/root", "PF_FAKE_LOG": str(log), **extra_env}
        script = script_body.replace("/opt/pocketforge/apt-cve-2026-109518", str(tmp_path / "apt-fix"))
        result = subprocess.run(["/bin/sh", "-c", WRAPPER, script], env=env, capture_output=True, text=True)
        leftovers = Path(f"{log}.tmpdirs")
        if leftovers.exists():  # the body's own mktemp -d, left behind when the RUN fails
            for leftover in leftovers.read_text(encoding="utf-8").split():
                subprocess.run(["rm", "-rf", "--", leftover], check=True)
        return result.returncode, log.read_text(encoding="utf-8").splitlines()


def apt_commands(lines: list[str]) -> list[str]:
    return [line.split()[1] + (" --download-only" if "download_only=1" in line else "")
            for line in lines if line.startswith("apt-get ")]


fetch_fail = {"http_proxy": PROXY, "PF_FAKE_FETCH_FAIL": "1"}
rc, calls = run_self_upgrade(body, fetch_fail)
if rc == 0 or apt_commands(calls) != ["update"]:
    fail(f"pf-build-base: a failed index fetch must stop the RUN at the update (rc={rc}): {calls}")
if "error_on=1" not in calls[0]:
    fail(f"pf-build-base: the update ran without --error-on=any: {calls[0]}")
rc, calls = run_self_upgrade(body.replace(" update --error-on=any", " update"), fetch_fail)
if "install" not in apt_commands(calls):
    fail("negative control: without --error-on=any the failed fetch must run on into the install; "
         "the fail-closed check above no longer discriminates")
rc, calls = run_self_upgrade(body, {"http_proxy": PROXY})
if rc != 0 or apt_commands(calls) != ["update", "install --download-only", "install", "download"]:
    fail(f"pf-build-base: the cache-mode self-upgrade did not run to the end (rc={rc}): {calls}")
if "sources deb [arch=amd64,arm64 check-valid-until=no] http://snapshot.debian.org/" not in "\n".join(calls) \
        or any(f"http_proxy=<{PROXY}>" not in line for line in calls if line.startswith("apt-get ")):
    fail(f"pf-build-base: cache mode must read the snapshot over http with http_proxy set: {calls}")
rc, calls = run_self_upgrade(body, {})
if rc != 0 or "sources deb [arch=amd64,arm64 check-valid-until=no] https://snapshot.debian.org/" not in "\n".join(calls) \
        or any("http_proxy=<>" not in line for line in calls if line.startswith("apt-get ")):
    fail(f"pf-build-base: with no cache the self-upgrade must read the snapshot over https direct: {calls}")
print("ok 7 - a failed index fetch stops the self-upgrade at the update (red control proves it)")

# ---------------------------------------------------------------- 8. CI hands the cache over
builds = 0
for workflow in sorted((ROOT / ".github" / "workflows").glob("*.yml")):
    text = workflow.read_text(encoding="utf-8")
    for line in re.sub(r"\\\n\s*", " ", text).splitlines():
        if "buildx build" not in line or "build/Dockerfile.pf" not in line:
            continue
        builds += 1
        if '--build-arg http_proxy="$PF_APT_CACHE"' not in line:
            fail(f'{workflow.name}: a Dockerfile.pf build must pass --build-arg http_proxy="$PF_APT_CACHE" '
                 "(a build-VM RUN cannot resolve snapshot.debian.org itself)")
        if not re.search(r"(?m)^  PF_APT_CACHE: http://\d+\.\d+\.\d+\.\d+:\d+$", text):
            fail(f"{workflow.name}: PF_APT_CACHE must be a plain-http IP:port cache endpoint "
                 "(the CI->NAS hop; the cache never carries https)")
if builds < 1:
    fail("no workflow builds build/Dockerfile.pf any more; refresh the CI routing inventory")
print(f"ok 8 - all {builds} CI Dockerfile.pf build(s) hand the apt cache over as http_proxy")

print("PASS: every apt-running stage can use the transport cache, transport only")
sys.exit(0)
