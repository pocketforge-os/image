#!/usr/bin/env python3
"""The open-GPU gate waits for its own device, never for udev-settle (bd tsp-3rd3.18).

pf-open-gpu-gate.service used to Want, and order itself After,
systemd-udev-settle.service. The stock settle unit is Before=sysinit.target, so
pulling it into the boot made sysinit.target, basic.target and every
default-dependency service wait for EVERY coldplug udev event. That includes
pf-shell-selected (MainUI). tsp-3rd3.16 measured one such event, a 6.6 s XR829
firmware upload, holding MainUI on 11 of 11 boots. The gate needs only its
render node, so it waits on that device unit, bounded, and names the failure.

Phases (all run; every failure is reported):
  static       unit and build-script contract.
  transaction  the REAL boot transaction. It runs `systemd --test --system`,
               which executes nothing and needs no root, over the overlay units,
               the host's verbatim stock systemd-udev-settle/-trigger units, and
               a synthetic consumer of a slow udev device. It runs in an
               unprivileged bwrap view with an empty /sys and /run, so no host
               device leaks into the transaction. It checks three things:
                 - no settle job;
                 - pf-shell-selected waits on no device but fb0 and the render
                   node;
                 - a slow udev event (120 s) does not move pf-shell-selected's
                   start.
  bound        the render-node wait is bounded by a drop-in in exactly the form
               systemd-fstab-generator writes for the image's own /boot entry.
               The real parser loads it without complaint, checked against a
               positive control in the same run.
  absent       the production gate script runs in an unprivileged bwrap view
               where powervr is "loaded" and there is no /dev/dri. It must fail
               by name, promptly. A control run without powervr must name that
               instead.

Usage: tests/test-open-gpu-gate-ordering.sh [--ref GIT_REF] [--keep]
--ref reads units, the gate script and the builder from a git ref, for example
`--ref origin/main` for the red-before-fix evidence. Exit status: 0 PASS,
1 FAIL, 75 BLOCKED. BLOCKED means a required tool is missing, and it is never
reported as PASS.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[1]
UNIT_DIR = "rootfs-overlay/etc/systemd/system"
BUILDER = "scripts/build-rootfs.sh"
GATE_SCRIPT = "rootfs-overlay/usr/lib/pocketforge/open-gpu-gate.sh"
DRM_RULE = "rootfs-overlay/etc/udev/rules.d/70-pocketforge-drm-systemd.rules"

GATE = "pf-open-gpu-gate.service"
SHELL = "pf-shell-selected.service"
ANIM = "pocketforge-boot-animator.service"
SETTLE = "systemd-udev-settle.service"
TRIGGER = "systemd-udev-trigger.service"
RENDER_DEV = "dev-dri-renderD128.device"
FB_DEV = "dev-fb0.device"
BOUND_DROPIN = f"{RENDER_DEV}.d/50-pocketforge-device-timeout.conf"
REQUIRED_DROPIN = ("pf-open-gpu-required.conf", "20-open-gpu-required.conf")

# The synthetic slow udev event: a device some other unit consumes.
SLOW_DEV = "dev-pftestslow.device"
SLOW_CONSUMER = "pf-test-slow-udev-consumer.service"
# Positive control for the parser-warning check, in the same systemd run: a
# misspelled key that systemd must report.
PARSER_CONTROL = f"{SLOW_DEV}.d/99-parser-control.conf"

# Measured, not chosen. On all 11 B6/B7 open-7x boots the render-node job
# started at k7.49-7.72 (`Expecting device dev-dri-renderD128.device`). The
# worst `Found device` came 9.87 s later: B7 B4, 7.490218 -> 17.358229, in
# /home/matt/recovery/tsp-3rd3.14-b7/runs/B4/journal.txt. That worst boot
# includes the ones where the XR829 upload held the render node (tsp-3rd3.16).
WORST_RENDER_NODE_S = 9.87
# systemd's default device job timeout, which applied before this bead:
# `Job dev-dri-renderD128.device/start running (9s / 1min 30s)`.
DEFAULT_DEVICE_TIMEOUT_S = 90.0
# The GPU-absent gate run must fail by name well inside this.
ABSENT_FAIL_WITHIN_S = 5.0

# Transaction model: overlay files an open-GPU display image with the shell
# owner installs (scripts/build-rootfs.sh), copied byte for byte.
REAL_FILES = [
    GATE,
    SHELL,
    f"{SHELL}.d/10-input-broker.conf",
    ANIM,
    "pocketforge-foreground.target",
    "pocketforge-foreground.target.d/10-owner-shell.conf",
    "pocketforge-splash-handoff.target",
    "pocketforge-menu.service",
    "pocketforge-placeholder.service",
]
# These builder lines create the links modelled below. If any of them
# disappears, the model is stale and the test refuses to run.
BUILDER_NEEDLES = [
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-open-gpu-gate.service"',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-shell-selected.service"',
    '"${ROOTFS}/etc/systemd/system/basic.target.wants/pocketforge-boot-animator.service"',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-input-decode.service"',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-prefsd.service"',
    'for ui_unit in pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service; do',
    '"${dropin}/20-open-gpu-required.conf"',
]
WANTS = {
    "basic.target": [ANIM],
    "multi-user.target": [GATE, SHELL, "pf-input-decode.service", "pf-prefsd.service", SLOW_CONSUMER],
}
# Stand-ins for the targets, with the same ordering shape as the stock units.
STANDIN_TARGETS = {
    "local-fs.target": "[Unit]\nDefaultDependencies=no\n",
    "sysinit.target": "[Unit]\nDefaultDependencies=no\nWants=local-fs.target\nAfter=local-fs.target\n",
    "basic.target": "[Unit]\nDefaultDependencies=no\nRequires=sysinit.target\nAfter=sysinit.target\n",
    "multi-user.target": "[Unit]\nRequires=basic.target\nAfter=basic.target\nAllowIsolate=yes\n",
    "shutdown.target": "[Unit]\nDefaultDependencies=no\nRefuseManualStart=yes\n",
}
# Runtime-repo units get stand-ins with the runtime units' ordering (After=local-fs.target).
STANDIN_SERVICES = {
    "pf-input-decode.service": "[Unit]\nAfter=local-fs.target\n[Service]\nExecStart=/bin/true\n",
    "pf-prefsd.service": "[Unit]\nAfter=local-fs.target\n[Service]\nExecStart=/bin/true\n",
    SLOW_CONSUMER: (f"[Unit]\nWants={SLOW_DEV}\nAfter={SLOW_DEV}\n"
                    "[Service]\nType=oneshot\nExecStart=/bin/true\n"),
}
STOCK_UNITS = [SETTLE, TRIGGER]
STOCK_DIRS = ["/usr/lib/systemd/system", "/lib/systemd/system"]
GENERATOR_DIRS = ["/usr/lib/systemd/system-generators", "/lib/systemd/system-generators"]

# Synthetic completion times, in seconds from the start of the transaction.
# The slow udev event holds `udevadm settle` for as long as it takes.
SLOW_S = 120.0
DURATIONS = {SLOW_DEV: SLOW_S, SETTLE: SLOW_S, RENDER_DEV: 3.0, FB_DEV: 2.0, GATE: 1.0}

DEP_KEYS = ("Wants", "Requires", "Requisite", "BindsTo", "PartOf", "Upholds", "After", "Before")
BLOCKED = 75


class Blocked(Exception):
    pass


class Failed(AssertionError):
    pass


class Source:
    """Unit files, scripts and the builder, from the work tree or from a git ref."""

    def __init__(self, ref: str | None):
        self.ref = ref
        if ref:
            sha = subprocess.run(["git", "-C", str(REPO), "rev-parse", "--verify", f"{ref}^{{commit}}"],
                                 capture_output=True, text=True)
            if sha.returncode:
                raise Blocked(f"unknown git ref {ref}")
            self.label = f"{ref}@{sha.stdout.strip()[:12]}"
        else:
            self.label = "work-tree"

    def read(self, rel: str) -> str | None:
        if self.ref:
            r = subprocess.run(["git", "-C", str(REPO), "show", f"{self.ref}:{rel}"],
                               capture_output=True, text=True)
            return None if r.returncode else r.stdout
        path = REPO / rel
        return path.read_text() if path.is_file() else None

    def need(self, rel: str) -> str:
        text = self.read(rel)
        if text is None:
            raise Failed(f"{rel} missing in {self.label}")
        return text

    def unit(self, rel: str) -> str | None:
        return self.read(f"{UNIT_DIR}/{rel}")

    def unit_files(self) -> list[str]:
        """Every file under the overlay unit dir, relative to it."""
        if self.ref:
            r = subprocess.run(["git", "-C", str(REPO), "ls-tree", "-r", "--name-only", self.ref, "--", UNIT_DIR],
                               capture_output=True, text=True, check=True)
            return [p[len(UNIT_DIR) + 1:] for p in r.stdout.splitlines()]
        base = REPO / UNIT_DIR
        return sorted(str(p.relative_to(base)) for p in base.rglob("*") if p.is_file())


def check(cond, msg):
    if not cond:
        raise Failed(msg)


def directives(text: str) -> list[tuple[str, str, str]]:
    """(section, key, value) for every assignment, in file order."""
    out, section = [], ""
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith(("#", ";")):
            continue
        if s.startswith("[") and s.endswith("]"):
            section = s[1:-1]
            continue
        if "=" in s:
            k, v = s.split("=", 1)
            out.append((section, k.strip(), v.strip()))
    return out


def dep_units(text: str, key: str) -> set[str]:
    return {u for sec, k, v in directives(text) if k == key for u in v.split()}


def timespan_s(value: str) -> float:
    """The subset of systemd.time(7) timespans a drop-in here may use."""
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*(ms|s|sec|min|m)?", value.strip())
    if not m:
        raise Failed(f"unparsed timespan {value!r}")
    n, unit = float(m.group(1)), m.group(2) or "s"
    return n / 1000 if unit == "ms" else n * 60 if unit in ("min", "m") else n


def blocks(builder: str, start_line: str) -> list[str]:
    """The text of every top-level `if` block that opens with exactly start_line."""
    lines = builder.splitlines()
    found = []
    for i, first in enumerate(lines):
        if first != start_line:
            continue
        depth, out = 0, []
        for line in lines[i:]:
            out.append(line)
            if re.match(r"^\s*if\b", line) and not re.search(r"\bfi\s*$", line):
                depth += 1
            elif re.match(r"^\s*fi\b", line):
                depth -= 1
                if depth == 0:
                    found.append("\n".join(out))
                    break
        else:
            raise Failed(f"{BUILDER}: block `{start_line}` at line {i + 1} not terminated")
    check(found, f"{BUILDER}: no block `{start_line}`")
    return found


# ---- static -----------------------------------------------------------------------

def phase_static(src: Source) -> list[str]:
    notes = []
    gate = src.unit(GATE)
    check(gate is not None, f"{GATE} missing")
    settle_lines = [ln for ln in gate.splitlines()
                    if SETTLE in ln and not ln.strip().startswith(("#", ";"))]
    check(not settle_lines, f"{GATE} still references {SETTLE}: {settle_lines}")
    check(RENDER_DEV in dep_units(gate, "Wants"), f"{GATE} does not Want {RENDER_DEV}")
    after = dep_units(gate, "After")
    check(after == {RENDER_DEV}, f"{GATE} After= must be exactly {RENDER_DEV}, got {sorted(after)}")
    for hard in ("Requires", "BindsTo", "Requisite"):
        check(RENDER_DEV not in dep_units(gate, hard),
              f"{GATE} {hard}={RENDER_DEV}: a timed-out device job would cancel the gate "
              "instead of letting it name the failure")
    notes.append(f"gate waits only on {RENDER_DEV} (Wants+After), no {SETTLE}")

    rule = src.need(DRM_RULE)
    check('SUBSYSTEM=="drm", KERNEL=="renderD*", TAG+="systemd"' in rule.splitlines(),
          f"{DRM_RULE} no longer tags render nodes for systemd, so {RENDER_DEV} would never appear")

    dropin = src.unit(BOUND_DROPIN)
    check(dropin is not None, f"{UNIT_DIR}/{BOUND_DROPIN} missing: the render-node wait is unbounded "
          f"(systemd default {DEFAULT_DEVICE_TIMEOUT_S:.0f}s)")
    d = directives(dropin)
    check([(s, k) for s, k, _ in d] == [("Unit", "JobRunningTimeoutSec")],
          f"{BOUND_DROPIN} must hold exactly [Unit] JobRunningTimeoutSec=, got {d}")
    bound = timespan_s(d[0][2])
    check(3 * WORST_RENDER_NODE_S <= bound < DEFAULT_DEVICE_TIMEOUT_S,
          f"render-node bound {bound}s must be >= 3x the worst observed {WORST_RENDER_NODE_S}s "
          f"and below the {DEFAULT_DEVICE_TIMEOUT_S:.0f}s default")
    notes.append(f"render-node job bound {bound:g}s (worst observed {WORST_RENDER_NODE_S}s, "
                 f"default {DEFAULT_DEVICE_TIMEOUT_S:.0f}s)")

    gate_timeout = [timespan_s(v) for s, k, v in directives(gate) if k == "TimeoutStartSec"]
    script = src.need(GATE_SCRIPT)
    probe = re.search(r'timeout (\d+)s "\$probe"', script)
    check(probe and gate_timeout and int(probe.group(1)) < gate_timeout[-1],
          "the gate's probe timeout must sit inside its TimeoutStartSec")

    builder = src.need(BUILDER)
    # The open-model block that installs the gate must install its bound too.
    gate_install = f'"/work/src/{UNIT_DIR}/{GATE}"'
    gate_blocks = [b for b in blocks(builder, 'if [ "${PF_GPU_MODEL}" = "open" ]; then') if gate_install in b]
    check(len(gate_blocks) == 1, f"{BUILDER}: expected one open-model block installing {GATE}")
    open_block = gate_blocks[0]
    install = f'"/work/src/{UNIT_DIR}/{BOUND_DROPIN}"'
    check(install in open_block, f"{BUILDER} does not install {BOUND_DROPIN} in the gate's open-model block")
    check(builder.count(install) == open_block.count(install),
          f"{BUILDER} installs {BOUND_DROPIN} outside the gate's open-model block")
    check(f'"${{ROOTFS}}/etc/systemd/system/{BOUND_DROPIN}"' in open_block,
          f"{BUILDER} installs {BOUND_DROPIN} under the wrong rootfs path")

    # Settle pullers. The one legacy puller is scoped to a GPU-less, display-less
    # profile that installs no gate and no MainUI. Any new puller fails here.
    pullers = {}
    for rel in src.unit_files():
        text = src.unit(rel) or ""
        for sec, k, v in directives(text):
            if k in DEP_KEYS and k != "Before" and SETTLE in v.split():
                pullers.setdefault(rel, []).append(k)
    allowed = {"pocketforge-xr829-hciattach.service"}
    check(set(pullers) <= allowed, f"units pulling in {SETTLE}: {pullers} (allowed: {sorted(allowed)})")
    bt_blocks = "\n".join(blocks(builder, 'if [ "${PF_DEVICE_ID}" = "a133-open-7x" ]; then'))
    bt_install = '"${ROOTFS}/etc/systemd/system/pocketforge-xr829-hciattach.service"'
    check(bt_install in bt_blocks and builder.count(bt_install) == bt_blocks.count(bt_install),
          "pocketforge-xr829-hciattach.service must stay confined to the a133-open-7x profile")
    gpu_ids = re.search(r"is_a133_open_7x_gpu_device\(\) \{\n\s*case \"\$1\" in\n\s*([^)]*)\)", builder)
    check(gpu_ids and "a133-open-7x" not in gpu_ids.group(1).split("|"),
          "the a133-open-7x (hciattach) profile must not be an open-GPU device id")
    notes.append(f"{SETTLE} pullers in the overlay: {sorted(pullers) or 'none'} (a133-open-7x only)")
    return notes


# ---- sandbox helpers ------------------------------------------------------------------

def bwrap() -> str:
    b = shutil.which("bwrap")
    if not b:
        raise Blocked("bwrap not installed")
    return b


def systemd_binary() -> str:
    for cand in (os.environ.get("PF_TEST_SYSTEMD", ""), "/usr/lib/systemd/systemd", "/lib/systemd/systemd"):
        if cand and os.access(cand, os.X_OK):
            return cand
    raise Blocked("no systemd binary for --test")


def empty_sys_view(work: Path) -> list[str]:
    """An unprivileged view of the host: read-only root, empty /sys, /run and /tmp.
    systemd needs only the cgroup mount from /sys; nothing else there leaks in."""
    return [bwrap(), "--ro-bind", "/", "/", "--tmpfs", "/sys", "--ro-bind", "/sys/fs/cgroup", "/sys/fs/cgroup",
            "--tmpfs", "/run", "--tmpfs", "/tmp", "--tmpfs", "/var/tmp", "--dev", "/dev", "--proc", "/proc",
            "--bind", str(work), str(work)]


# ---- transaction --------------------------------------------------------------------------

def stock_unit(name: str) -> str:
    for d in STOCK_DIRS:
        p = Path(d) / name
        if p.is_file():
            return p.read_text()
    raise Blocked(f"host has no stock {name} to model the boot with")


def write_tree(tree: Path, files: dict[str, str], wants: dict[str, list[str]]):
    for rel, text in files.items():
        (tree / rel).parent.mkdir(parents=True, exist_ok=True)
        (tree / rel).write_text(text)
    for target, units in wants.items():
        wdir = tree / f"{target}.wants"
        wdir.mkdir(exist_ok=True)
        for u in units:
            (wdir / u).symlink_to(f"../{u}")


def parse_dump(out: str) -> tuple[set[str], dict[str, dict[str, set[str]]], dict[str, list[str]]]:
    """(units with a start job, {unit: {dep key: units}}, {unit: drop-in paths})."""
    head, sep, jobs_dump = out.partition("-> By jobs:")
    if not sep:
        raise Blocked("systemd --test printed no job dump")
    jobs = {u for u, t in re.findall(r"Action: (\S+) -> (\w+)", jobs_dump) if t == "start"}
    deps: dict[str, dict[str, set[str]]] = {}
    dropins: dict[str, list[str]] = {}
    unit = None
    for line in head.splitlines():
        m = re.match(r"^\t-> Unit (.+):$", line)
        if m:
            unit = m.group(1)
            deps[unit] = {}
            dropins[unit] = []
            continue
        if unit is None:
            continue
        m = re.match(r"^\t\t(\w+): (\S+)(?: \(.*\))?$", line)
        if m and m.group(1) in DEP_KEYS:
            deps[unit].setdefault(m.group(1), set()).add(m.group(2))
        m = re.match(r"^\t\tDropIn Path: (.+)$", line)
        if m:
            dropins[unit].append(m.group(1))
    return jobs, deps, dropins


def wait_closure(unit: str, jobs: set[str], deps) -> set[str]:
    """Every job `unit`'s start job transitively waits for (After= edges between jobs)."""
    seen, stack = set(), [unit]
    while stack:
        for x in deps.get(stack.pop(), {}).get("After", ()):
            if x in jobs and x not in seen:
                seen.add(x)
                stack.append(x)
    return seen


def earliest_start(unit: str, jobs: set[str], deps) -> float:
    memo: dict[str, float] = {}

    def start(u: str, path: tuple[str, ...]) -> float:
        if u in memo:
            return memo[u]
        if u in path:
            raise Failed(f"ordering cycle through {u}")
        preds = [x for x in deps.get(u, {}).get("After", ()) if x in jobs]
        memo[u] = max((start(x, path + (u,)) + DURATIONS.get(x, 0.0) for x in preds), default=0.0)
        return memo[u]

    return start(unit, ())


def phase_transaction(src: Source, work: Path) -> list[str]:
    builder = src.need(BUILDER)
    missing = [n for n in BUILDER_NEEDLES if n not in builder]
    check(not missing, f"{BUILDER} no longer creates the modelled links: {missing}")
    settle_text = stock_unit(SETTLE)
    if "Before=sysinit.target" not in settle_text.splitlines():
        raise Blocked(f"host {SETTLE} is not Before=sysinit.target; it does not model the stock unit")

    files = {rel: src.need(f"{UNIT_DIR}/{rel}") for rel in REAL_FILES}
    files[f"{SHELL}.d/{REQUIRED_DROPIN[1]}"] = src.need(f"{UNIT_DIR}/{REQUIRED_DROPIN[0]}")
    bound = src.unit(BOUND_DROPIN)
    if bound is not None:
        files[BOUND_DROPIN] = bound
    files.update(STANDIN_TARGETS)
    files.update(STANDIN_SERVICES)
    for name in STOCK_UNITS:
        files[name] = stock_unit(name)
    files[PARSER_CONTROL] = "[Unit]\nJobRunningTimeoutSecc=1s\n"

    tree = work / "txn"
    empty = work / "empty"
    empty.mkdir(exist_ok=True)
    write_tree(tree, files, WANTS)
    env = []
    for k, v in (("SYSTEMD_UNIT_PATH", str(tree)), ("SYSTEMD_GENERATOR_PATH", str(empty)),
                 ("SYSTEMD_ENVIRONMENT_GENERATOR_PATH", str(empty)), ("SYSTEMD_LOG_LEVEL", "debug"),
                 ("SYSTEMD_LOG_TARGET", "console"), ("SYSTEMD_LOG_COLOR", "0")):
        env += ["--setenv", k, v]
    binary = systemd_binary()
    version = subprocess.run([binary, "--version"], capture_output=True, text=True).stdout.split("\n")[0].strip()
    r = subprocess.run(empty_sys_view(work) + env +
                       [binary, "--test", "--system", "--unit=multi-user.target", "--no-pager"],
                       capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    (work / "txn.log").write_text(out)
    if r.returncode != 0:
        raise Blocked(f"systemd --test failed (rc={r.returncode}); log {work / 'txn.log'}")
    check("Trying to enqueue job multi-user.target/start/isolate" in out,
          "boot transaction was not an isolate of multi-user.target (the boot's job mode)")
    jobs, deps, dropins = parse_dump(out)
    notes = [f"({version}) boot transaction: {len(jobs)} start jobs"]

    # The model has to be able to see what it is asserting about.
    for needed in (GATE, SHELL, RENDER_DEV, FB_DEV, SLOW_DEV):
        check(needed in jobs, f"control: no {needed} start job in the boot transaction")
    gate_deps = deps.get(GATE, {})
    check(RENDER_DEV in gate_deps.get("Wants", set()) and RENDER_DEV in gate_deps.get("After", set()),
          f"real parser: {GATE} lacks Wants+After={RENDER_DEV}")
    for hard in ("Requires", "BindsTo", "Requisite"):
        check(RENDER_DEV not in gate_deps.get(hard, set()), f"real parser: {GATE} {hard}={RENDER_DEV}")

    failures = []
    if SETTLE in jobs:
        failures.append(f"{SETTLE} has a start job in the boot transaction "
                        f"(wanted by {sorted(u for u, d in deps.items() if SETTLE in d.get('Wants', ()))})")
    closure = wait_closure(SHELL, jobs, deps)
    if SETTLE in closure:
        failures.append(f"{SHELL} waits for {SETTLE}")
    waited_devices = sorted(u for u in closure if u.endswith(".device"))
    if waited_devices != sorted({FB_DEV, RENDER_DEV}):
        failures.append(f"{SHELL} waits for devices {waited_devices}, expected only {FB_DEV} and {RENDER_DEV}")
    t_shell = earliest_start(SHELL, jobs, deps)
    ceiling = DURATIONS[RENDER_DEV] + DURATIONS[GATE]
    if t_shell > ceiling + 1e-9:
        failures.append(f"with a {SLOW_S:.0f}s udev event, {SHELL} starts at t={t_shell:g}s "
                        f"(ceiling: render node {DURATIONS[RENDER_DEV]:g}s + gate {DURATIONS[GATE]:g}s = {ceiling:g}s)")
    check(not failures, "; ".join(failures))
    notes.append(f"no {SETTLE} job; {SHELL} waits on devices {waited_devices} only")
    notes.append(f"slow udev event ({SLOW_DEV} and settle at {SLOW_S:.0f}s): {SHELL} starts at "
                 f"t={t_shell:g}s <= render node + gate = {ceiling:g}s")

    # The bound drop-in: loaded onto the device unit, and accepted by the parser.
    loaded = [p for p in dropins.get(RENDER_DEV, []) if p.endswith(BOUND_DROPIN)]
    check(loaded, f"real parser: no {BOUND_DROPIN} loaded for {RENDER_DEV} (drop-ins: {dropins.get(RENDER_DEV)})")
    complaint = re.compile(r"(Unknown|Invalid|Failed to parse|ignoring)", re.I)
    control_hits = [ln for ln in out.splitlines() if PARSER_CONTROL.split("/")[-1] in ln and complaint.search(ln)]
    check(control_hits, "positive control: systemd did not report the misspelled key in "
          f"{PARSER_CONTROL}, so a silent parser cannot be ruled out")
    ours = [ln for ln in out.splitlines() if BOUND_DROPIN.split("/")[-1] in ln and complaint.search(ln)]
    check(not ours, f"systemd complained about {BOUND_DROPIN}: {ours}")
    control_msg = control_hits[0].split(PARSER_CONTROL.split("/")[-1], 1)[-1].strip(": ")
    notes.append(f"{BOUND_DROPIN} loaded for {RENDER_DEV} with no parser complaint "
                 f"(same-run control on {PARSER_CONTROL.split('/')[-1]}: {control_msg!r})")
    return notes


# ---- bound ----------------------------------------------------------------------------------

def phase_bound(src: Source, work: Path) -> list[str]:
    """Our drop-in has the form systemd itself uses to bound a device wait. The
    image's /boot fstab entry already runs that path on the device."""
    builder = src.need(BUILDER)
    boot = [ln for ln in builder.splitlines()
            if "x-systemd.device-timeout=" in ln and not ln.lstrip().startswith("#")]
    check(len(boot) == 1, f"expected one fstab line with x-systemd.device-timeout= in {BUILDER}, got {boot}")
    generator = next((str(Path(d) / "systemd-fstab-generator") for d in GENERATOR_DIRS
                      if os.access(Path(d) / "systemd-fstab-generator", os.X_OK)), None)
    if not generator:
        raise Blocked("no systemd-fstab-generator on this host")
    gen = work / "gen"
    for sub in ("normal", "early", "late"):
        (gen / sub).mkdir(parents=True)
    fstab = gen / "fstab"
    fstab.write_text(boot[0].strip() + "\n")
    env = []
    for k, v in (("SYSTEMD_FSTAB", str(fstab)), ("SYSTEMD_PROC_CMDLINE", ""),
                 ("SYSTEMD_IN_INITRD", "0"), ("SYSTEMD_LOG_LEVEL", "info")):
        env += ["--setenv", k, v]
    r = subprocess.run(empty_sys_view(work) + env +
                       [generator, str(gen / "normal"), str(gen / "early"), str(gen / "late")],
                       capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise Blocked(f"systemd-fstab-generator rc={r.returncode}: {r.stderr.strip()}")
    made = sorted(gen.glob("*/*.device.d/*.conf"))
    check(len(made) == 1, f"generator emitted {len(made)} device drop-ins for the /boot line: {made}")
    reference = [(s, k) for s, k, _ in directives(made[0].read_text())]
    ours = src.unit(BOUND_DROPIN)
    check(ours is not None, f"{BOUND_DROPIN} missing")
    check([(s, k) for s, k, _ in directives(ours)] == reference,
          f"{BOUND_DROPIN} form {directives(ours)} differs from systemd's own device bound {reference}")
    return [f"systemd-fstab-generator bounds the image's /boot device as {made[0].parent.name}/"
            f"{made[0].name} {reference}; {BOUND_DROPIN} uses the same form"]


# ---- absent -----------------------------------------------------------------------------------

def run_gate(script: Path, work: Path, powervr_loaded: bool) -> tuple[int, str, str, float]:
    argv = [bwrap(), "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/sys/module"]
    if powervr_loaded:
        argv += ["--dir", "/sys/module/powervr"]
    argv += ["--bind", str(work), str(work), "/bin/sh", str(script)]
    t0 = time.monotonic()
    r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout, r.stderr, time.monotonic() - t0


def phase_absent(src: Source, work: Path) -> list[str]:
    script = work / "open-gpu-gate.sh"
    script.write_text(src.need(GATE_SCRIPT))
    script.chmod(0o755)
    rc, out, err, dt = run_gate(script, work, powervr_loaded=True)
    want = "PF-OPEN-GPU FAIL: /dev/dri/renderD128 is absent"
    check(rc == 1 and err.strip().splitlines()[-1:] == [want] and "PASS" not in out,
          f"GPU absent: rc={rc} stdout={out.strip()!r} stderr={err.strip()!r}, expected rc=1 and {want!r}")
    check(dt < ABSENT_FAIL_WITHIN_S, f"GPU absent: the gate took {dt:.2f}s to fail (limit {ABSENT_FAIL_WITHIN_S}s)")
    crc, _, cerr, _ = run_gate(script, work, powervr_loaded=False)
    control = "PF-OPEN-GPU FAIL: powervr is not loaded"
    check(crc == 1 and cerr.strip().splitlines()[-1:] == [control],
          f"control (no powervr): rc={crc} stderr={cerr.strip()!r}; the sandbox does not control what the gate sees")
    bound = src.unit(BOUND_DROPIN)
    limit = timespan_s(directives(bound)[0][2]) if bound else DEFAULT_DEVICE_TIMEOUT_S
    return [f"GPU absent: {want!r} in {dt:.2f}s (control: {control!r}); named failure at <= "
            f"device-job start + {limit:g}s + {dt:.2f}s (before: + {DEFAULT_DEVICE_TIMEOUT_S:.0f}s)"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ref")
    ap.add_argument("--work", required=True, help="empty scratch directory (the wrapper creates and removes it)")
    args = ap.parse_args()
    work = Path(args.work)
    try:
        src = Source(args.ref)
    except Blocked as e:
        print(f"open-gpu-gate-ordering: BLOCKED: {e}")
        return BLOCKED
    print(f"open-gpu-gate-ordering: source {src.label}")
    failed = blocked = False
    for name, fn in (("static", lambda: phase_static(src)),
                     ("transaction", lambda: phase_transaction(src, work)),
                     ("bound", lambda: phase_bound(src, work)),
                     ("absent", lambda: phase_absent(src, work))):
        try:
            for note in fn():
                print(f"  {name}: PASS {note}")
        except Failed as e:
            failed = True
            print(f"  {name}: FAIL {e}")
        except Blocked as e:
            blocked = True
            print(f"  {name}: BLOCKED {e}")
    verdict = "FAIL" if failed else "BLOCKED" if blocked else "PASS"
    print(f"open-gpu-gate-ordering={verdict}")
    return 1 if failed else BLOCKED if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
