#!/usr/bin/env python3
"""Hermetic tests for the initrd first-light frame-000 hook (bd tsp-3rd3.7).

The real boards/tsp/initrd/init runs end to end inside a bubblewrap fake root.
Only what /init talks to outside itself is stood in for:

  * mount/umount/findfs/insmod/reboot/sync are shell functions from a prelude
    (functions shadow busybox applets as well as PATH), and the sync stand-in
    doubles as a probe: after every logged stage it records every process in
    the sandbox's pid namespace other than the reaper (pid 1) and /init;
  * /dev/watchdog is a raw pty slave, so every keepalive byte /init writes is
    timestamped on the master side;
  * /dev/fb0 appears (or never does) at PF_FF_FB, a seam like WATCHDOG_DEV;
  * the helper is either the production animator source built for the host and
    run under apps/pocketforge-boot-animator/tests/fakefb.c (painted frame,
    unreadable orientation, bad geometry) or a single-process stand-in that
    hangs, crashes or exits 1.

Every case runs under two shells: bash, and (when available) the device's own
busybox 1.35.0 arm64 ash through qemu-aarch64-static -- the shell that runs
/init on the device, with its read -t / kill / wait / job-reaping semantics.

Each case asserts that switch_root is reached, that no process other than /init
exists when it is (and before self-flash recovery), the reaped exit status, and
the helper's observable effects. Timing cases compare the init path (banner ->
switch_root) against the no-payload path under identical stubs and bound the
difference by 50 ms; the watchdog case compares every keepalive gap. Then the
same checks run against deliberately broken copies of /init and of
build-initrd.sh and must fail.

Needs: python3, bwrap (unprivileged user namespaces), cc, bash. Optional:
PF_TEST_BUSYBOX_ARM64=<busybox-arm64 from the pinned build container> plus
qemu-aarch64-static for the device-shell leg; --container IMAGE for the real
reproducible initrd build (docker, unprivileged, --network none).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import tty

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
INIT = os.path.join(REPO, "boards/tsp/initrd/init")
BUILD_INITRD = os.path.join(REPO, "boards/tsp/initrd/build-initrd.sh")
APP = os.path.join(REPO, "apps/pocketforge-boot-animator")
FRAME0 = os.path.join(APP, "frames/frame-000.png")
# sha256 of /opt/pocketforge/initrd-payload/busybox-arm64 in the pinned build
# container (it is the busybox every a133 initrd ships).
DEVICE_BUSYBOX_SHA256 = "61781806ad3650b0b9d2b3fc6971e2bffdca967af1a95375abd0578bafff14fb"
BUDGET_S = 0.050          # acceptance: <= 50 ms added to the init path
FF_BOUND_S = 2.5          # acceptance: <= 2.5 s wait for /dev/fb0
G_DRM = (720, 1280, 720, 1280, 2880)      # 7.x DRM fbdev, OVERALLOC=100

PRELUDE = r"""
# tests/test_initrd_first_frame.py prelude: stand-ins for what /init asks of
# the kernel and the SD card. Shell functions shadow busybox applets and PATH.
mount() { printf 'mount %s\n' "$*" >> /t/calls.log; return 0; }
umount() { return 0; }
insmod() { return 0; }
reboot() { printf 'reboot\n' >> /t/calls.log; exit 0; }
findfs() {
    case "$1" in
        LABEL=POCKETFORGE) echo /dev/mmcblk0p4 ;;
        LABEL=POCKETFORGE_DATA)
            if [ -n "$T_ROOT_DELAY" ]; then sleep "$T_ROOT_DELAY"; fi
            echo /dev/mmcblk0p5 ;;
    esac
}
# sync is called after every logged stage: record every process other than
# the namespace reaper (pid 1) and /init itself, keyed by the log line count.
sync() {
    t_n=0
    if [ -f /pflog/bootlog.txt ]; then
        while IFS= read -r t_l; do t_n=$((t_n + 1)); done < /pflog/bootlog.txt
    fi
    t_out=""
    for t_d in /proc/[0-9]*; do
        t_p="${t_d#/proc/}"
        [ "$t_p" = 1 ] && continue
        [ "$t_p" = "$$" ] && continue
        t_s=""
        { read -r t_s < "$t_d/stat"; } 2>/dev/null
        [ -n "$t_s" ] || continue
        t_st="${t_s##*) }"; t_st="${t_st%% *}"
        t_c="${t_s#*(}"; t_c="${t_c%)*}"
        t_out="$t_out $t_p:$t_st:$t_c"
    done
    printf 'SCAN %s%s\n' "$t_n" "$t_out" >> /t/scan.log
}
"""

STUB_BUSYBOX = "#!/usr/bin/bash\n# /bin/busybox --install -s /bin: nothing to install here\nexit 0\n"
STUB_SWITCH_ROOT = "#!/usr/bin/bash\necho \"STUB switch_root $*\"\nexit 0\n"
STUB_SH = "#!/usr/bin/bash\necho \"STUB /bin/sh reached (fail shell or M1.B shell)\"\nexit 0\n"

HELPER_LOG = 'printf \'%s %s\\n\' "$$" "$*" >> /t/helper.log\n'
FAKE_HELPERS = {
    # one process, deaf to TERM/INT/HUP, blocked in a builtin read: only SIGKILL ends it
    "hang": "#!/usr/bin/bash\n" + HELPER_LOG + "trap '' TERM INT HUP\n"
            "if [ -n \"$T_FAKE_D\" ]; then\n"
            "    mkdir -p \"/t/fakeproc/$$\" \"/t/fakeproc/$PPID\"\n"
            "    printf '%s (fake) D 1\\n' \"$$\" > \"/t/fakeproc/$$/stat\"\n"
            "    printf '%s (init) S 0\\n' \"$PPID\" > \"/t/fakeproc/$PPID/stat\"\n"
            "fi\n"
            "exec 3<>/t/hang.fifo\nwhile :; do read -r -t 30 x <&3; done\n",
    "crash": "#!/usr/bin/bash\n" + HELPER_LOG + "kill -SEGV $$\nsleep 30\n",
    "exit1": "#!/usr/bin/bash\n" + HELPER_LOG + "exit 1\n",
    # the production source built for the host, under the fakefb.so test double
    "real": "#!/usr/bin/bash\n" + HELPER_LOG +
            "LD_PRELOAD=/t/fakefb.so exec /t/animator-host \"$@\"\n",
}


class Ctx:
    def __init__(self, work, busybox, blockdev, keep):
        self.work = work
        self.busybox = busybox
        self.blockdev = blockdev
        self.keep = keep
        self.n = 0
        self.notes = []
        self.animator = os.path.join(work, "animator-host")
        self.shim = os.path.join(work, "fakefb.so")

    def note(self, line):
        print(f"  {line}")
        self.notes.append(line)


class Result:
    def __init__(self):
        self.lines = []        # (t, text) of /init stdout+stderr
        self.pings = []        # (t, byte) written to /dev/watchdog
        self.scans = []        # (n_bootlog_lines, [pid:state:comm, ...])
        self.bootlog = []
        self.rc = None
        self.timed_out = False
        self.helper_log = []
        self.kmsg = []
        self.events = []

    def t_of(self, needle):
        for t, text in self.lines:
            if needle in text:
                return t
        return None

    def has(self, needle):
        return self.t_of(needle) is not None

    def text(self):
        return "\n".join(text for _, text in self.lines)

    @property
    def init_path_s(self):
        a, b = self.t_of("STAGE: banner"), self.t_of("STAGE: switch_root /newroot")
        return None if a is None or b is None else b - a

    def reaped_rc(self):
        m = re.search(r"first-frame helper reaped \(rc=(\d+)\)", self.text())
        return int(m.group(1)) if m else None

    def scan_after(self, needle):
        """Processes recorded right after the bootlog line containing needle."""
        for i, line in enumerate(self.bootlog):
            if needle in line:
                for n, procs in self.scans:
                    if n == i + 1:
                        return procs
        return None


def read_lines(pipe, sink, on_line):
    for raw in iter(pipe.readline, b""):
        text = raw.decode(errors="replace").rstrip("\n")
        sink.append((time.monotonic(), text))
        on_line(text)
    pipe.close()


def read_pty(fd, sink, stop):
    while not stop.is_set():
        try:
            data = os.read(fd, 64)
        except OSError:
            return
        if not data:
            return
        t = time.monotonic()
        for b in data:
            sink.append((t, b))


def make_root(ctx, case, init_text):
    ctx.n += 1
    root = os.path.join(ctx.work, f"run-{ctx.n:03d}")
    for d in ("bin", "etc", "proc", "sys", "dev", "t", "fbdev", "pflog", "newroot/usr/sbin",
              "newroot/usr/bin", "newroot/usr/lib/systemd", "newroot/usr/lib/aarch64-linux-gnu",
              "t/sys/class/vtconsole/vtcon0", "t/sys/class/graphics/fbcon", "t/fakefb",
              "lib/pocketforge-first-frame"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    os.symlink("usr/lib64", os.path.join(root, "lib64"))
    for name, text in (("busybox", STUB_BUSYBOX), ("switch_root", STUB_SWITCH_ROOT),
                       ("sh", STUB_SH)):
        write(os.path.join(root, "bin", name), text, 0o755)
    write(os.path.join(root, "init"), init_text, 0o755)
    write(os.path.join(root, "t/prelude.sh"), PRELUDE)
    write(os.path.join(root, "etc/pocketforge-initrd-version"), "test-norm\n")
    if case.get("dev"):
        write(os.path.join(root, "etc/pocketforge-selfflash"), "self-flash (test)\n")
    if case.get("m1b"):
        write(os.path.join(root, "etc/pocketforge-m1b-mode"), "m1b (test)\n")
    if case.get("flag"):
        os.makedirs(os.path.join(root, "sfp5/var/tmp"))
        write(os.path.join(root, "sfp5/var/tmp/pf-selfflash.flag"),
              f"PF_FLAG=1\nver=1\nstate={case['flag']}\ntries=0\n")
    # rootfs the pre-switch_root verification inspects
    write(os.path.join(root, "newroot/usr/lib/systemd/systemd"), "#!/bin/false\n", 0o755)
    write(os.path.join(root, "newroot/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"), "")
    for link in ("sbin", "lib", "bin"):
        os.symlink(f"usr/{link}", os.path.join(root, "newroot", link))
    # fakefb's /sys: a bound fbcon, as on the device at first light
    write(os.path.join(root, "t/sys/class/vtconsole/vtcon0/name"), "(S) dummy device\n")
    write(os.path.join(root, "t/sys/class/vtconsole/vtcon0/bind"), "0\n")
    if case.get("fbcon", True):
        os.makedirs(os.path.join(root, "t/sys/class/vtconsole/vtcon1"))
        write(os.path.join(root, "t/sys/class/vtconsole/vtcon1/name"), "(M) frame buffer device\n")
        write(os.path.join(root, "t/sys/class/vtconsole/vtcon1/bind"), "1\n")
        write(os.path.join(root, "t/sys/class/graphics/fbcon/rotate"), "3\n")
    write(os.path.join(root, "t/kmsg"), "")
    os.mkfifo(os.path.join(root, "t/hang.fifo"))
    payload = case.get("payload", "absent")
    ffdir = os.path.join(root, "lib/pocketforge-first-frame")
    if payload != "absent":
        write(os.path.join(ffdir, "pocketforge-boot-animator"), FAKE_HELPERS[payload], 0o755)
        shutil.copyfile(FRAME0, os.path.join(ffdir, "frame-000.png"))
    if payload == "real":
        shutil.copyfile(ctx.animator, os.path.join(root, "t/animator-host"))
        os.chmod(os.path.join(root, "t/animator-host"), 0o755)
        shutil.copyfile(ctx.shim, os.path.join(root, "t/fakefb.so"))
    if ctx.busybox:
        shutil.copyfile(ctx.busybox, os.path.join(root, "t/busybox-arm64"))
        os.chmod(os.path.join(root, "t/busybox-arm64"), 0o755)
    return root


def write(path, text, mode=0o644):
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, mode)


def run_init(ctx, shell, case, init_text=None, timeout=20.0):
    init_text = init_text if init_text is not None else open(INIT).read()
    root = make_root(ctx, case, init_text)
    res = Result()
    master, slave = os.openpty()
    tty.setraw(slave)
    slave_path = os.ttyname(slave)
    env = {
        "PATH": "/bin:/usr/bin", "HOME": "/", "TERM": "linux",
        "PF_FF_FB": "/fbdev/fb0",
        "T_ROOT_DELAY": str(case.get("root_delay", "")),
        # fakefb.so (only the "real" helper loads it)
        "FAKEFB_STATE": "/t/fakefb",
        "FAKEFB_BACKING": "/fbdev/fb0",
        "FAKEFB_GEOM": ",".join(str(v) for v in (*case.get("geom", G_DRM)[:4], 32,
                                                 case.get("geom", G_DRM)[4])),
        "FAKEFB_ID": "sun4i-drmdrmfb",
        "FAKEFB_DRM": case.get("drm", "prop:Left Side Up"),
        "FAKEFB_REDIRECT": "/sys=/t/sys;/dev/kmsg=/t/kmsg",
    }
    if case.get("fake_d"):
        env["T_FAKE_D"] = "1"
        env["PF_FF_PROC"] = "/t/fakeproc"
    cmd = ["bwrap", "--unshare-pid", "--die-with-parent", "--bind", root, "/",
           "--ro-bind", "/usr", "/usr", "--ro-bind", "/etc/ld.so.cache", "/etc/ld.so.cache",
           "--proc", "/proc", "--dev", "/dev", "--dev-bind", slave_path, "/dev/watchdog"]
    if case.get("dev"):
        # [ -b ] must hold for the enumerated rootfs partition. nodev + ro: the
        # node can be stat()ed but never opened; every reader of it is stubbed.
        cmd += ["--ro-bind", ctx.blockdev, "/dev/mmcblk0p5"]
    cmd += ["--clearenv"]
    for k, v in env.items():
        cmd += ["--setenv", k, v]
    cmd += ["--chdir", "/"]
    body = ". /t/prelude.sh; . /init"
    if shell == "bash":
        cmd += ["/usr/bin/bash", "-c", body]
    else:
        cmd += ["/usr/bin/qemu-aarch64-static", "/t/busybox-arm64", "sh", "-c", body]

    fb_at = case.get("fb_delay")

    def on_line(text):
        if fb_at is not None and "STAGE: banner" in text:
            threading.Timer(fb_at, make_fb, args=(root, case)).start()

    stop = threading.Event()
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    t_out = threading.Thread(target=read_lines, args=(p.stdout, res.lines, on_line))
    t_pty = threading.Thread(target=read_pty, args=(master, res.pings, stop), daemon=True)
    t_out.start()
    t_pty.start()
    try:
        res.rc = p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        res.timed_out = True
        p.kill()
        res.rc = p.wait()
    t_out.join(5)
    time.sleep(0.05)       # let the pty drain the last keepalive
    stop.set()
    os.close(slave)
    os.close(master)
    t_pty.join(1)
    res.bootlog = readlines(os.path.join(root, "pflog/bootlog.txt"))
    for line in readlines(os.path.join(root, "t/scan.log")):
        parts = line.split()
        res.scans.append((int(parts[1]), parts[2:]))
    res.helper_log = readlines(os.path.join(root, "t/helper.log"))
    res.kmsg = [ln for ln in readlines(os.path.join(root, "t/kmsg")) if ln]
    res.events = readlines(os.path.join(root, "t/fakefb/events.log"))
    res.root = root
    return res


def make_fb(root, case):
    xres, yres, xv, yv, stride = case.get("geom", G_DRM)
    tmp = os.path.join(root, "fbdev/.fb0")
    with open(tmp, "wb") as fh:
        fh.truncate(stride * yv)
    os.rename(tmp, os.path.join(root, "fbdev/fb0"))


def readlines(path):
    if not os.path.exists(path):
        return []
    with open(path, errors="replace") as fh:
        return fh.read().splitlines()


# ---- assertions ---------------------------------------------------------------

def check_boot(res, label, *, reap=True, scan_clean=True):
    """The fail-open invariants every case shares. Returns failure strings."""
    fails = []
    if res.timed_out:
        fails.append(f"{label}: /init did not finish (timed out) -- boot held")
        return fails
    if not res.has("STAGE: switch_root /newroot"):
        fails.append(f"{label}: switch_root not reached")
    if res.has("FAILURE:") or res.has("STUB /bin/sh reached"):
        fails.append(f"{label}: fail shell reached")
    if scan_clean:
        # While it runs, the hook is exactly one process: the subshell, which
        # later execs the helper under the same pid (a forking sleep in the
        # wait loop would show up here as a second process).
        m = re.search(r"first-frame helper pid (\d+)", res.text())
        if m:
            start = next(i for i, ln in enumerate(res.bootlog, 1) if "first-frame helper pid" in ln)
            end = next((i for i, ln in enumerate(res.bootlog, 1)
                        if "first-frame helper reaped" in ln or "WARN: first-frame" in ln),
                       len(res.bootlog))
            for n, procs in res.scans:
                if start <= n < end:
                    extra = [e for e in procs if e.split(":")[0] != m.group(1)]
                    if extra:
                        fails.append(f"{label}: hook is more than one process while waiting "
                                     f"(after bootlog line {n}): {' '.join(extra)}")
                        break
        # Right after the reap: nothing the hook started may still exist (this
        # is what an orphaned child of the waiting subshell would violate).
        if res.has("first-frame helper reaped"):
            after = res.scan_after("first-frame helper reaped")
            if after:
                fails.append(f"{label}: processes alive right after the reap: {' '.join(after)}")
        at = res.scan_after("STAGE: switch_root /newroot")
        if at is None:
            fails.append(f"{label}: no process probe at switch_root")
        elif at:
            fails.append(f"{label}: processes alive at switch_root: {' '.join(at)}")
    return fails


def expect(cond, fails, msg):
    if not cond:
        fails.append(msg)


# ---- cases ----------------------------------------------------------------------

CASES = {
    # name: (case dict, checker)
}


def case(name, **spec):
    def deco(fn):
        CASES[name] = (spec, fn)
        return fn
    return deco


@case("absent", payload="absent", root_delay=0.2)
def c_absent(res, label):
    f = check_boot(res, label)
    expect(not res.has("first-frame"), f, f"{label}: hook logged without a payload: "
           f"{[t for _, t in res.lines if 'first-frame' in t]}")
    return f


@case("paint", payload="real", fb_delay=0.10, root_delay=0.8)
def c_paint(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 0, f, f"{label}: reaped rc={res.reaped_rc()} (want 0)")
    want = ('pf-boot-splash: first-frame presented src=first-frame rotation=ROTATE_90 '
            'orientation="Left Side Up" source=drm-connector pan=ok')
    expect(len(res.kmsg) == 1 and want in res.kmsg[0], f,
           f"{label}: kmsg {res.kmsg!r} (want exactly one first-frame marker)")
    expect(any(e.split()[1:2] == ["pan"] for e in res.events), f,
           f"{label}: no pan in fakefb events")
    expect(res.helper_log and "--first-frame --frames-dir /lib/pocketforge-first-frame"
           in res.helper_log[0], f, f"{label}: helper argv {res.helper_log!r}")
    return f


@case("orientation-unreadable", payload="real", fb_delay=0.10, root_delay=0.8,
      drm="noprop", fbcon=False)
def c_orient(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 0, f, f"{label}: reaped rc={res.reaped_rc()} (want 0)")
    expect(res.kmsg == [], f, f"{label}: painted/marked with unknown orientation: {res.kmsg!r}")
    expect(not any(e.split()[1:2] == ["pan"] for e in res.events), f, f"{label}: panned")
    expect(res.has("panel orientation unknown"), f, f"{label}: helper did not say why")
    return f


@case("bad-geometry", payload="real", fb_delay=0.10, root_delay=0.8,
      geom=(1280, 720, 1280, 720, 5120))
def c_geom(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 1, f, f"{label}: reaped rc={res.reaped_rc()} (want 1)")
    return f


@case("fb0-never-killed-waiting", payload="hang", root_delay=0.3)
def c_never_killed(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 137, f, f"{label}: reaped rc={res.reaped_rc()} (want 137: "
           "SIGKILLed while still waiting)")
    expect(res.helper_log == [], f, f"{label}: helper exec'd without fb0")
    return f


@case("fb0-never-bound", payload="hang", root_delay=FF_BOUND_S + 0.6)
def c_never_bound(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 124, f, f"{label}: reaped rc={res.reaped_rc()} (want 124: the "
           f"wait gave up by itself within {FF_BOUND_S} s)")
    expect(res.helper_log == [], f, f"{label}: helper exec'd without fb0")
    return f


@case("hang-killed", payload="hang", fb_delay=0.05, root_delay=0.3)
def c_hang(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 137, f, f"{label}: reaped rc={res.reaped_rc()} (want 137)")
    expect(len(res.helper_log) == 1, f, f"{label}: helper not exec'd once: {res.helper_log!r}")
    return f


@case("crash", payload="crash", fb_delay=0.05, root_delay=0.3)
def c_crash(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 139, f, f"{label}: reaped rc={res.reaped_rc()} (want 139)")
    return f


@case("exit1", payload="exit1", fb_delay=0.05, root_delay=0.3)
def c_exit1(res, label):
    f = check_boot(res, label)
    expect(res.reaped_rc() == 1, f, f"{label}: reaped rc={res.reaped_rc()} (want 1)")
    return f


@case("unreapable", payload="hang", fb_delay=0.05, root_delay=0.3, fake_d=True)
def c_unreapable(res, label):
    # /proc (the PF_FF_PROC seam) reports the helper in uninterruptible sleep
    # forever: the reap must give up inside its bound and let boot continue.
    f = check_boot(res, label, scan_clean=False)
    expect(res.has("first-frame helper pid") and res.has("still in state D after SIGKILL"),
           f, f"{label}: no give-up WARN")
    t_mount = res.t_of("STAGE: mount /dev/mmcblk0p5")
    t_warn = res.t_of("still in state D after SIGKILL")
    if t_mount is not None and t_warn is not None:
        ctx_note = t_warn - t_mount
        expect(ctx_note <= BUDGET_S, f, f"{label}: give-up took {ctx_note * 1e3:.1f} ms "
               f"(> {BUDGET_S * 1e3:.0f} ms)")
    return f


@case("self-flash-mode", payload="hang", fb_delay=0.05, root_delay=0.1, dev=True,
      flag="idle")
def c_selfflash(res, label):
    f = check_boot(res, label)
    t_reap = res.t_of("first-frame helper reaped")
    t_recover = res.t_of("selfflash: state=idle")
    expect(t_reap is not None and t_recover is not None and t_reap < t_recover, f,
           f"{label}: helper not reaped before selfflash_recover ran")
    at = res.scan_after("selfflash: state=idle")
    expect(at == [], f, f"{label}: processes alive during self-flash recovery: {at}")
    return f


@case("m1b-mode", payload="hang", fb_delay=0.05, m1b=True)
def c_m1b(res, label):
    f = []
    expect(res.has("STAGE: M1.B mode") and res.has("STUB /bin/sh reached"), f,
           f"{label}: M1.B shell not reached")
    expect(not res.has("first-frame helper pid"), f, f"{label}: helper started in M1.B mode")
    return f


# ---- runners --------------------------------------------------------------------

def shells(ctx):
    out = ["bash"]
    if ctx.busybox:
        out.append("ash")
    return out


def run_case(ctx, shell, name, init_text=None):
    spec, fn = CASES[name]
    res = run_init(ctx, shell, spec, init_text)
    return res, fn(res, f"{shell}/{name}")


def test_cases(ctx):
    fails = []
    for shell in shells(ctx):
        for name in CASES:
            res, f = run_case(ctx, shell, name)
            status = "PASS" if not f else "FAIL"
            ctx.note(f"{status} {shell}/{name}: rc={res.reaped_rc()} "
                     f"init_path={fmt_ms(res.init_path_s)}")
            fails += f
    assert not fails, "\n".join(fails)


def fmt_ms(s):
    return "n/a" if s is None else f"{s * 1e3:.1f}ms"


def test_budget(ctx):
    """<= 50 ms added to the init path (banner -> switch_root), per shell, for the
    worst cases: the helper hung (SIGKILL + reap) and killed mid-wait."""
    fails = []
    specs = {"no-payload": {"payload": "absent", "root_delay": 0.3},
             "hang-killed": {"payload": "hang", "fb_delay": 0.05, "root_delay": 0.3},
             "killed-waiting": {"payload": "hang", "root_delay": 0.3}}
    for shell in shells(ctx):
        # interleaved, so host drift lands on every variant alike
        samples = {k: [] for k in specs}
        for _ in range(7):
            for k, spec in specs.items():
                r = run_init(ctx, shell, spec)
                fails.extend(check_boot(r, f"{shell}/budget-{k}"))
                samples[k].append(r.init_path_s)
        bv = samples["no-payload"]
        base = statistics.median(bv)
        for label in ("hang-killed", "killed-waiting"):
            v = samples[label]
            m = statistics.median(v)
            delta = m - base
            ctx.note(f"budget {shell}/{label}: init path median {m * 1e3:.1f} ms vs no-payload "
                     f"{base * 1e3:.1f} ms -> +{delta * 1e3:.1f} ms (<= {BUDGET_S * 1e3:.0f})")
            if delta > BUDGET_S:
                fails.append(f"{shell}/{label}: +{delta * 1e3:.1f} ms > {BUDGET_S * 1e3:.0f} ms "
                             f"(samples {[round(x * 1e3, 1) for x in v]} vs "
                             f"{[round(x * 1e3, 1) for x in bv]})")
    assert not fails, "\n".join(fails)


def test_watchdog_cadence(ctx):
    """Dev-image path (self-flash gate): the same keepalive bytes, and every gap
    between consecutive keepalives within 50 ms of the no-payload run."""
    fails = []
    for shell in shells(ctx):
        base = run_init(ctx, shell, {"payload": "absent", "root_delay": 0.1, "dev": True})
        fails.extend(check_boot(base, f"{shell}/cadence-base"))
        for payload, extra in (("real", {"fb_delay": 0.10}), ("hang", {"fb_delay": 0.05})):
            spec = {"payload": payload, "root_delay": 0.1, "dev": True, **extra}
            r = run_init(ctx, shell, spec)
            fails.extend(check_boot(r, f"{shell}/cadence-{payload}"))
            bb = bytes(b for _, b in base.pings)
            rb = bytes(b for _, b in r.pings)
            if not bb or bb != rb:
                fails.append(f"{shell}/cadence-{payload}: keepalive bytes {rb!r} != {bb!r}")
                continue
            gaps_b = [b - a for (a, _), (b, _) in zip(base.pings, base.pings[1:])]
            gaps_r = [b - a for (a, _), (b, _) in zip(r.pings, r.pings[1:])]
            worst = max((gr - gb for gb, gr in zip(gaps_b, gaps_r)), default=0.0)
            ctx.note(f"cadence {shell}/{payload}: {len(rb)} keepalives (all {sorted(set(rb))}), "
                     f"worst gap growth {worst * 1e3:+.1f} ms")
            if worst > BUDGET_S:
                fails.append(f"{shell}/cadence-{payload}: a keepalive gap grew "
                             f"{worst * 1e3:.1f} ms")
    assert not fails, "\n".join(fails)


# Deliberately broken /init copies: each must turn the named case(s) red.
MUTANTS = [
    ("no-handoff-reap", "hang-killed",
     lambda s: s.replace("# Nothing the initrd started may outlive it into switch_root "
                         "(see FIRST LIGHT).\npf_first_frame_reap\n",
                         "# Nothing the initrd started may outlive it into switch_root "
                         "(see FIRST LIGHT).\n")),
    ("forking-sleep-wait", "fb0-never-killed-waiting",
     lambda s: s.replace("read -r -t 0.05 pf_ff_x <&3", "sleep 0.05")),
    ("blocking-wait", "hang-killed",
     lambda s: s.replace('    kill -KILL "$pf_ff_pid" 2>/dev/null\n',
                         '    wait "$pf_ff_pid" 2>/dev/null\n'
                         '    kill -KILL "$pf_ff_pid" 2>/dev/null\n')),
    ("no-kill", "hang-killed",
     lambda s: s.replace('    kill -KILL "$pf_ff_pid" 2>/dev/null\n', "")),
    ("gate-on-exit-code", "crash",
     lambda s: s.replace('log "STAGE: first-frame helper reaped (rc=$pf_ff_rc)"\n',
                         'log "STAGE: first-frame helper reaped (rc=$pf_ff_rc)"\n'
                         '                [ "$pf_ff_rc" = 0 ] || fail "first-frame helper failed"\n')),
    ("unbounded-fb-wait", "fb0-never-bound",
     lambda s: s.replace('[ "$pf_ff_n" -lt 50 ] || exit 124', '[ "$pf_ff_n" -lt 5000 ] || exit 124')),
    ("no-selfflash-reap", "self-flash-mode",
     lambda s: s.replace("                pf_first_frame_reap   # self-flash mode runs with no "
                         "helper (tsp-3rd3.7)\n", "")),
    ("unbounded-give-up", "unreapable",
     lambda s: s.replace('[ "$pf_ff_i" -lt 6 ] || break', '[ "$pf_ff_i" -lt 600 ] || break')),
    ("helper-in-m1b", "m1b-mode",
     lambda s: s.replace("    if [ -f /etc/pocketforge-m1b-mode ]; then\n        return 0\n    fi\n",
                         "")),
]


def test_mutants_red(ctx):
    base = open(INIT).read()
    fails = []
    for mname, cname, mutate in MUTANTS:
        text = mutate(base)
        if text == base:
            fails.append(f"mutant {mname}: did not apply (test out of date)")
            continue
        for shell in shells(ctx):
            res, f = run_case(ctx, shell, cname, init_text=text)
            if f:
                ctx.note(f"RED as intended: {mname} -> {shell}/{cname}: {f[0][:150]}")
            else:
                fails.append(f"mutant {mname}: {shell}/{cname} still passed")
    assert not fails, "\n".join(fails)


# ---- build gate (build-initrd.sh first_frame_decision) ---------------------------

KCONFIG_OK = "CONFIG_DRM_FBDEV_EMULATION=y\nCONFIG_FB_DEVICE=y\nCONFIG_FRAMEBUFFER_CONSOLE=y\n"
GATE_CASES = [
    # (label, extra args, kconfig text or None, expected decision or exit code)
    ("no-args", [], None, "skip display-pipeline-not-given"),
    ("fbdev+7.x", ["--display-pipeline", "fbdev"], KCONFIG_OK, "stage"),
    ("fbdev-no-kconfig", ["--display-pipeline", "fbdev"], None, "skip kernel-config-not-given"),
    ("fbdev+no-FB_DEVICE", ["--display-pipeline", "fbdev"],
     "CONFIG_DRM_FBDEV_EMULATION=y\n# CONFIG_FB_DEVICE is not set\n",
     "skip kernel-lacks-CONFIG_FB_DEVICE"),
    ("fbdev+no-DRM_FBDEV", ["--display-pipeline", "fbdev"], "CONFIG_FB=y\nCONFIG_FB_DEVICE=y\n",
     "skip kernel-lacks-CONFIG_DRM_FBDEV_EMULATION"),
    ("display-none", ["--display-pipeline", "none"], KCONFIG_OK, "skip display-pipeline=none"),
    ("display-drm", ["--display-pipeline", "drm"], KCONFIG_OK, "skip display-pipeline=drm"),
    ("m1b", ["--m1b-mode", "--display-pipeline", "fbdev"], KCONFIG_OK, "skip m1b-mode"),
    ("bad-pipeline", ["--display-pipeline", "fbdevv"], KCONFIG_OK, 2),
    ("missing-kconfig", ["--display-pipeline", "fbdev", "--kernel-config", "/nonexistent"],
     None, 2),
]


def gate_decision(ctx, script, args, kconfig):
    d = tempfile.mkdtemp(dir=ctx.work, prefix="gate-")
    kdir = os.path.join(d, "kernel/lib/modules/7.2.0-pocketforge")
    os.makedirs(kdir)
    write(os.path.join(kdir, "modules.builtin"), "")
    extra = list(args)
    if kconfig is not None:
        write(os.path.join(d, "config"), kconfig)
        extra += ["--kernel-config", os.path.join(d, "config")]
    env = dict(os.environ, PF_GPU_MODEL="open", BUSYBOX_ARM64=os.path.join(d, "absent-busybox"),
               SOURCE_DATE_EPOCH="1700000000")
    r = subprocess.run(["bash", script, "--src", REPO, "--kernel-tsp-dir", os.path.join(d, "kernel"),
                        "--gpu-km-dir", os.path.join(d, "unused"), "--gpu-km-model", "in-tree-7.x",
                        "--kernel-required-modules", "powervr", "--out",
                        os.path.join(d, "initrd.gz"), *extra],
                       capture_output=True, text=True, env=env)
    m = re.search(r"^  first-frame: (.+?) \(display=", r.stdout, re.M)
    return r.returncode, (m.group(1) if m else None), r


def check_gate(ctx, script):
    fails = []
    for label, args, kconfig, want in GATE_CASES:
        rc, decision, r = gate_decision(ctx, script, args, kconfig)
        if isinstance(want, int):
            if rc != want:
                fails.append(f"gate {label}: rc={rc} (want {want}) {r.stderr.strip()[-200:]}")
        elif decision != want:
            fails.append(f"gate {label}: decision {decision!r} (want {want!r})")
        elif "FATAL: baked busybox not found" not in r.stderr:
            fails.append(f"gate {label}: did not reach the staging step: {r.stderr[-200:]}")
    return fails


def test_build_gate(ctx):
    fails = check_gate(ctx, BUILD_INITRD)
    assert not fails, "\n".join(fails)
    ctx.note(f"build gate: {len(GATE_CASES)} decisions as specified")
    # red: a gate that forgets the /dev/fb0 capability must be caught
    text = open(BUILD_INITRD).read()
    bad = text.replace("    grep -qx 'CONFIG_FB_DEVICE=y' \"${KERNEL_CONFIG}\" \\\n"
                       "        || { echo \"skip kernel-lacks-CONFIG_FB_DEVICE\"; return; }\n", "")
    assert bad != text, "build-gate mutant did not apply"
    path = os.path.join(ctx.work, "build-initrd-mutant.sh")
    write(path, bad, 0o755)
    red = check_gate(ctx, path)
    assert red, "mutant build gate (no CONFIG_FB_DEVICE check) still passed"
    ctx.note(f"RED as intended: build gate without the FB_DEVICE check -> {red[0]}")


def test_wiring(ctx):
    """Only the owned-SPL (a133-open-7x-gpu*) assemble branch hands the initrd
    builder the display pipeline and the packaged kernel's .config; the vendor a133
    branch and every other caller hand it nothing (so they cannot stage)."""
    df = open(os.path.join(REPO, "build/Dockerfile.pf")).read()
    sd = open(os.path.join(REPO, "scripts/build-sd-image.sh")).read()
    asm = df[df.index("FROM rootfs AS assemble"):df.index("FROM scratch AS export")]
    fails = []
    for snippet in ("ARG PF_DISPLAY_PIPELINE\n",
                    "COPY --from=kernel /out/build/config /work/kbuild/config\n"):
        if snippet not in asm:
            fails.append(f"Dockerfile.pf assemble stage lacks {snippet.strip()!r}")
    owned = asm[asm.index("  sunxi-spl-booti)"):asm.index("\n  *)")]
    vendor = asm[asm.index("\n  *)"):asm.index("\nesac")]
    wire = 'PF_DISPLAY_PIPELINE="${PF_DISPLAY_PIPELINE}" KERNEL_CONFIG=/work/kbuild/config'
    if wire not in owned:
        fails.append("sunxi-spl-booti assemble branch does not pass the display facts")
    if "KERNEL_CONFIG" in vendor or "PF_DISPLAY_PIPELINE" in vendor:
        fails.append("vendor a133 assemble branch passes display facts (would change it)")
    want = ('if [ -n "${KERNEL_CONFIG}" ]; then\n'
            '    INITRD_ARGS+=(--display-pipeline "${PF_DISPLAY_PIPELINE}" '
            '--kernel-config "${KERNEL_CONFIG}")\nfi\n'
            'bash "${BOARD_DIR}/initrd/build-initrd.sh" "${INITRD_ARGS[@]}"')
    if want not in sd:
        fails.append("build-sd-image.sh does not forward the display facts to build-initrd.sh")
    assert not fails, "\n".join(fails)
    ctx.note("wiring: only the owned-SPL assemble branch forwards display pipeline + kernel .config")


# ---- real initrd in the pinned build container (optional) ------------------------

def test_container_build(ctx, image):
    """Two builds of the 7.x-shaped initrd with the payload are byte-identical;
    the payload is static AArch64; the size delta against the same build with no
    display facts is reported; the shipped /init passes the hook cases."""
    out = os.path.join(ctx.work, "container")
    kdir = os.path.join(out, "kernel/lib/modules/7.2.0-pocketforge")
    os.makedirs(kdir)
    write(os.path.join(kdir, "modules.builtin"), "")
    os.makedirs(os.path.join(out, "gpu-km"))
    write(os.path.join(out, "config"), KCONFIG_OK)
    script = r"""
set -euo pipefail
common=(--src /work/src --kernel-tsp-dir /work/out/kernel --gpu-km-dir /work/out/gpu-km
        --gpu-model open --gpu-km-model in-tree-7.x --kernel-required-modules powervr
        --variant dev)
ff=(--display-pipeline fbdev --kernel-config /work/out/config)
export SOURCE_DATE_EPOCH=1790605388
bash /work/src/boards/tsp/initrd/build-initrd.sh "${common[@]}" "${ff[@]}" --out /work/out/a.gz > /work/out/a.log 2>&1
bash /work/src/boards/tsp/initrd/build-initrd.sh "${common[@]}" "${ff[@]}" --out /work/out/b.gz > /work/out/b.log 2>&1
bash /work/src/boards/tsp/initrd/build-initrd.sh "${common[@]}" --out /work/out/none.gz > /work/out/none.log 2>&1
for f in a b none; do gzip -dc /work/out/$f.gz > /work/out/$f.cpio; done
mkdir -p /work/out/x && cd /work/out/x && cpio -id --quiet < /work/out/a.cpio
aarch64-linux-gnu-readelf -h lib/pocketforge-first-frame/pocketforge-boot-animator | grep -c AArch64 > /work/out/elf.txt
aarch64-linux-gnu-readelf -l lib/pocketforge-first-frame/pocketforge-boot-animator | grep -c INTERP >> /work/out/elf.txt || true
"""
    subprocess.run(["docker", "run", "--rm", "--network", "none", "--user",
                    f"{os.getuid()}:{os.getgid()}", "-v", f"{REPO}:/work/src:ro",
                    "-v", f"{out}:/work/out", image, "bash", "-c", script], check=True)
    sha = {k: hashlib.sha256(open(os.path.join(out, f"{k}.gz"), "rb").read()).hexdigest()
           for k in ("a", "b", "none")}
    size = {k: os.path.getsize(os.path.join(out, f"{k}.gz")) for k in ("a", "b", "none")}
    raw = {k: os.path.getsize(os.path.join(out, f"{k}.cpio")) for k in ("a", "none")}
    assert sha["a"] == sha["b"], f"initrd not reproducible: {sha['a']} != {sha['b']}"
    assert sha["a"] != sha["none"], "payload build equals the no-payload build"
    elf = readlines(os.path.join(out, "elf.txt"))
    assert elf[0].strip() == "1" and elf[1].strip() == "0", f"helper not static AArch64: {elf}"
    x = os.path.join(out, "x")
    assert open(os.path.join(x, "lib/pocketforge-first-frame/frame-000.png"), "rb").read() == \
        open(FRAME0, "rb").read(), "staged frame-000 differs from the committed frame"
    none_list = subprocess.run(["cpio", "-it", "--quiet"], stdin=open(os.path.join(out, "none.cpio")),
                               capture_output=True, text=True).stdout
    assert "pocketforge-first-frame" not in none_list, "payload staged without display facts"
    helper = os.path.getsize(os.path.join(x, "lib/pocketforge-first-frame/pocketforge-boot-animator"))
    ctx.note(f"container build: 2x sha256 {sha['a']} (reproducible); no-payload {sha['none']}")
    ctx.note(f"initrd.gz {size['none']} -> {size['a']} bytes (+{size['a'] - size['none']}); "
             f"cpio {raw['none']} -> {raw['a']} (+{raw['a'] - raw['none']}); "
             f"helper {helper} B static AArch64 stripped, frame-000 {os.path.getsize(FRAME0)} B")
    # The /init actually packed (after build-initrd.sh's open-model transform)
    # runs the core cases too.
    shipped = open(os.path.join(x, "init")).read()
    fails = []
    for shell in shells(ctx):
        for name in ("absent", "paint", "hang-killed", "fb0-never-killed-waiting",
                     "self-flash-mode"):
            res, f = run_case(ctx, shell, name, init_text=shipped)
            fails += f
    assert not fails, "\n".join(fails)
    ctx.note("shipped /init (from the built initrd) passes absent/paint/hang/wait/self-flash")


# ---- setup ----------------------------------------------------------------------

def build_host(ctx):
    cc = os.environ.get("CC", "cc")
    flags = ["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-unused-function"]
    subprocess.run([cc, *flags, "-I", os.path.join(APP, "src"), "-o", ctx.animator,
                    os.path.join(APP, "src/main.c"), "-lm"], check=True)
    subprocess.run([cc, "-O2", "-Wall", "-Wextra", "-fPIC", "-shared", "-o", ctx.shim,
                    os.path.join(APP, "tests/fakefb.c"), "-ldl"], check=True)


def find_blockdev():
    for name in sorted(os.listdir("/dev")):
        path = os.path.join("/dev", name)
        try:
            import stat as st
            if st.S_ISBLK(os.stat(path).st_mode):
                return path
        except OSError:
            continue
    return None


def preflight():
    if not shutil.which("bwrap"):
        raise SystemExit("BLOCKED: bwrap (bubblewrap) is required for the fake-root runs")
    r = subprocess.run(["bwrap", "--unshare-pid", "--ro-bind", "/", "/", "--proc", "/proc",
                        "--dev", "/dev", "true"], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"BLOCKED: bwrap cannot create a sandbox here: {r.stderr.strip()}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--container", help="pinned build image for the real initrd build")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--only", help="comma list of tests to run")
    args = ap.parse_args()
    preflight()
    busybox = os.environ.get("PF_TEST_BUSYBOX_ARM64")
    if busybox:
        got = hashlib.sha256(open(busybox, "rb").read()).hexdigest()
        if got != DEVICE_BUSYBOX_SHA256:
            raise SystemExit(f"PF_TEST_BUSYBOX_ARM64 sha256 {got} is not the initrd busybox "
                             f"{DEVICE_BUSYBOX_SHA256}")
        if not shutil.which("qemu-aarch64-static"):
            raise SystemExit("PF_TEST_BUSYBOX_ARM64 given but qemu-aarch64-static is missing")
    blockdev = find_blockdev()
    if not blockdev:
        raise SystemExit("BLOCKED: no block device node to stand in for the SD partition")
    work = tempfile.mkdtemp(prefix="pf-initrd-ff-")
    ctx = Ctx(work, busybox, blockdev, args.keep)
    print(f"initrd first-frame tests: work={work} shells={shells(ctx)}"
          + ("" if busybox else " (device-shell leg SKIPPED: set PF_TEST_BUSYBOX_ARM64)"))
    tests = [("wiring", test_wiring), ("build_gate", test_build_gate), ("cases", test_cases),
             ("budget", test_budget), ("watchdog_cadence", test_watchdog_cadence),
             ("mutants_red", test_mutants_red)]
    if args.container:
        tests.append(("container_build", lambda c: test_container_build(c, args.container)))
    if args.only:
        keep = set(args.only.split(","))
        tests = [t for t in tests if t[0] in keep]
    failed = 0
    try:
        build_host(ctx)
        for name, fn in tests:
            print(f"[{name}]")
            try:
                fn(ctx)
                print(f"PASS {name}")
            except AssertionError as e:
                failed += 1
                print(f"FAIL {name}: {e}")
            except Exception:
                failed += 1
                print(f"ERROR {name}:\n{traceback.format_exc()}")
    finally:
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
    print(f"initrd first-frame: {'FAIL' if failed else 'PASS'} ({len(tests) - failed}/{len(tests)})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
