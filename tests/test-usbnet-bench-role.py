#!/usr/bin/env python3
"""Hermetic harness for the dev bench USB0 role script (bd tsp-mc9m.41.984.34.2).

The PRODUCTION script (rootfs-overlay/usr/lib/pocketforge/usbnet-bench.sh) runs
unmodified, with its production paths, in an unprivileged bwrap view:
  - the host root is read-only (--ro-bind / /, and /dev is remounted read-only);
  - a fake sysfs (which holds a fake configfs at kernel/config) is bound at /sys;
  - a fake /run is bound at /run.
Those two trees are the only writable surfaces, and the harness records every
write to them itself, without any cooperation from the script:
  - a before/after snapshot of both trees (content digest, mode, link target)
    gives every created, modified or deleted path;
  - inotify watches on every pre-existing file and directory record every
    write session (IN_CLOSE_WRITE, IN_MODIFY, IN_ATTRIB), even one that
    rewrites identical bytes, plus every create/delete/rename;
  - those same watches count writes to the MUSB `mode` and gadget `UDC`
    attributes and give their order.
Positive controls run in the same view: /sys is the fake, the host root and
/dev are read-only, and the recorder sees a write made inside the sandbox.

Cases (acceptance 2 and 3 of the bead):
  VBUS present -> `peripheral` written exactly once, then the UDC is bound
  (order proven), and the configfs tree the script produced is parsed against
  usbnet contract v1 (1d6b:0104, one ncm function linked into the one config,
  locally administered unicast MACs). A second start writes only its status.
  VBUS absent -> no mode write and no UDC bind.
  A missing, unreadable or ambiguous supply -> no write, with the reason logged.
  Boost on, unknown or missing -> no write.
  Controller or gadget problems -> no mode write. A bind failure followed by a
  retry still writes `mode` only once in the boot.
  Every case: nothing written under any regulator or power_supply path, and
  nothing whose path contains "vbus".
A static phase parses 30-usb0.network, the unit and the udev rule. The unit's
RuntimeDirectory must equal the state directory the script was OBSERVED to use.

Exit status: 0 PASS, 1 FAIL, 75 BLOCKED (bwrap or inotify unusable).
"""
import argparse
import ctypes
import ctypes.util
import errno
import hashlib
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
OVERLAY = REPO / "rootfs-overlay"
SCRIPT = OVERLAY / "usr/lib/pocketforge/usbnet-bench.sh"
UNIT_FILE = OVERLAY / "etc/systemd/system/pocketforge-usbnet-bench.service"
RULE_FILE = OVERLAY / "etc/udev/rules.d/80-pocketforge-usbnet-bench.rules"
NETWORK_FILE = OVERLAY / "etc/systemd/network/30-usb0.network"
WLAN_FILE = OVERLAY / "etc/systemd/network/20-wlan0.network"
NETWORKD_DEFAULT_DHCP_ROUTE_METRIC = 1024

MUSB = "musb-hdrc.2.auto"
MUSB_DEV = f"devices/platform/soc/5100000.usb/{MUSB}"
MODE = f"sys/{MUSB_DEV}/mode"
PMIC = "devices/platform/soc/7081400.i2c/i2c-0/0-0034"
DT_PMIC = "firmware/devicetree/base/soc/i2c@7081400/pmic@34"
AXP_USB_COMPAT = b"x-powers,axp717-usb-power-supply\0"
GADGET = "sys/kernel/config/usb_gadget/pocketforge-usbnet"
UDC_FILE = f"{GADGET}/UDC"
STATE = "run/pocketforge-usbnet-bench"
ALLOWED_PREFIXES = (GADGET, STATE)
ALLOWED_EXACT = {MODE}
ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C"}


class Blocked(Exception):
    pass


class Failed(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failed(message)


# ---- inotify ----------------------------------------------------------------------------
IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE = 0x2, 0x4, 0x8
IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE, IN_DELETE = 0x40, 0x80, 0x100, 0x200
IN_Q_OVERFLOW, IN_IGNORED, IN_DONT_FOLLOW = 0x4000, 0x8000, 0x02000000
IN_NONBLOCK, IN_CLOEXEC = os.O_NONBLOCK, 0o2000000
FILE_MASK = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_DONT_FOLLOW
DIR_MASK = IN_ATTRIB | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DONT_FOLLOW
WRITE_EVENTS = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO


class Recorder:
    """inotify on every pre-existing file and directory of the writable trees."""

    def __init__(self, work, trees):
        libc_name = ctypes.util.find_library("c") or "libc.so.6"
        try:
            self.libc = ctypes.CDLL(libc_name, use_errno=True)
            self.fd = self.libc.inotify_init1(IN_NONBLOCK | IN_CLOEXEC)
        except (OSError, AttributeError) as exc:
            raise Blocked(f"inotify unavailable: {exc}") from exc
        if self.fd < 0:
            raise Blocked(f"inotify_init1: {os.strerror(ctypes.get_errno())}")
        self.work = work
        self.wds = {}
        for tree in trees:
            for top, dirs, files in os.walk(work / tree):
                self._watch(Path(top), DIR_MASK)
                for name in files:
                    self._watch(Path(top) / name, FILE_MASK)

    def _watch(self, path, mask):
        wd = self.libc.inotify_add_watch(self.fd, os.fsencode(path), mask)
        if wd < 0:
            raise Blocked(f"inotify_add_watch {path}: {os.strerror(ctypes.get_errno())}")
        self.wds[wd] = path.relative_to(self.work).as_posix()

    def events(self):
        """[(rel_path, mask)] in kernel order."""
        data = b""
        while True:
            try:
                chunk = os.read(self.fd, 65536)
            except BlockingIOError:
                break
            if not chunk:
                break
            data += chunk
        out = []
        offset = 0
        while offset < len(data):
            wd, mask, _cookie, length = struct.unpack_from("iIII", data, offset)
            offset += 16
            name = data[offset:offset + length].rstrip(b"\0").decode()
            offset += length
            if mask & IN_Q_OVERFLOW:
                raise Blocked("inotify queue overflowed")
            if mask & IN_IGNORED:
                continue
            base = self.wds.get(wd)
            if base is None:
                continue
            out.append((f"{base}/{name}" if name else base, mask))
        return out

    def close(self):
        os.close(self.fd)


# ---- fake sysfs -------------------------------------------------------------------------

def put(root, rel, content=b"", mode=0o644):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())
    path.chmod(mode)


def link(root, rel, target_rel):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(os.path.relpath(root / target_rel, path.parent))


def add_supply(sys_root, name, index, compat, kind, present):
    dev = f"{PMIC}/axp20x-{kind}-power-supply.{index}.auto"
    node = f"{DT_PMIC}/{kind}-power-{index}"
    put(sys_root, f"{node}/compatible", compat)
    link(sys_root, f"{dev}/of_node", node)
    psy = f"{dev}/power_supply/{name}"
    put(sys_root, f"{psy}/type", "USB\n" if kind == "usb" else "Battery\n")
    if present is not None:
        put(sys_root, f"{psy}/present", present)
    put(sys_root, f"{psy}/online", "1\n")
    put(sys_root, f"{psy}/voltage_now", "4478000\n")
    link(sys_root, f"{psy}/device", dev)
    link(sys_root, f"class/power_supply/{name}", psy)


def add_regulator(sys_root, number, name, state, users):
    dev = f"{PMIC}/axp20x-regulator/regulator/regulator.{number}"
    put(sys_root, f"{dev}/name", f"{name}\n")
    if state is not None:
        put(sys_root, f"{dev}/state", f"{state}\n")
    if users is not None:
        put(sys_root, f"{dev}/num_users", f"{users}\n")
    put(sys_root, f"{dev}/microvolts", "5126000\n")
    link(sys_root, f"class/regulator/regulator.{number}", dev)


def build_sys(sys_root, supply="axp717", present="1\n", boost=("disabled", "0"),
              musb="ok", gadget=None, other_gadget_udc=None):
    """A fake /sys modelled on the A133 tsp DT at kernel-sunxi-7.x 94ee6079.

    Values echo the R0-cap bench receipt (tsp-mc9m.41.923.42-armR0-cap):
    mode=b_idle with phy0 locked HOST, usb0-vbus disabled/0 users, VBUS good.
    """
    put(sys_root, "harness-marker", "pf-usbnet-fake-sysfs\n")
    if supply == "axp717":
        add_supply(sys_root, "axp20x-usb", 1, AXP_USB_COMPAT, "usb", present)
    elif supply == "other":
        add_supply(sys_root, "axp20x-usb", 1, b"x-powers,axp813-usb-power-supply\0", "usb", present)
    elif supply == "two":
        add_supply(sys_root, "axp20x-usb", 1, AXP_USB_COMPAT, "usb", present)
        add_supply(sys_root, "axp20x-usb-2", 3, AXP_USB_COMPAT, "usb", present)
    # Decoy: a battery supply, never USB.
    add_supply(sys_root, "axp20x-battery", 2, b"x-powers,axp717-battery-power-supply\0", "battery", "1\n")
    add_regulator(sys_root, 21, "vcc-5v", "enabled", "14")
    add_regulator(sys_root, 23, "usb1-vbus", "enabled", "1")  # decoy: "vbus" but not ours
    if boost == "two":
        add_regulator(sys_root, 22, "usb0-vbus", "disabled", "0")
        add_regulator(sys_root, 24, "usb0-vbus", "disabled", "0")
    elif boost is not None:
        add_regulator(sys_root, 22, "usb0-vbus", boost[0], boost[1])
    if musb in ("ok", "wrong-parent"):
        dev = MUSB_DEV if musb == "ok" else f"devices/platform/soc/5200000.usb/{MUSB}"
        put(sys_root, f"{dev}/mode", "b_idle\n")
        put(sys_root, f"{dev}/vbus", "Vbus off, timeout 1100 msec\n")
        put(sys_root, f"{dev}/srp", "")
        put(sys_root, f"{dev}/udc/{MUSB}/state", "not attached\n")
        put(sys_root, f"{dev}/udc/{MUSB}/current_speed", "UNKNOWN\n")
        link(sys_root, f"bus/platform/devices/{MUSB}", dev)
        link(sys_root, f"class/udc/{MUSB}", f"{dev}/udc/{MUSB}")
    (sys_root / "kernel/config/usb_gadget").mkdir(parents=True, exist_ok=True)
    if gadget is not None:
        # As real configfs presents a gadget after mkdir: attributes exist.
        g = sys_root / "kernel/config/usb_gadget/pocketforge-usbnet"
        for rel in ("idVendor", "idProduct", "bcdDevice", "bcdUSB",
                    "strings/0x409/manufacturer", "strings/0x409/product",
                    "strings/0x409/serialnumber", "configs/c.1/bmAttributes",
                    "configs/c.1/MaxPower", "configs/c.1/strings/0x409/configuration",
                    "functions/ncm.usb0/dev_addr", "functions/ncm.usb0/host_addr"):
            put(g, rel, "")
        if gadget == "udc-file":
            put(g, "UDC", "")
        elif gadget == "udc-unwritable":
            (g / "UDC").mkdir()
    if other_gadget_udc is not None:
        put(sys_root, "kernel/config/usb_gadget/other/UDC", other_gadget_udc)


# ---- sandbox run -------------------------------------------------------------------------

def bwrap_path():
    path = shutil.which("bwrap")
    if not path:
        raise Blocked("bwrap not installed")
    return path


def sandbox(work, command, ro_config=False):
    argv = [bwrap_path(), "--ro-bind", "/", "/", "--dev", "/dev", "--remount-ro", "/dev",
            "--proc", "/proc", "--bind", str(work / "sys"), "/sys", "--bind", str(work / "run"), "/run"]
    if ro_config:
        argv += ["--ro-bind", str(work / "sys/kernel/config"), "/sys/kernel/config"]
    argv += ["--chdir", "/"] + command
    return subprocess.run(argv, env=ENV, capture_output=True, text=True, timeout=60)


def snapshot(work, trees=("sys", "run")):
    state = {}
    for tree in trees:
        base = work / tree
        for top, dirs, files in os.walk(base):
            for name in dirs + files:
                path = Path(top) / name
                rel = path.relative_to(work).as_posix()
                st = path.lstat()
                if stat.S_ISLNK(st.st_mode):
                    state[rel] = ("l", os.readlink(path))
                elif stat.S_ISDIR(st.st_mode):
                    state[rel] = ("d", stat.S_IMODE(st.st_mode))
                else:
                    state[rel] = ("f", hashlib.sha256(path.read_bytes()).hexdigest(),
                                  stat.S_IMODE(st.st_mode))
    return state


class Run:
    def __init__(self, work, ro_config=False):
        before = snapshot(work)
        recorder = Recorder(work, ("sys", "run"))
        try:
            self.proc = sandbox(work, ["/bin/bash", str(SCRIPT)], ro_config=ro_config)
            self.events = recorder.events()
        finally:
            recorder.close()
        after = snapshot(work)
        changed = {rel for rel in before.keys() | after.keys() if before.get(rel) != after.get(rel)}
        evented = {rel for rel, mask in self.events if mask & WRITE_EVENTS}
        self.writes = changed | evented
        self.after = after
        self.work = work
        status = work / STATE / "status"
        self.status = {}
        if status.is_file():
            for line in status.read_text().splitlines():
                key, _, value = line.partition("=")
                self.status[key] = value

    @property
    def rc(self):
        return self.proc.returncode

    def close_writes(self, rel):
        return [i for i, (path, mask) in enumerate(self.events) if path == rel and mask & IN_CLOSE_WRITE]

    def describe(self):
        return (f"rc={self.rc} status={self.status} writes={sorted(self.writes)}\n"
                f"stdout={self.proc.stdout!r}\nstderr={self.proc.stderr!r}")


def assert_write_policy(run, label):
    """Every recorded write lies inside the allowed surfaces; no regulator,
    power_supply or vbus path is touched."""
    for rel in run.writes:
        check(not re.search("vbus", rel, re.IGNORECASE),
              f"{label}: wrote a *vbus* path {rel}\n{run.describe()}")
        check("/regulator" not in rel and "power_supply" not in rel and "-power-supply." not in rel,
              f"{label}: wrote a regulator/power_supply path {rel}\n{run.describe()}")
        allowed = rel in ALLOWED_EXACT or any(rel == p or rel.startswith(p + "/") for p in ALLOWED_PREFIXES)
        check(allowed, f"{label}: write outside the allowed surfaces: {rel}\n{run.describe()}")


def assert_hold(run, label, reason, rc):
    check(run.rc == rc, f"{label}: exit {run.rc}, want {rc}\n{run.describe()}")
    check(run.status.get("decision") == "hold" and run.status.get("reason") == reason,
          f"{label}: status {run.status}, want hold/{reason}\n{run.describe()}")
    check(f"decision=hold reason={reason}" in run.proc.stdout,
          f"{label}: reason not logged\n{run.describe()}")
    check(not run.close_writes(MODE), f"{label}: wrote the MUSB mode\n{run.describe()}")
    assert_write_policy(run, label)
    check(all(rel == STATE or rel.startswith(STATE + "/") for rel in run.writes),
          f"{label}: wrote outside its state dir (gadget, mode or elsewhere)\n{run.describe()}")


# ---- cases ------------------------------------------------------------------------------

def fresh(base, name, **tree):
    work = base / name
    (work / "run").mkdir(parents=True)
    build_sys(work / "sys", **tree)
    return work


def parse_gadget(work):
    g = work / GADGET
    check(sorted(p.name for p in (work / "sys/kernel/config/usb_gadget").iterdir()) == ["pocketforge-usbnet"],
          "configfs holds a gadget other than pocketforge-usbnet")

    def attr(rel):
        return (g / rel).read_text().strip()

    check(int(attr("idVendor"), 16) == 0x1D6B, f"idVendor {attr('idVendor')}")
    check(int(attr("idProduct"), 16) == 0x0104, f"idProduct {attr('idProduct')}")
    functions = sorted(p.name for p in (g / "functions").iterdir())
    check(functions == ["ncm.usb0"], f"functions {functions}, want exactly one ncm function")
    configs = sorted(p.name for p in (g / "configs").iterdir())
    check(configs == ["c.1"], f"configs {configs}")
    linked = [p for p in (g / "configs/c.1").iterdir() if p.is_symlink()]
    check(len(linked) == 1, f"config c.1 links {linked}, want one function")
    target = os.readlink(linked[0])
    check(target == "/sys/kernel/config/usb_gadget/pocketforge-usbnet/functions/ncm.usb0",
          f"config link target {target}")
    macs = []
    for rel in ("functions/ncm.usb0/dev_addr", "functions/ncm.usb0/host_addr"):
        value = attr(rel)
        check(re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", value), f"{rel} {value!r} is not a MAC")
        first = int(value[:2], 16)
        check(first & 0x02 and not first & 0x01, f"{rel} {value} is not locally administered unicast")
        macs.append(value)
    check(macs[0] != macs[1], "dev_addr equals host_addr")
    check(attr("UDC") == MUSB, f"UDC {attr('UDC')!r}")
    return f"1d6b:0104, functions={functions}, c.1 -> ncm.usb0, macs={macs}, UDC={MUSB}"


def case_controls(base):
    work = fresh(base, "controls")
    probe = ("cat /sys/harness-marker; test -d /sys/kernel/config/usb_gadget && echo configfs; "
             "for p in /etc/pf-canary /usr/pf-canary /tmp/pf-canary /dev/pf-canary; do "
             ": > $p 2>/dev/null && echo writable:$p; done; "
             f"printf probe > /sys/{MUSB_DEV}/srp && echo sys-writable")
    before = snapshot(work)
    recorder = Recorder(work, ("sys", "run"))
    try:
        proc = sandbox(work, ["/bin/bash", "-c", probe])
        events = recorder.events()
    finally:
        recorder.close()
    check(proc.returncode == 0, f"control probe failed: {proc.stderr}")
    lines = proc.stdout.split()
    check(lines[:2] == ["pf-usbnet-fake-sysfs", "configfs"], f"/sys is not the fake: {lines}")
    check(not [line for line in lines if line.startswith("writable:")], f"host root writable: {lines}")
    check("sys-writable" in lines, "the fake /sys is not writable in the view")
    srp = f"sys/{MUSB_DEV}/srp"
    check(any(rel == srp and mask & IN_CLOSE_WRITE for rel, mask in events),
          "the recorder did not see a write made inside the sandbox")
    check(before != snapshot(work), "the snapshot did not see a write made inside the sandbox")
    return "view: /sys and configfs are the fakes; /etc, /usr, /tmp, /dev read-only; recorder sees sandbox writes"


def case_present(base):
    work = fresh(base, "present")
    run = Run(work)
    check(run.rc == 0, f"exit {run.rc}\n{run.describe()}")
    check(run.status.get("decision") == "switched", f"status {run.status}\n{run.describe()}")
    check(run.status.get("musb_mode_before") == "b_idle", f"status {run.status}")
    check(len(run.close_writes(MODE)) == 1, f"mode written {len(run.close_writes(MODE))} times\n{run.describe()}")
    check((work / MODE).read_text() == "peripheral\n", f"mode = {(work / MODE).read_text()!r}")
    assert_write_policy(run, "present")
    contract = parse_gadget(work)
    check("decision=switched reason=external_vbus_present" in run.proc.stdout, run.describe())
    observed_state = sorted({rel.split("/")[1] for rel in run.writes if rel.startswith("run/")})
    check(observed_state == ["pocketforge-usbnet-bench"], f"state dirs written {observed_state}")
    second = Run(work)
    check(second.rc == 0 and second.status.get("decision") == "already_switched",
          f"second start: {second.describe()}")
    check(not second.close_writes(MODE), f"second start rewrote mode\n{second.describe()}")
    check(all(rel.startswith(STATE + "/status") for rel in second.writes),
          f"second start wrote more than its status: {sorted(second.writes)}")
    return (f"switched: mode written once (b_idle -> peripheral), UDC bound; contract {contract}; "
            f"a second start writes only {sorted(second.writes)}"), observed_state[0]


def case_order(base):
    work = fresh(base, "order", gadget="udc-file")
    run = Run(work)
    check(run.rc == 0 and run.status.get("decision") == "switched", run.describe())
    modes, binds = run.close_writes(MODE), run.close_writes(UDC_FILE)
    check(len(modes) == 1 and len(binds) == 1, f"mode writes {modes}, UDC writes {binds}\n{run.describe()}")
    check(modes[0] < binds[0], f"UDC bound before the mode write: {modes} {binds}")
    assert_write_policy(run, "order")
    parse_gadget(work)
    return f"pre-built gadget: mode write (event {modes[0]}) precedes the UDC bind (event {binds[0]}), one each"


def case_retry(base):
    work = fresh(base, "retry", gadget="udc-unwritable")
    first = Run(work)
    check(first.rc == 1 and first.status.get("decision") == "error"
          and first.status.get("reason") == "udc_bind_failed", first.describe())
    check(len(first.close_writes(MODE)) == 1, f"first run mode writes\n{first.describe()}")
    assert_write_policy(first, "retry-1")
    (work / UDC_FILE).rmdir()
    put(work, UDC_FILE, "")
    second = Run(work)
    check(second.rc == 0 and second.status.get("decision") == "switched", second.describe())
    check(not second.close_writes(MODE), f"retry rewrote mode\n{second.describe()}")
    check(len(second.close_writes(UDC_FILE)) == 1, second.describe())
    assert_write_policy(second, "retry-2")
    return "bind failure -> exit 1 after one mode write; the retry binds without writing mode again"


HOLDS = (
    ("vbus-absent", dict(present="0\n"), "vbus_absent", 0, False),
    ("supply-missing", dict(supply="other"), "vbus_supply_missing", 1, False),
    ("supply-none", dict(supply=None), "vbus_supply_missing", 1, False),
    ("supply-ambiguous", dict(supply="two"), "vbus_supply_ambiguous", 1, False),
    ("present-unreadable", dict(present=None), "vbus_unreadable", 1, False),
    ("present-garbage", dict(present="2\n"), "vbus_unreadable", 1, False),
    ("boost-enabled", dict(boost=("enabled", "1")), "boost_enabled", 1, False),
    ("boost-users", dict(boost=("disabled", "1")), "boost_enabled", 1, False),
    ("boost-state-unknown", dict(boost=(None, "0")), "boost_state_unknown", 1, False),
    ("boost-missing", dict(boost=None), "boost_regulator_missing", 1, False),
    ("boost-ambiguous", dict(boost="two"), "boost_regulator_ambiguous", 1, False),
    ("musb-missing", dict(musb=None), "musb_missing", 1, False),
    ("musb-wrong-parent", dict(musb="wrong-parent"), "musb_unexpected_parent", 1, False),
    ("udc-in-use", dict(other_gadget_udc=MUSB + "\n"), "udc_in_use", 1, False),
    ("gadget-configfs-readonly", dict(), "gadget_create_failed", 1, True),
)


def case_hold(base, label, tree, reason, rc, ro_config):
    work = fresh(base, label, **tree)
    run = Run(work, ro_config=ro_config)
    assert_hold(run, label, reason, rc)
    check(not (work / UDC_FILE).exists(), f"{label}: a UDC file exists")
    evidence = {k: run.status.get(k) for k in ("supply", "present", "boost_state", "boost_users") if run.status.get(k)}
    return f"hold/{reason} exit {rc}, no mode write, no bind, writes {sorted(run.writes)} evidence {evidence}"


# ---- static contract ----------------------------------------------------------------------

def unit_values(path):
    section = None
    values = {}
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("["):
            check(line.endswith("]"), f"{path.name}:{number} unparseable {line!r}")
            section = line[1:-1]
            continue
        key, sep, value = line.partition("=")
        check(sep and section, f"{path.name}:{number} unparseable {line!r}")
        values.setdefault((section, key.strip()), []).append(value.strip())
    return values


def udev_rules(path):
    rules = []
    for number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        check(not line.endswith("\\"), f"{path.name}:{number}: continuation lines are not expected")
        pairs = re.findall(r'\s*([A-Za-z_]+(?:\{[^}]*\})?)\s*(==|!=|\+=|:=|=)\s*"([^"]*)"\s*(?:,|$)', line)
        rebuilt = ", ".join(f'{k}{op}"{v}"' for k, op, v in pairs)
        check(rebuilt == line, f"{path.name}:{number} does not parse as key/op/value: {line!r}")
        rules.append(pairs)
    return rules


def case_static(state_dir):
    net = unit_values(NETWORK_FILE)
    check(net.get(("Match", "Name")) == ["usb0"] and net.get(("Match", "Driver")) == ["g_ether"],
          f"30-usb0.network [Match] {net}")
    check(net.get(("Network", "DHCP")) == ["ipv4"], f"DHCP {net.get(('Network', 'DHCP'))}")
    check(net.get(("Link", "RequiredForOnline")) == ["no"], "RequiredForOnline must be no")
    wlan = unit_values(WLAN_FILE)
    wlan_metric = int(wlan.get(("DHCPv4", "RouteMetric"), [NETWORKD_DEFAULT_DHCP_ROUTE_METRIC])[-1])
    metric = int(net[("DHCPv4", "RouteMetric")][-1])
    check(metric > wlan_metric, f"usb0 RouteMetric {metric} is not worse than wlan0's {wlan_metric}")
    unit = unit_values(UNIT_FILE)
    check(unit.get(("Install", "WantedBy")) == ["usb-gadget.target"], f"WantedBy {unit.get(('Install', 'WantedBy'))}")
    check(unit.get(("Service", "Type")) == ["oneshot"], "Type must be oneshot")
    check(unit.get(("Service", "ExecStart")) == ["/usr/lib/pocketforge/usbnet-bench.sh"], "ExecStart")
    check(unit.get(("Service", "RemainAfterExit"), ["no"]) == ["no"],
          "RemainAfterExit would stop VBUS change events from re-running the gate")
    check(unit.get(("Service", "RuntimeDirectory")) == [state_dir],
          f"RuntimeDirectory {unit.get(('Service', 'RuntimeDirectory'))} != observed state dir {state_dir}")
    check(unit.get(("Service", "RuntimeDirectoryPreserve")) == ["yes"],
          "RuntimeDirectoryPreserve=yes keeps the latch between oneshot runs")
    rules = udev_rules(RULE_FILE)
    check(len(rules) == 1, f"{len(rules)} udev rules, want 1")
    rule = {(k, op): v for k, op, v in rules[0]}
    check(rule == {
        ("ACTION", "=="): "change", ("SUBSYSTEM", "=="): "power_supply", ("KERNEL", "=="): "axp20x-usb",
        ("RUN", "+="): f"/usr/bin/systemctl --no-block start {UNIT_FILE.name}",
    }, f"udev rule {rule}")
    return (f"30-usb0.network Name=usb0 Driver=g_ether DHCP=ipv4 RouteMetric={metric} > wlan0 {wlan_metric}; "
            f"unit oneshot, WantedBy=usb-gadget.target, RuntimeDirectory={state_dir}; udev change rule starts it")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true")
    args = parser.parse_args()
    base = Path(tempfile.mkdtemp(prefix="pf-usbnet-role."))
    passed = 0
    try:
        probe = subprocess.run([bwrap_path(), "--ro-bind", "/", "/", "--dev", "/dev", "--remount-ro", "/dev",
                                "--proc", "/proc", "/bin/true"], env=ENV, capture_output=True, text=True)
        if probe.returncode != 0:
            raise Blocked(f"bwrap cannot create the view: {probe.stderr.strip()}")
        results = [("controls", case_controls(base))]
        detail, state_dir = case_present(base)
        results.append(("vbus-present", detail))
        results.append(("order", case_order(base)))
        results.append(("bind-retry", case_retry(base)))
        for label, tree, reason, rc, ro_config in HOLDS:
            results.append((label, case_hold(base, label, tree, reason, rc, ro_config)))
        results.append(("static", case_static(state_dir)))
        for label, detail in results:
            print(f"PASS {label}: {detail}")
            passed += 1
        print(f"usbnet-bench role harness: PASS ({passed} cases)")
        return 0
    except Blocked as exc:
        print(f"usbnet-bench role harness: BLOCKED {exc}", file=sys.stderr)
        return 75
    except Failed as exc:
        print(f"usbnet-bench role harness: FAIL {exc}", file=sys.stderr)
        return 1
    finally:
        if args.keep:
            print(f"kept: {base}")
        else:
            for top, dirs, _ in os.walk(base):
                for name in dirs:
                    os.chmod(os.path.join(top, name), 0o755)
            shutil.rmtree(base)


if __name__ == "__main__":
    sys.exit(main())
