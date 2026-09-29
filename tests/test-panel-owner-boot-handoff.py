#!/usr/bin/env python3
"""Boot handoff between the fb0 boot animator and the panel owner (bd tsp-3rd3.12).

On every display image the boot animator (basic.target.wants) and the panel
owner (multi-user.target.wants: pf-shell-selected, or the menu/placeholder
variant) are started by ONE boot transaction. The owner used to declare
Conflicts=pocketforge-boot-animator.service. That put a conflicting stop job
for the animator into the boot transaction, and systemd resolves such a pair
by deleting the animator's START (transaction.c, delete_one_unmergeable_job),
so the animator never ran. This test proves the fixed contract with real
systemd, for every owner variant the image can build:

  static       `systemd-analyze verify` of the owner and animator units.
  transaction  the REAL system-manager boot transaction: `systemd --test
               --system` over the unmodified overlay units plus the image's
               enablement links. No root; nothing is executed; generators are
               disabled. The animator's and the owner's start jobs must both
               be installed, and no job of either may be deleted.
  live         the same units, renamed into a private namespace and with stub
               executables, run by the invoking user's systemd user manager
               from ONE start of a stand-in multi-user.target (the same
               transaction merge as the boot; never isolate). The stubs hold
               an exclusive flock on a stand-in fb0, so a second writer is
               recorded. From systemd's own ExecMain timestamps: the animator
               starts; it exits on SIGTERM before the owner's ExecStart (one
               writer at every instant); the owner starts promptly, since it
               never waits for the animation, which would otherwise run
               forever. Then a later `start` of the animator while the owner
               holds the panel is a condition skip, and the owner is
               untouched. As a positive control, once the owner stops, the
               animator starts again.

That the real animator HOLDS its last frame on SIGTERM is proven on the
production binary by tests/test-boot-animator.sh (sigterm-hold). Here systemd
must deliver that SIGTERM (not a timeout SIGKILL) before the owner starts.

Usage:
  tests/test-panel-owner-boot-handoff.py [--ref GIT_REF] [--phase P] [--keep]

--ref reads units and the builder from a git ref instead of the work tree.
For example, `--ref origin/main` produces the red-before-fix evidence.
--phase is one of static, transaction, live or all (the default).
Exit status: 0 PASS, 1 FAIL, 75 BLOCKED. BLOCKED means a required systemd
facility is unavailable, and it is never reported as PASS.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True

REPO = Path(__file__).resolve().parents[1]
UNIT_DIR = "rootfs-overlay/etc/systemd/system"
BUILDER = "scripts/build-rootfs.sh"
ANIM = "pocketforge-boot-animator.service"
OWNERS = {
    "shell": "pf-shell-selected.service",
    "menu": "pocketforge-menu.service",
    "placeholder": "pocketforge-placeholder.service",
    "animator": None,               # the animator itself owns the panel
}
OWNER_UNITS = [u for u in OWNERS.values() if u]

# Overlay files an open-GPU display image installs (scripts/build-rootfs.sh),
# copied byte-for-byte. The owner-variant foreground drop-in is added per run.
REAL_FILES = [
    ANIM,
    *OWNER_UNITS,
    "pocketforge-foreground.target",
    "pocketforge-splash-handoff.target",
    "pf-open-gpu-gate.service",
    "pocketforge-recovery.path",
    "pocketforge-recovery.service",
    "pf-shell-selected.service.d/10-input-broker.conf",
    "pf-shell-selected.service.d/50-open-gpu.conf",
    "pocketforge-menu.service.d/50-open-gpu.conf",
]
# build-rootfs.sh installs pf-open-gpu-required.conf as this drop-in on every owner.
GPU_REQUIRED = ("pf-open-gpu-required.conf", "20-open-gpu-required.conf")

# The builder lines that create the links modelled below; if any disappears the
# model is stale and the test refuses to run.
BUILDER_NEEDLES = [
    '"${ROOTFS}/etc/systemd/system/basic.target.wants/pocketforge-boot-animator.service"',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/${PF_PANEL_OWNER_UNIT}"',
    'PF_PANEL_OWNER="shell"',
    'shell)       PF_PANEL_OWNER_UNIT="pf-shell-selected.service" ;;',
    'menu)        PF_PANEL_OWNER_UNIT="pocketforge-menu.service" ;;',
    'placeholder) PF_PANEL_OWNER_UNIT="pocketforge-placeholder.service" ;;',
    'animator)    PF_PANEL_OWNER_UNIT="" ;;',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-open-gpu-gate.service"',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pocketforge-recovery.path"',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-input-decode.service"',
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-prefsd.service"',
    'for ui_unit in pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service; do',
    '"${dropin}/20-open-gpu-required.conf"',
]
COMMON_WANTS = {
    "basic.target": [ANIM],
    "multi-user.target": ["pf-open-gpu-gate.service", "pocketforge-recovery.path",
                          "pf-input-decode.service", "pf-prefsd.service"],
}

# Minimal stand-ins for the distribution units the image units reference, with
# the same dependency shape as Debian 12's (only what orders the owners).
STANDIN_TARGETS = {
    "local-fs.target": "[Unit]\nDefaultDependencies=no\n",
    "sysinit.target": "[Unit]\nDefaultDependencies=no\nWants=local-fs.target\nAfter=local-fs.target\n",
    "basic.target": "[Unit]\nDefaultDependencies=no\nRequires=sysinit.target\nAfter=sysinit.target\n",
    "multi-user.target": "[Unit]\nRequires=basic.target\nAfter=basic.target\nAllowIsolate=yes\n",
    "shutdown.target": "[Unit]\nDefaultDependencies=no\nRefuseManualStart=yes\n",
}
STANDIN_DAEMONS = ["pf-input-decode.service", "pf-prefsd.service"]

DEP_KEYS = ("Requires", "Requisite", "Wants", "BindsTo", "PartOf", "Upholds", "Conflicts",
            "Before", "After", "OnSuccess", "OnFailure", "PropagatesStopTo",
            "StopPropagatedFrom", "Unit")
UNIT_NAME = re.compile(r"^[A-Za-z0-9:_.@\\-]+\.(service|target|device|path|mount|socket|slice|timer)$")

BLOCKED = 75


class Blocked(Exception):
    pass


class Failed(AssertionError):
    pass


def check(cond, msg):
    if not cond:
        raise Failed(msg)


# ---- source -------------------------------------------------------------------

class Source:
    """Unit files and the builder, from the work tree or from a git ref."""

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

    def read(self, rel: str) -> str:
        if self.ref:
            r = subprocess.run(["git", "-C", str(REPO), "show", f"{self.ref}:{rel}"],
                               capture_output=True, text=True)
            if r.returncode:
                raise Failed(f"{rel} missing at {self.ref}")
            return r.stdout
        path = REPO / rel
        check(path.is_file(), f"{rel} missing")
        return path.read_text()

    def unit(self, rel: str) -> str:
        return self.read(f"{UNIT_DIR}/{rel}")


def check_builder(src: Source):
    builder = src.read(BUILDER)
    missing = [n for n in BUILDER_NEEDLES if n not in builder]
    check(not missing, f"{BUILDER} no longer creates the modelled links: {missing}")


def directive_values(text: str, key: str) -> list[str]:
    """Every value of `key` in unit text (all sections), in file order."""
    out = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith(("#", ";")) or "=" not in s:
            continue
        k, v = s.split("=", 1)
        if k.strip() == key:
            out.append(v.strip())
    return out


def model(src: Source, variant: str) -> tuple[dict[str, str], dict[str, list[str]]]:
    """Return ({relative path: text}, {target: [wanted units]}) for one owner variant."""
    files = {rel: src.unit(rel) for rel in REAL_FILES}
    for owner in OWNER_UNITS:
        files[f"{owner}.d/{GPU_REQUIRED[1]}"] = src.unit(GPU_REQUIRED[0])
    files[f"pocketforge-foreground.target.d/10-owner-{variant}.conf"] = \
        src.unit(f"pocketforge-foreground.target.d/10-owner-{variant}.conf")
    wants = {k: list(v) for k, v in COMMON_WANTS.items()}
    if OWNERS[variant]:
        wants["multi-user.target"].append(OWNERS[variant])
    return files, wants


# ---- static -------------------------------------------------------------------

def phase_static(src: Source, work: Path):
    sa = os.environ.get("PF_TEST_SYSTEMD_ANALYZE") or shutil.which("systemd-analyze")
    if not sa:
        raise Blocked("systemd-analyze not installed")
    env = dict(os.environ)
    root = work / "verify-root"
    unit_dir = root / "etc/systemd/system"
    files, _ = model(src, "shell")
    for rel, text in {**files, **STANDIN_TARGETS}.items():
        (unit_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (unit_dir / rel).write_text(text)
    for exe in ("bin/sh", "bin/systemctl", "usr/bin/pf-shell", "opt/pocketforge/bin/pocketforge-boot-animator",
                "opt/pocketforge/bin/pocketforge-menu", "opt/pocketforge/bin/pocketforge-placeholder",
                "opt/pocketforge/bin/pocketforge-recovery-entry", "usr/lib/pocketforge/open-gpu-gate.sh"):
        p = root / exe
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("#!/bin/sh\n")
        p.chmod(0o755)
    (root / "opt/pocketforge/boot-anim/frames").mkdir(parents=True)
    names = [ANIM, *OWNER_UNITS]
    r = subprocess.run([sa, "verify", f"--root={root}", "--man=no",
                        *[f"/etc/systemd/system/{n}" for n in names]],
                       capture_output=True, text=True, env=env)
    out = (r.stdout + r.stderr).strip()
    bad = [ln for ln in out.splitlines() if any(n.split(".")[0] in ln for n in names)]
    check(r.returncode == 0 and not bad, f"systemd-analyze verify: rc={r.returncode}\n{out}")
    version = subprocess.run([sa, "--version"], capture_output=True, text=True,
                             env=env).stdout.split("\n")[0].strip()
    print(f"  static ({version}): systemd-analyze verify clean for {', '.join(names)}")


# ---- transaction ----------------------------------------------------------------

def systemd_binary() -> str:
    """The host's systemd, or PF_TEST_SYSTEMD (e.g. Debian 12's 252 extracted
    from its .deb, with LD_LIBRARY_PATH, to match the device's manager)."""
    for cand in (os.environ.get("PF_TEST_SYSTEMD", ""), "/usr/lib/systemd/systemd",
                 "/lib/systemd/systemd"):
        if cand and os.access(cand, os.X_OK):
            return cand
    raise Blocked("no systemd binary for --test")


def write_tree(unit_dir: Path, files: dict[str, str], wants: dict[str, list[str]], extra: dict[str, str]):
    for rel, text in {**files, **extra}.items():
        (unit_dir / rel).parent.mkdir(parents=True, exist_ok=True)
        (unit_dir / rel).write_text(text)
    for target, units in wants.items():
        wdir = unit_dir / f"{target}.wants"
        wdir.mkdir(exist_ok=True)
        for u in units:
            (wdir / u).symlink_to(f"../{u}")


def phase_transaction(src: Source, work: Path, variant: str) -> str:
    binary = systemd_binary()
    files, wants = model(src, variant)
    tree = work / f"txn-{variant}"
    empty = work / "empty"
    empty.mkdir(exist_ok=True)
    extra = dict(STANDIN_TARGETS)
    for d in STANDIN_DAEMONS:
        extra[d] = "[Service]\nExecStart=/bin/true\n"
    write_tree(tree, files, wants, extra)
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "SYSTEMD_UNIT_PATH": str(tree),
        "SYSTEMD_GENERATOR_PATH": str(empty),
        "SYSTEMD_ENVIRONMENT_GENERATOR_PATH": str(empty),
        "SYSTEMD_LOG_LEVEL": "debug",
        "SYSTEMD_LOG_TARGET": "console",
        "SYSTEMD_LOG_COLOR": "0",
    }
    if os.environ.get("LD_LIBRARY_PATH"):
        env["LD_LIBRARY_PATH"] = os.environ["LD_LIBRARY_PATH"]
    version = subprocess.run([binary, "--version"], env=env, capture_output=True,
                             text=True).stdout.split("\n")[0].strip()
    r = subprocess.run([binary, "--test", "--system", "--unit=multi-user.target", "--no-pager"],
                       env=env, capture_output=True, text=True, timeout=120)
    out = r.stdout + r.stderr
    (work / f"txn-{variant}.log").write_text(out)
    if r.returncode != 0 or "-> By jobs:" not in out:
        raise Blocked(f"systemd --test did not dump a transaction (rc={r.returncode}); "
                      f"log {work / f'txn-{variant}.log'}")
    check("Trying to enqueue job multi-user.target/start/isolate" in out,
          "boot transaction was not an isolate of multi-user.target (the boot's job mode)")
    ours = {ANIM, *OWNER_UNITS}
    deleted = []
    for m in re.finditer(r"Fixing conflicting jobs (\S+),(\S+) by deleting job (\S+)/(\w+)", out):
        deleted.append((m.group(3), m.group(4), f"{m.group(1)} vs {m.group(2)}"))
    for m in re.finditer(r"Deleting job (\S+)/(\w+) as dependency of job (\S+)", out):
        deleted.append((m.group(1), m.group(2), f"dependency of {m.group(3)}"))
    jobs_dump = out.split("-> By jobs:", 1)[1]
    installed = set(re.findall(r"Action: (\S+) -> (\w+)", jobs_dump))
    owner = OWNERS[variant]
    ours_deleted = [d for d in deleted if d[0] in ours]
    check(not ours_deleted,
          f"[{variant}] boot transaction DELETED " +
          "; ".join(f"{u}/{t} ({why})" for u, t, why in ours_deleted))
    check((ANIM, "start") in installed, f"[{variant}] no {ANIM} start job in the boot transaction")
    stops = sorted(u for u, t in installed if u in ours and t == "stop")
    check(not stops, f"[{variant}] boot transaction stops {stops}")
    if owner:
        check((owner, "start") in installed, f"[{variant}] no {owner} start job in the boot transaction")
        others = sorted(u for u, t in installed if u in ours - {ANIM, owner})
        check(not others, f"[{variant}] other owners in the boot transaction: {others}")
    return (f"  transaction[{variant}] ({version}): isolate multi-user.target installs "
            f"{ANIM}/start" + (f" + {owner}/start" if owner else "") +
            f"; deleted jobs of these units: 0 (of {len(deleted)} total)")


# ---- live -------------------------------------------------------------------------

STUB = r'''#!/usr/bin/env python3
import fcntl, os, signal, sys, time
role, events, lock = sys.argv[1:4]
def log(msg):
    with open(events, "a") as fh:
        fh.write(f"{time.monotonic_ns()} {role} {msg}\n")
def term(signum, frame):
    log(f"signal {signal.Signals(signum).name}")
    os._exit(0)
signal.signal(signal.SIGTERM, term)
if role == "recovery":
    # stand-in recovery surface (a oneshot): record each start, then exit
    log("start")
    sys.exit(0)
if role == "decode":
    # stand-in pf-input-decode: the gamepad node appears ~0.4 s after start
    time.sleep(0.4)
    open(sys.argv[4], "w").close()
    while True:
        signal.pause()
fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    log("VIOLATION second-fb0-writer")
    sys.exit(3)
log(f"writer pid={os.getpid()}")
while True:
    signal.pause()
'''
GATE_DELAY = "0.3"      # stand-in open-GPU gate (the real one waits for the GPU)


class Live:
    def __init__(self, src: Source, work: Path):
        self.src = src
        self.work = work
        self.systemctl = shutil.which("systemctl")
        xdg = os.environ.get("XDG_RUNTIME_DIR")
        if not self.systemctl or not xdg:
            raise Blocked("no systemctl or XDG_RUNTIME_DIR")
        probe = subprocess.run([self.systemctl, "--user", "show", "-P", "Version"],
                               capture_output=True, text=True)
        if probe.returncode or not probe.stdout.strip():
            raise Blocked("no reachable systemd user manager")
        self.version = probe.stdout.strip()
        self.xdg = Path(xdg)
        self.unit_dir = self.xdg / "systemd/user"
        self.prefix = f"pfho{os.getpid()}-"
        self.marker = self.xdg / f"{self.prefix}panel-owner"

    def n(self, name: str) -> str:
        if name.endswith(".device"):         # the user manager cannot own a device
            name = name[:-len(".device")] + "-device.target"
        return self.prefix + name

    def sc(self, *args, check_rc=True) -> subprocess.CompletedProcess:
        r = subprocess.run([self.systemctl, "--user", *args], capture_output=True, text=True, timeout=60)
        if check_rc and r.returncode:
            raise Failed(f"systemctl --user {' '.join(args)}: rc={r.returncode} {r.stderr.strip()}")
        return r

    def show(self, unit: str, *props: str) -> dict[str, str]:
        r = self.sc("show", self.n(unit), *[f"--property={p}" for p in props])
        return dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)

    def transform(self, text: str, names: set[str], role: str | None, dd_before: str | None,
                  service: bool) -> str:
        """One image unit (or drop-in) -> a user-manager unit in the private namespace."""
        v = self.vdir
        lines = []
        section = None
        default_deps = True
        for raw in text.splitlines():
            s = raw.strip()
            if not s or s.startswith(("#", ";")):
                continue
            if s.startswith("["):
                section = s
                lines.append(s)
                continue
            key, _, val = s.partition("=")
            if key == "DefaultDependencies" and val.strip() == "no":
                default_deps = False
            if key in ("User", "Group", "SupplementaryGroups", "StateDirectory", "MemoryMax",
                       "StandardOutput", "StandardError", "ProtectSystem", "PrivateTmp",
                       "ReadWritePaths", "NoNewPrivileges"):
                continue
            if key == "Nice" and int(val) < 0:
                continue
            if key == "ExecStart" and section == "[Service]":
                val = self.exec_for(role)
            lines.append(f"{key}={val}")
        text = "\n".join(lines) + "\n"
        for old, new in (
                ("/run/pocketforge-panel-owner", str(self.marker)),
                ("RuntimeDirectory=pocketforge-panel-owner/", f"RuntimeDirectory={self.marker.name}/"),
                ("/opt/pocketforge/boot-anim/frames", str(v / "frames")),
                ("/dev/input/pf-gamepad", str(v / "pf-gamepad")),
                ("/dev/fb0", str(v / "fb0")),
                ("/var/lib/pocketforge/recovery", str(v / "recovery")),
                ("/bin/systemctl ", f"{self.systemctl} --user ")):
            text = text.replace(old, new)
        for name in sorted(names, key=len, reverse=True):
            text = re.sub(rf"(?<![A-Za-z0-9_.@:\\-]){re.escape(name)}(?![A-Za-z0-9_.@:\\-])",
                          self.n(name), text)
        if service and default_deps:
            # The system manager's implicit service dependencies, made explicit
            # (the user manager's own defaults would order against the user's
            # real basic.target instead).
            if "[Unit]" not in text:
                text = "[Unit]\n" + text
            extra = ["DefaultDependencies=no",
                     f"Requires={self.n('sysinit.target')}",
                     f"After={self.n('sysinit.target')} {self.n('basic.target')}",
                     f"Before={self.n('shutdown.target')}",
                     f"Conflicts={self.n('shutdown.target')}"]
            if dd_before:
                extra.append(f"Before={self.n(dd_before)}")
            text = text.replace("[Unit]\n", "[Unit]\n" + "\n".join(extra) + "\n", 1)
        return text

    def exec_for(self, role: str | None) -> str:
        stub = f"{sys.executable} -S {self.work / 'stub.py'}"
        ev, lock = self.events, self.vdir / "fb0.lock"
        if role in ("anim", "owner"):
            return f"{stub} {role} {ev} {lock}"
        if role == "decode":
            return f"{stub} decode {ev} {lock} {self.vdir / 'pf-gamepad'}"
        if role == "gate":
            return f"/bin/sleep {GATE_DELAY}"
        if role == "recovery":
            return f"{stub} recovery {ev} {self.vdir / 'fb0.lock'}"
        if role == "daemon":
            return "/bin/sleep infinity"
        return "/bin/true"

    def install(self, variant: str, recovery_required: bool = False):
        files, wants = model(self.src, variant)
        self.vdir = self.work / f"live-{variant}{'-recovery' if recovery_required else ''}"
        self.vdir.mkdir()
        (self.vdir / "recovery").mkdir()
        if recovery_required:
            (self.vdir / "recovery/required.json").write_text("{}\n")
        (self.vdir / "frames").mkdir()
        (self.vdir / "frames/frame-000.png").write_bytes(b"")
        (self.vdir / "fb0").write_bytes(b"")
        self.events = self.vdir / "events"
        self.events.write_text("")
        texts = dict(files)
        texts.update(STANDIN_TARGETS)
        for d in STANDIN_DAEMONS:
            texts[d] = "[Service]\nExecStart=/bin/true\n"
        names = {Path(rel).name for rel in texts if not rel.endswith(".conf")}
        for text in texts.values():
            for key in DEP_KEYS:
                for val in directive_values(text, key):
                    names.update(t for t in val.split() if UNIT_NAME.match(t))
            for val in directive_values(text, "ExecStartPre"):
                names.update(t for t in val.split() if UNIT_NAME.match(t))
        devices = sorted(n for n in names if n.endswith(".device"))
        roles = {ANIM: "anim", **{u: "owner" for u in OWNER_UNITS},
                 "pf-input-decode.service": "decode", "pf-prefsd.service": "daemon",
                 "pf-open-gpu-gate.service": "gate", "pocketforge-recovery.service": "recovery"}
        wanted_by = {u: t for t, us in wants.items() for u in us}
        for rel, text in texts.items():
            base = Path(rel).name
            is_dropin = rel.endswith(".conf")
            role = None if is_dropin else roles.get(base, "noop" if base.endswith(".service") else None)
            before = wanted_by.get(base) if not is_dropin else None
            out = self.transform(text, names, role, before,
                                 service=not is_dropin and base.endswith(".service"))
            if is_dropin:
                parent, leaf = rel.split("/")
                dest = self.unit_dir / (self.n(parent[:-2]) + ".d") / leaf
            else:
                dest = self.unit_dir / self.n(base)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(out)
        for dev in devices:
            (self.unit_dir / self.n(dev)).write_text("[Unit]\nDefaultDependencies=no\n")
        for target, units in wants.items():
            wdir = self.unit_dir / f"{self.n(target)}.wants"
            wdir.mkdir(exist_ok=True)
            for u in units:
                (wdir / self.n(u)).symlink_to(self.unit_dir / self.n(u))
        self.sc("daemon-reload")

    def events_list(self) -> list[tuple[int, str, str]]:
        out = []
        for line in self.events.read_text().splitlines():
            t, role, msg = line.split(" ", 2)
            out.append((int(t), role, msg))
        return out

    def cleanup(self):
        r = self.sc("list-units", "--all", "--plain", "--no-legend", f"{self.prefix}*", check_rc=False)
        units = [ln.split()[0] for ln in r.stdout.splitlines() if ln.strip()]
        if units:
            self.sc("stop", *units, check_rc=False)
            self.sc("reset-failed", *units, check_rc=False)
        for p in self.unit_dir.glob(f"{self.prefix}*"):
            if p.is_dir() and not p.is_symlink():
                shutil.rmtree(p)
            else:
                p.unlink()
        self.sc("daemon-reload", check_rc=False)
        if self.marker.exists():
            shutil.rmtree(self.marker)

    def run_variant(self, variant: str) -> str:
        owner = OWNERS[variant]
        self.install(variant)
        t0 = time.monotonic_ns() // 1000
        self.sc("start", self.n("multi-user.target"))
        deadline = time.monotonic() + 15
        want = owner or ANIM
        while time.monotonic() < deadline:
            st = self.show(want, "ActiveState", "ExecMainStartTimestampMonotonic")
            if st["ActiveState"] == "active" and int(st["ExecMainStartTimestampMonotonic"]):
                break
            time.sleep(0.05)
        time.sleep(0.3)                 # let any late stop/start settle
        props = ("ActiveState", "Result", "ConditionResult", "ConditionTimestampMonotonic",
                 "ExecMainStartTimestampMonotonic",
                 "ExecMainExitTimestampMonotonic", "ExecMainCode", "ExecMainStatus", "MainPID")
        a = self.show(ANIM, *props)
        ev = self.events_list()
        violations = [e for e in ev if "VIOLATION" in e[2]]
        a_start = int(a["ExecMainStartTimestampMonotonic"])
        check(a_start > 0, f"[{variant}] the animator never started: no start job for it ran "
                           f"(ActiveState={a['ActiveState']}, conditions evaluated at "
                           f"{a['ConditionTimestampMonotonic']} = never, ExecMainStart=0)"
                           if a["ConditionTimestampMonotonic"] == "0" else
                           f"[{variant}] the animator did not start: {a}")
        check(any(r == "anim" and m.startswith("writer") for _, r, m in ev),
              f"[{variant}] the animator started but never held fb0 (events: {ev})")
        check(not violations, f"[{variant}] two fb0 writers: {violations}")
        if not owner:
            check(a["ActiveState"] == "active", f"[{variant}] animator-owned image: animator not active ({a})")
            return (f"  live[{variant}] (systemd {self.version}): animator started "
                    f"{(a_start - t0) / 1000:.0f} ms after the boot start and keeps the panel")
        o = self.show(owner, *props)
        o_start = int(o["ExecMainStartTimestampMonotonic"])
        a_exit = int(a["ExecMainExitTimestampMonotonic"])
        check(o["ActiveState"] == "active" and o_start > 0, f"[{variant}] owner not running: {o}")
        check(a["ActiveState"] == "inactive" and a_exit > 0,
              f"[{variant}] the animator is still running next to the owner: {a}")
        signals = [m for _, r, m in ev if r == "anim" and m.startswith("signal")]
        check(signals == ["signal SIGTERM"], f"[{variant}] animator stop was not one SIGTERM: {signals}")
        check(a["ExecMainCode"] == "1" and a["ExecMainStatus"] == "0" and a["Result"] == "success",
              f"[{variant}] animator did not exit 0 on SIGTERM (a timeout kill?): {a}")
        check(a_start < a_exit <= o_start,
              f"[{variant}] animator exit ({a_exit}) is not before the owner's ExecStart ({o_start})")
        gap_ms = (o_start - a_exit) / 1000
        boot_ms = (o_start - t0) / 1000
        check(gap_ms < 1000, f"[{variant}] owner started {gap_ms:.0f} ms after the animator exited")
        check(boot_ms < 8000, f"[{variant}] owner took {boot_ms:.0f} ms from the boot start")
        writers = [r for _, r, m in ev if m.startswith("writer")]
        check(writers == ["anim", "owner"], f"[{variant}] fb0 writer sequence {writers}")
        # Reverse direction: starting the animator while the owner holds the panel
        # must be a skip; the owner must keep running (same main PID).
        o_pid = o["MainPID"]
        r = self.sc("start", self.n(ANIM), check_rc=False)
        time.sleep(0.3)
        a2 = self.show(ANIM, *props)
        o2 = self.show(owner, *props)
        check(o2["ActiveState"] == "active" and o2["MainPID"] == o_pid,
              f"[{variant}] `start {ANIM}` while the owner runs stopped or restarted the owner: {o2}")
        check(r.returncode == 0 and a2["ActiveState"] == "inactive" and a2["ConditionResult"] == "no",
              f"[{variant}] `start {ANIM}` while the owner runs was not a condition skip: rc={r.returncode} {a2}")
        check(not [e for e in self.events_list() if "VIOLATION" in e[2]], f"[{variant}] two fb0 writers")
        # Positive control: the guard is keyed to the owner's lifetime.
        self.sc("stop", self.n(owner))
        left = sorted(p.name for p in self.marker.iterdir()) if self.marker.exists() else []
        check(not left, f"[{variant}] panel-owner marker survived the owner's stop: {left}")
        self.sc("start", self.n(ANIM))
        time.sleep(0.3)
        a3 = self.show(ANIM, "ActiveState")
        check(a3["ActiveState"] == "active", f"[{variant}] animator cannot start after the owner stopped: {a3}")
        return (f"  live[{variant}] (systemd {self.version}): animator ran {(a_exit - a_start) / 1000:.0f} ms, "
                f"stopped by one SIGTERM (exit 0) {gap_ms:.1f} ms before the owner's ExecStart "
                f"({boot_ms:.0f} ms after the boot start); fb0 writers anim->owner, 0 overlaps; "
                f"animator start with owner live = skip (owner pid kept); after owner stop = runs")

    def run_recovery(self, variant: str) -> str:
        """Regression guard: a recovery surface requested at boot still wins.

        pocketforge-recovery.path fires early, in its own transaction. Through the
        foreground target it stops the animator and replaces the owner's pending
        boot start job, so the recovery surface owns fb0, starts exactly once,
        and the owner never starts. Starting the owner from a LATER transaction
        (the rejected alternative in bd tsp-3rd3.12) stops the target and the
        running recovery surface; the path unit then re-triggers it, so the
        surface flaps (killed and restarted) while the final state looks the
        same. Hence the start count, not just the final state."""
        owner = OWNERS[variant]
        self.install(variant, recovery_required=True)
        self.sc("start", self.n("multi-user.target"))
        time.sleep(1.5)                 # past the owner's gamepad wait and gate
        props = ("ActiveState", "ExecMainStartTimestampMonotonic", "ConditionResult")
        rec = self.show("pocketforge-recovery.service", *props)
        o = self.show(owner, *props)
        a = self.show(ANIM, *props)
        check(rec["ActiveState"] == "active" and rec["ConditionResult"] == "yes",
              f"[{variant}+recovery] recovery surface not active: {rec}")
        check(o["ActiveState"] != "active" and o["ExecMainStartTimestampMonotonic"] == "0",
              f"[{variant}+recovery] the owner started over the recovery surface: {o}")
        check(a["ActiveState"] != "active", f"[{variant}+recovery] animator still running: {a}")
        check(not [e for e in self.events_list() if "VIOLATION" in e[2]],
              f"[{variant}+recovery] two fb0 writers")
        starts = [e for e in self.events_list() if e[1] == "recovery"]
        check(len(starts) == 1, f"[{variant}+recovery] recovery surface started {len(starts)} times "
                                f"(stopped and re-triggered): {starts}")
        return (f"  live[{variant}+recovery]: RecoveryRequired at boot -> recovery started once and "
                f"active, {owner} never started, animator not running")


# ---- main ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ref", help="read units from this git ref instead of the work tree")
    ap.add_argument("--phase", choices=("static", "transaction", "live", "all"), default="all")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="pf-owner-handoff-"))
    (work / "stub.py").write_text(STUB)
    failures, blocked, notes = [], [], []
    live = None
    try:
        src = Source(args.ref)
        print(f"panel-owner boot handoff: units from {src.label}")
        check_builder(src)
        phases = ("static", "transaction", "live") if args.phase == "all" else (args.phase,)
        for phase in phases:
            variants = {"static": ["-"], "transaction": list(OWNERS),
                        "live": [*OWNERS, "shell+recovery"]}[phase]
            for variant in variants:
                label = phase if phase == "static" else f"{phase}[{variant}]"
                try:
                    if phase == "static":
                        phase_static(src, work)
                        continue
                    if phase == "transaction":
                        notes.append(phase_transaction(src, work, variant))
                    else:
                        live = live or Live(src, work)
                        try:
                            if variant.endswith("+recovery"):
                                notes.append(live.run_recovery(variant.split("+")[0]))
                            else:
                                notes.append(live.run_variant(variant))
                        finally:
                            live.cleanup()
                    print(notes[-1])
                except Failed as e:
                    failures.append(label)
                    print(f"FAIL {label}: {e}")
                except Blocked as e:
                    blocked.append(label)
                    print(f"BLOCKED {label}: {e}")
    except Failed as e:
        failures.append("model")
        print(f"FAIL model: {e}")
    except Blocked as e:
        blocked.append("setup")
        print(f"BLOCKED setup: {e}")
    finally:
        if args.keep or failures:
            print(f"work dir kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    if failures:
        print(f"panel-owner boot handoff: FAIL {','.join(failures)}")
        return 1
    if blocked:
        print(f"panel-owner boot handoff: BLOCKED {','.join(blocked)}")
        return BLOCKED
    print("panel-owner boot handoff: PASS")
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, signal.default_int_handler)
    sys.exit(main())
