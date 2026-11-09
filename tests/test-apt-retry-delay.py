#!/usr/bin/env python3
"""apt's retry delay is off wherever the owned-image build retries apt (tsp-hqm1p.142).

apt 2.3 to 3.0.2 can stop for good in `apt-get update`. It prints nothing, opens no
connection and never times out. The trigger is one index that fails transiently while
another index on the same host succeeds. The failed item is requeued behind
Acquire::Retries::Delay (on by default), the good item's follow-up indexes are queued
ahead of it without waking the queue, and the Run() loop looks only at each queue's
head item. This is upstream LP #2003851, fixed in apt 3.0.3 and 3.1.10 (commit
5378c38d). bookworm's 2.6.x (PF_CONTAINER, the rootfs) and noble's 2.8.x
(gpu-um-toolchain) have no fix. Acquire::http::Timeout cannot end the wait, because
no request is outstanding.

The NAS apt-cacher-ng supplies the trigger. Two clients ask for the same InRelease at
the same moment, acng revalidates it for both, and one client gets the headers and
then a closed connection (acng logs `O 290`). That stopped the wpa stage of an owned
image build for good (tsp-mc9m.60.29.84.67), and sim-suite twice (sim#66).

Disabling the delay removes the deadlock and keeps the retries: a retried item is
then ready at once, and every completion cycles the queue.

Contract under test:
  1. the build container (build/Dockerfile) persists Acquire::Retries "5" in
     99-pocketforge-snapshot, so the same snippet sets Acquire::Retries::Delay "false";
  2. Dockerfile.pf: pf-build-base, gpu-um-toolchain and poolsuite-toolchain write the
     99-pf-retry-delay drop-in before their first apt run that retries, and every
     stage that runs apt descends from one of them (the container itself may be an
     older pin whose snippet still has the delay on);
  3. every mmdebstrap call (build-rootfs.sh, build-rootfs-a523.sh,
     build-debian-app-root.sh) passes --aptopt 'Acquire::Retries::Delay "false"':
     mmdebstrap runs apt with its own config, so no drop-in reaches it;
  3b. the test-only container recipes that run apt (tsp-mc9m.60.29.84.67): in
     tests/input-harness/Containerfile.guest-payload (the pinned build container,
     through the NAS cache) and tests/session-authority-systemd/{,probe/}Containerfile
     (bookworm, apt's default retries) every stage that runs apt with retries has
     the drop-in before that run, itself or in a stage it is built on, and every
     mmdebstrap call there carries the aptopt. tests/input-harness/Containerfile is
     out of scope only while it builds on trixie, whose apt 3.0.3 has the fix;
  4. red controls: each regression of 1-3b is refused;
  5. live, where apt-get and dpkg exist: the effective apt config of each path
     carries `apt-get update` through a loopback origin that cuts the first fetch of
     two of three suites' Release after the headers, and the pinned container's
     snippet alone (the wpa stage before this fix) is still stuck after 10 s. The
     replay runs the host's apt, unprivileged; the red control is skipped on an apt
     that carries the upstream fix.
"""

import hashlib
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = ROOT / "build" / "Dockerfile"
DOCKERFILE_PF = ROOT / "build" / "Dockerfile.pf"
TEST_RECIPES = ("tests/input-harness/Containerfile.guest-payload",
                "tests/session-authority-systemd/Containerfile",
                "tests/session-authority-systemd/probe/Containerfile")
# Recipes whose base apt carries the LP #2003851 fix: the base they must keep.
FIXED_APT_BASES = {
    "tests/input-harness/Containerfile": (
        "ARG BASE_IMAGE=debian@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f",
        "trixie, apt 3.0.3"),
}
MMDEBSTRAP_SCRIPTS = ("scripts/build-rootfs.sh", "scripts/build-rootfs-base.sh",
                      "scripts/build-rootfs-a523.sh", "scripts/build-debian-app-root.sh")
# The a133 rootfs passes take their aptopts from this shared array
# (tsp-hqm1p.182.13); a call's "${MMDEBSTRAP_*_OPTS[@]}" word expands to it.
SHARED_OPTS_LIB = "scripts/rootfs-package-list.sh"
SHARED_ARRAY_WORD = re.compile(r"^\$\{MMDEBSTRAP_(?:PASS|SOLVE|OVERLAY)_OPTS\[@\]\}$")
DELAY_OFF = 'Acquire::Retries::Delay "false";'
DROP_IN_NAME = "99-pf-retry-delay"
DROP_IN_RUN = ("RUN printf '%s\\n' 'Acquire::Retries::Delay \"false\";' > "
               "/etc/apt/apt.conf.d/" + DROP_IN_NAME)
ROOT_STAGES = ("pf-build-base", "gpu-um-toolchain", "poolsuite-toolchain")
# What the container pinned in container.pin (r5) persists: the conf the wpa stage
# retried with when it stalled.
PINNED_CONTAINER_SNIPPET = 'Acquire::Check-Valid-Until "false";\nAcquire::Retries "5";\n'
SUITES = ("s1", "s2", "s3")
CUT_ONCE = ("dists/s1/Release", "dists/s3/Release")
LIVE_TIMEOUT_S = 30
CONTROL_TIMEOUT_S = 10

passed = 0


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def ok(message: str) -> None:
    global passed
    passed += 1
    print(f"ok {passed} - {message}")


def joined(text: str) -> str:
    return re.sub(r"\\\n\s*", " ", text)


def code_lines(block: str) -> list[str]:
    return [line for line in block.splitlines() if not line.lstrip().startswith("#")]


def retries_on(items: list[str]) -> bool:
    for item in items:
        m = re.fullmatch(r'Acquire::Retries "(\d+)";?', item)
        if m:
            return int(m.group(1)) > 0
    return True  # apt's default is 3


# ---------------------------------------------------------------- 1. build container
def container_snippet(text: str) -> list[str] | None:
    found = re.findall(r"printf '%s\\n'\s+((?:'[^']*'\s+)+)> /etc/apt/apt\.conf\.d/"
                       r"99-pocketforge-snapshot", joined(text))
    if len(found) != 1:
        return None
    return re.findall(r"'([^']*)'", found[0])


def container_problems(text: str) -> list[str]:
    items = container_snippet(text)
    if items is None:
        return ["build/Dockerfile: cannot find exactly one 99-pocketforge-snapshot snippet"]
    delay = [i for i in items if i.startswith("Acquire::Retries::Delay ")]
    if retries_on(items) and delay != [DELAY_OFF]:
        return ["reason=apt_retry_delay_deadlock build/Dockerfile: 99-pocketforge-snapshot "
                f"retries without exactly {DELAY_OFF}: {items}"]
    return []


# ---------------------------------------------------------------- 2. Dockerfile.pf
def parse_stages(text: str) -> dict[str, dict]:
    """Stages by name; an unnamed stage is keyed #<its index>."""
    pattern = re.compile(r"^FROM\s+(?:--\S+\s+)*(\S+)(?:\s+AS\s+(\S+))?\s*$", re.M)
    found = list(pattern.finditer(text))
    stages: dict[str, dict] = {}
    for index, match in enumerate(found):
        end = found[index + 1].start() if index + 1 < len(found) else len(text)
        stages[match.group(2) or f"#{index}"] = {"parent": match.group(1),
                                                 "lines": code_lines(text[match.start():end])}
    return stages


# apt itself, or the sdl helper that runs apt-get.
APT_RUN = re.compile(r"(?<![\w./-])(?:apt-get|apt)(?![\w-])\s|prepare-sdl-kmsdrm-sysroot")


def retrying_apt(line: str) -> bool:
    return bool(APT_RUN.search(line)) and "-o Acquire::Retries=0" not in line


def pf_problems(text: str) -> list[str]:
    stages = parse_stages(text)
    problems = []
    for name in ROOT_STAGES:
        if name not in stages:
            problems.append(f"Dockerfile.pf: stage {name} is missing")
            continue
        lines = stages[name]["lines"]
        writes = [i for i, line in enumerate(lines) if line.strip() == DROP_IN_RUN]
        first = next((i for i, line in enumerate(lines) if retrying_apt(line)), None)
        if len(writes) != 1:
            problems.append(f"reason=apt_retry_delay_deadlock {name}: expected one `{DROP_IN_RUN}`, "
                            f"found {len(writes)}")
        elif first is not None and writes[0] > first:
            problems.append(f"reason=apt_retry_delay_deadlock {name}: the retry-delay drop-in comes "
                            f"after an apt run that retries: {lines[first].strip()[:100]}")
    for name, stage in stages.items():
        if not any(APT_RUN.search(line) for line in stage["lines"]):
            continue
        chain, current = [], name
        while current in stages and current not in chain:
            chain.append(current)
            current = stages[current]["parent"]
        if not any(any(line.strip() == DROP_IN_RUN for line in stages[s]["lines"]) for s in chain):
            problems.append(f"reason=apt_retry_delay_deadlock {name}: runs apt, and no stage it "
                            f"descends from ({' -> '.join(chain + [current])}) turns the retry delay off")
    return problems


# ---------------------------------------------------------------- 3. mmdebstrap
def shared_aptopts(lib: str) -> list[str]:
    block = re.search(r"^\s*MMDEBSTRAP_APT_OPTS=\((.*?)^\s*\)", lib, re.M | re.S)
    return shlex.split(block.group(1)) if block else []


def mmdebstrap_calls(text: str, lib: str = "") -> list[list[str]]:
    calls = []
    lines = code_lines(text)
    shared = shared_aptopts(lib)
    for index, line in enumerate(lines):
        if line.strip() not in ("mmdebstrap \\", '"${MMDEBSTRAP}" \\'):
            continue
        command = []
        for part in lines[index:]:
            command.append(part.rstrip())
            if not part.rstrip().endswith("\\"):
                break
        argv = []
        for word in shlex.split(joined("\n".join(command))):
            argv += shared if SHARED_ARRAY_WORD.match(word) else [word]
        calls.append(argv)
    return calls


def aptopts(argv: list[str]) -> list[str]:
    return [a[len("--aptopt="):].rstrip(";") + ";" for a in argv if a.startswith("--aptopt=")]


def mmdebstrap_problems(name: str, text: str, lib: str = "") -> list[str]:
    calls = mmdebstrap_calls(text, lib)
    if not calls:
        return [f"{name}: no mmdebstrap call found"]
    problems = []
    for argv in calls:
        opts = aptopts(argv)
        if retries_on(opts) and DELAY_OFF not in opts:
            problems.append(f"reason=apt_retry_delay_deadlock {name}: mmdebstrap retries without "
                            f"--aptopt '{DELAY_OFF.rstrip(';')}': {opts}")
    return problems


# ---------------------------------------------------------------- 3b. test recipes
def recipe_mmdebstrap_calls(text: str) -> list[list[str]]:
    """mmdebstrap commands inside a recipe's RUN lines, up to the next ; or &&."""
    calls = []
    for line in code_lines(joined(text)):
        for match in re.finditer(r"(?<![\w./-])mmdebstrap\s+((?:[^;&']|'[^']*'|&(?!&))*)", line):
            calls.append(["mmdebstrap"] + shlex.split(match.group(1)))
    return calls


def recipe_problems(name: str, text: str) -> list[str]:
    stages = parse_stages(text)
    problems = []
    for stage, spec in stages.items():
        first = next((i for i, line in enumerate(spec["lines"]) if retrying_apt(line)), None)
        if first is None:
            continue
        own = [i for i, line in enumerate(spec["lines"]) if line.strip() == DROP_IN_RUN]
        chain, current = [], spec["parent"]
        while current in stages and current not in chain:
            chain.append(current)
            current = stages[current]["parent"]
        inherited = any(any(line.strip() == DROP_IN_RUN for line in stages[s]["lines"]) for s in chain)
        if not inherited and not (own and own[0] < first):
            problems.append(f"reason=apt_retry_delay_deadlock {name} stage {stage}: runs apt with "
                            f"retries before any retry-delay drop-in: {spec['lines'][first].strip()[:100]}")
    for argv in recipe_mmdebstrap_calls(text):
        opts = aptopts(argv)
        if retries_on(opts) and DELAY_OFF not in opts:
            problems.append(f"reason=apt_retry_delay_deadlock {name}: mmdebstrap retries without "
                            f"--aptopt '{DELAY_OFF.rstrip(';')}': {opts}")
    return problems


def fixed_base_problems(name: str, text: str) -> list[str]:
    base, why = FIXED_APT_BASES[name]
    if base not in text.splitlines():
        return [f"reason=apt_retry_delay_deadlock {name}: its base is no longer `{base}` ({why}); "
                "read the new base's apt version and add the recipe to TEST_RECIPES if it lacks "
                "the LP #2003851 fix"]
    return []


def all_problems(texts: dict[str, str]) -> list[str]:
    problems = container_problems(texts["build/Dockerfile"])
    problems += pf_problems(texts["build/Dockerfile.pf"])
    for name in MMDEBSTRAP_SCRIPTS:
        problems += mmdebstrap_problems(name, texts[name], texts[SHARED_OPTS_LIB])
    for name in TEST_RECIPES:
        problems += recipe_problems(name, texts[name])
    for name in FIXED_APT_BASES:
        problems += fixed_base_problems(name, texts[name])
    return problems


TEXTS = {name: (ROOT / name).read_text(encoding="utf-8")
         for name in ("build/Dockerfile", "build/Dockerfile.pf", SHARED_OPTS_LIB) + MMDEBSTRAP_SCRIPTS
         + TEST_RECIPES + tuple(FIXED_APT_BASES)}
problems = all_problems(TEXTS)
if problems:
    fail("\n  ".join(problems))
ok("the build container's persisted snippet, every apt stage of Dockerfile.pf and of the "
   "test recipes, and every mmdebstrap call retry with Acquire::Retries::Delay \"false\"")

# ---------------------------------------------------------------- 4. red controls
DELAY_ITEM = "'Acquire::Retries::Delay \"false\";' \\\n"
controls = {
    "container snippet without the delay line": ("build/Dockerfile", lambda t: re.sub(
        r"^\s*" + re.escape(DELAY_ITEM), "", t, count=1, flags=re.M)),
    "container snippet with the delay on": ("build/Dockerfile", lambda t: t.replace(
        DELAY_ITEM, "'Acquire::Retries::Delay \"true\";' \\\n", 1)),
    "the shared a133 rootfs aptopts without the delay": (SHARED_OPTS_LIB, lambda t: re.sub(
        r"^\s*--aptopt='Acquire::Retries::Delay \"false\"'\n", "", t, count=1, flags=re.M)),
    "the a523 mmdebstrap call without the delay aptopt": ("scripts/build-rootfs-a523.sh", lambda t: re.sub(
        r"^\s*--aptopt='Acquire::Retries::Delay \"false\"' \\\n", "", t, count=1, flags=re.M)),
    "the app-root mmdebstrap call without the delay aptopt": ("scripts/build-debian-app-root.sh", lambda t: re.sub(
        r"^\s*--aptopt='Acquire::Retries::Delay \"false\";' \\\n", "", t, count=1, flags=re.M)),
}
for name in ROOT_STAGES:
    controls[f"{name} without its drop-in"] = ("build/Dockerfile.pf", (
        lambda stage: lambda t: drop_stage_drop_in(t, stage))(name))
controls["pf-build-base drop-in after its first retrying apt run"] = (
    "build/Dockerfile.pf", lambda t: move_base_drop_in_late(t))
for name in TEST_RECIPES:
    controls[f"{name} without its drop-in"] = (name, (
        lambda t: t.replace(DROP_IN_RUN + "\n", "", 1)))
controls["the session-authority drop-in after its apt run"] = (
    "tests/session-authority-systemd/Containerfile", lambda t: move_drop_in_after_apt(t))
controls["a guest-payload mmdebstrap call without the delay aptopt"] = (
    "tests/input-harness/Containerfile.guest-payload", lambda t: t.replace(
        " --aptopt='Acquire::Retries::Delay \"false\"'", "", 1))
controls["the input harness on a base without the apt fix"] = (
    "tests/input-harness/Containerfile", lambda t: t.replace(
        FIXED_APT_BASES["tests/input-harness/Containerfile"][0],
        "ARG BASE_IMAGE=debian@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171", 1))


def stage_span(text: str, stage: str) -> tuple[int, int]:
    match = re.search(rf"^FROM\s+\S+\s+AS\s+{re.escape(stage)}\s*$", text, re.M)
    if not match:
        return (0, 0)
    nxt = re.compile(r"^FROM\s", re.M).search(text, match.end())
    return (match.start(), nxt.start() if nxt else len(text))


def drop_stage_drop_in(text: str, stage: str) -> str:
    start, end = stage_span(text, stage)
    block = text[start:end].replace(DROP_IN_RUN + "\n", "", 1)
    return text[:start] + block + text[end:]


def move_base_drop_in_late(text: str) -> str:
    start, end = stage_span(text, "pf-build-base")
    block = text[start:end]
    if DROP_IN_RUN + "\n" not in block:
        return text
    block = block.replace(DROP_IN_RUN + "\n", "", 1).rstrip("\n") + "\n" + DROP_IN_RUN + "\n\n"
    return text[:start] + block + text[end:]


def move_drop_in_after_apt(text: str) -> str:
    """The drop-in moved to just after the RUN that starts with apt-get update."""
    lines = text.splitlines(keepends=True)
    if DROP_IN_RUN + "\n" not in lines:
        return text
    lines.remove(DROP_IN_RUN + "\n")
    start = next((i for i, line in enumerate(lines) if line.startswith("RUN apt-get update")), None)
    if start is None:
        return text
    end = start
    while lines[end].rstrip("\n").endswith("\\"):
        end += 1
    lines.insert(end + 1, DROP_IN_RUN + "\n")
    return "".join(lines)


for label, (name, mutate) in controls.items():
    mutated = dict(TEXTS)
    mutated[name] = mutate(TEXTS[name])
    if mutated[name] == TEXTS[name]:
        fail(f"red control '{label}' did not change {name}")
    if not all_problems(mutated):
        fail(f"red control '{label}': the static contract accepted it")
ok(f"the static contract refuses {len(controls)} retry-delay regressions (red controls)")


# ---------------------------------------------------------------- 5. live replay
def apt_has_retry_deadlock() -> bool:
    version = subprocess.run(["dpkg-query", "-W", "-f=${Version}", "apt"], capture_output=True,
                             text=True).stdout.strip()
    if not version:
        return True

    def lt(a: str, b: str) -> bool:
        return subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0
    return lt(version, "3.0.3") or (not lt(version, "3.1~") and lt(version, "3.1.10"))


def build_repo(top: Path, arch: str) -> None:
    for suite in SUITES:
        index = top / "dists" / suite / "main" / f"binary-{arch}"
        index.mkdir(parents=True)
        packages = (f"Package: pf-{suite}\nVersion: 1\nArchitecture: all\n"
                    "Maintainer: test <test@example.invalid>\n"
                    f"Filename: pool/pf-{suite}_1_all.deb\nSize: 1\nSHA256: {'0' * 64}\n"
                    "Description: fixture\n\n").encode()
        (index / "Packages").write_bytes(packages)
        (top / "dists" / suite / "Release").write_text(
            f"Origin: pf\nLabel: pf\nSuite: {suite}\nCodename: {suite}\n"
            f"Date: Thu, 01 Jan 2026 00:00:00 UTC\nArchitectures: {arch}\nComponents: main\n"
            f"SHA256:\n {hashlib.sha256(packages).hexdigest()} {len(packages)} "
            f"main/binary-{arch}/Packages\n", encoding="ascii")


def serve(top: Path) -> ThreadingHTTPServer:
    pending = set(CUT_ONCE)
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            rel = os.path.normpath(self.path.split("?", 1)[0]).lstrip("/")
            with lock:
                cut = rel in pending
                pending.discard(rel)
            path = top / rel
            if not path.is_file():
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if cut:
                # Headers, then a closed connection: the acng `O 290` answer.
                self.wfile.flush()
                self.close_connection = True
                try:
                    self.connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                return
            self.wfile.write(body)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.pending = pending
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def replay(parts: dict[str, str], limit: int) -> tuple[str, str]:
    """apt-get update with the given apt.conf.d parts against the cut-once origin.
    Returns ("ok"|"stuck"|"failed", detail)."""
    arch = subprocess.run(["dpkg", "--print-architecture"], check=True, capture_output=True,
                          text=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="apt-retry-delay.") as raw:
        tmp = Path(raw)
        build_repo(tmp / "repo", arch)
        server = serve(tmp / "repo")
        try:
            for d in ("etc/apt.conf.d", "etc/sources.list.d", "etc/preferences.d",
                      "state/lists/partial", "cache/archives/partial"):
                (tmp / d).mkdir(parents=True)
            for name, body in parts.items():
                (tmp / "etc" / "apt.conf.d" / name).write_text(body)
            port = server.server_address[1]
            (tmp / "etc" / "sources.list").write_text("".join(
                f"deb [trusted=yes] http://127.0.0.1:{port}/ {s} main\n" for s in SUITES))
            # Unprivileged: no lock, no sandbox user, the host's dpkg status (read only).
            (tmp / "apt.conf").write_text(
                f'Dir::Etc "{tmp}/etc";\nDir::Etc::main "apt.conf";\n'
                'Dir::Etc::parts "apt.conf.d";\nDir::Etc::sourcelist "sources.list";\n'
                'Dir::Etc::sourceparts "sources.list.d";\n'
                'Dir::Etc::preferencesparts "preferences.d";\n'
                f'Dir::State "{tmp}/state";\nDir::State::status "/var/lib/dpkg/status";\n'
                f'Dir::Cache "{tmp}/cache";\nDebug::NoLocking "true";\n'
                'APT::Sandbox::User "";\nAcquire::Languages "none";\n')
            env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp), "APT_CONFIG": str(tmp / "apt.conf")}
            try:
                run = subprocess.run(["apt-get", "update"], env=env, capture_output=True,
                                     text=True, timeout=limit)
            except subprocess.TimeoutExpired:
                return ("stuck" if not server.pending else "failed",
                        f"no progress for {limit} s, uninjected cuts {sorted(server.pending)}")
            lists = sorted(p.name for p in (tmp / "state" / "lists").glob("*_Packages"))
            if run.returncode != 0 or server.pending or len(lists) != len(SUITES):
                return ("failed", f"rc={run.returncode} uninjected={sorted(server.pending)} "
                                  f"indexes={lists}\n{run.stdout[-1500:]}{run.stderr[-500:]}")
            return ("ok", "")
        finally:
            server.shutdown()
            server.server_close()


def sanitize(opts: list[str]) -> str:
    # The replay runs unprivileged: the rootfs builders' Sandbox::User "root" stays out.
    return "".join(o + "\n" for o in opts if not o.startswith("APT::Sandbox::"))


if not (shutil.which("apt-get") and shutil.which("dpkg") and shutil.which("dpkg-query")
        and Path("/var/lib/dpkg/status").is_file()):
    print("skip - live replay: apt-get/dpkg not on this host")
else:
    container = "".join(i + "\n" for i in container_snippet(TEXTS["build/Dockerfile"]))
    drop_in = DELAY_OFF + "\n"
    paths = {
        # What a pf-build-base stage (wpa, sdl, cloud-init, ...) runs with today: the pinned
        # container's snippet, plus the drop-in.
        "pf-build-base on the pinned container": {"99-pocketforge-snapshot": PINNED_CONTAINER_SNIPPET,
                                                  DROP_IN_NAME: drop_in},
        "pf-build-base on a rebuilt container": {"99-pocketforge-snapshot": container,
                                                 DROP_IN_NAME: drop_in},
        "a rebuilt container alone": {"99-pocketforge-snapshot": container},
        "gpu-um-toolchain / poolsuite-toolchain (default retries)": {DROP_IN_NAME: drop_in},
    }
    for name in MMDEBSTRAP_SCRIPTS:
        for index, argv in enumerate(mmdebstrap_calls(TEXTS[name], TEXTS[SHARED_OPTS_LIB])):
            paths[f"{name} mmdebstrap call {index + 1}"] = {"99mmdebstrap": sanitize(aptopts(argv))}
    # The test recipes' apt stages run on the pinned container (guest payload) or on
    # bookworm's defaults (session authority): covered above. Their mmdebstrap calls:
    for name in TEST_RECIPES:
        for index, argv in enumerate(recipe_mmdebstrap_calls(TEXTS[name])):
            paths[f"{name} mmdebstrap call {index + 1}"] = {"99mmdebstrap": sanitize(aptopts(argv))}
    for label, parts in paths.items():
        state, detail = replay(parts, LIVE_TIMEOUT_S)
        if state != "ok":
            fail(f"reason=apt_retry_delay_deadlock {label}: apt-get update did not get through two "
                 f"truncated Release answers ({state}): {detail}")
    ok(f"live: {len(paths)} apt configs carry apt-get update through two truncated Release answers")
    if not apt_has_retry_deadlock():
        print("skip - red control: this host's apt carries the LP #2003851 fix")
    else:
        state, detail = replay({"99-pocketforge-snapshot": PINNED_CONTAINER_SNIPPET}, CONTROL_TIMEOUT_S)
        if state != "stuck":
            fail(f"red control: the pinned container's snippet alone was not stuck ({state}: {detail}), "
                 "so the replay proves nothing")
        ok(f"live red control: the pinned container's snippet alone (the wpa stall) is still stuck "
           f"after {CONTROL_TIMEOUT_S} s")

print(f"apt-retry-delay=PASS checks={passed}")
