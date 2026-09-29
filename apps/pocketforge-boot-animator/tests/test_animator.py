#!/usr/bin/env python3
"""Hermetic tests for pocketforge-boot-animator (bd tsp-3rd3.6).

The production animator source is compiled for the host and run against
tests/fakefb.c (LD_PRELOAD): a regular file stands in for /dev/fb0, a scripted
KMS device for /dev/dri/card0, and /sys, /dev/kmsg and the frame directory
are redirected into a per-test directory. Nothing in the animator knows it is
under test.

The expected orientation of every pixel is NOT taken from the animator: it is
computed from the kernel's own formulas (the connector property ->
drm_client_rotation -> fbcon hint table, and the fbcon putcs cell origin
arithmetic), cited in KERNEL_* below at kernel-sunxi-7.x@03822b3f.

The backlight release (bd tsp-3rd3.14) is checked against a fake
/sys/class/backlight whose bl_power starts at 4 (FB_BLANK_POWERDOWN), as the
open 7.x panel driver's first-paint hold leaves it.

Needs: python3, a host C compiler (cc), git (for the pre-port baseline and the
pre-release helper), and optionally systemd-analyze. Runs in about a minute.

    tests/test_animator.py            # run everything
    tests/test_animator.py -k orient  # only tests whose name contains "orient"
"""

from __future__ import annotations

import argparse
import configparser
import hashlib
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import traceback
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(APP))
sys.path.insert(0, os.path.join(APP, "tools"))
sys.dont_write_bytecode = True     # never leave (or trust) a stale .pyc in the tree
import crop_frames  # noqa: E402

# Last commit that changed the pre-port animator source (tsp-woy3). The vendor
# byte-identity and cost baselines are built from exactly this source.
BASELINE_COMMIT = "08b0f163ba3417e34c332462eeebf22a5eb79b54"
# Image main before the first-frame helper released the backlight (tsp-3rd3.14):
# the negative control for the release checks.
PRE_RELEASE_COMMIT = "ea5ed12ee05e32307454872fc60f73a76c654e68"
SCENE_W, SCENE_H = 1280, 720
REGION = (507, 146, 266, 307)          # the committed frame set's changed rectangle
CFLAGS = ["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-unused-function"]

# ---- the kernel's table, restated independently of main.c ------------------
# connector "panel orientation" enum name -> DRM_MODE_ROTATE_<deg>
# (drm_connector.c:1241-1244 names; drm_client_modeset.c:971-983 mapping)
KERNEL_PROP_TO_DRM_ROTATION = {
    "Normal": 0, "Upside Down": 180, "Left Side Up": 90, "Right Side Up": 270,
}
# DRM_MODE_ROTATE_<deg> -> fbcon hint (drm_fb_helper.c:1682-1702); values are
# FB_ROTATE_UR=0, CW=1, UD=2, CCW=3 (uapi fb.h:235-238)
KERNEL_DRM_ROTATION_TO_FBCON = {0: 0, 90: 3, 180: 2, 270: 1}


def fbcon_cell_origin(fbcon_rotate, row, col, fw, fh, vxres, vyres):
    """Where fbcon draws console cell (row, col): its putcs image.dx/dy.

    UR  bitblit.c:165-166     dx = col*fw,             dy = row*fh
    CW  fbcon_cw.c:135-136    dx = vxres-(row+1)*fh,   dy = col*fw
    UD  fbcon_ud.c:172-173    dx = vxres-(col+1)*fw,   dy = vyres-(row+1)*fh
    CCW fbcon_ccw.c:150-151   dx = row*fh,             dy = vyres-(col+1)*fw
    """
    if fbcon_rotate == 0:
        return col * fw, row * fh
    if fbcon_rotate == 1:
        return vxres - (row + 1) * fh, col * fw
    if fbcon_rotate == 2:
        return vxres - (col + 1) * fw, vyres - (row + 1) * fh
    if fbcon_rotate == 3:
        return row * fh, vyres - (col + 1) * fw
    raise ValueError(fbcon_rotate)


def kernel_placement(prop_name):
    """scene (u, v) -> buffer (x, y), treating each scene pixel as a 1x1
    console cell (row v, column u) drawn by fbcon with the kernel's hint."""
    rot = KERNEL_DRM_ROTATION_TO_FBCON[KERNEL_PROP_TO_DRM_ROTATION[prop_name]]
    swap = rot in (1, 3)
    vxres, vyres = (SCENE_H, SCENE_W) if swap else (SCENE_W, SCENE_H)
    return (lambda u, v: fbcon_cell_origin(rot, v, u, 1, 1, vxres, vyres)), vxres, vyres


# pf-framehost (runtime@2ad0ca76 crates/pf-framehost/src/lib.rs, runtime#101;
# launcher#145 vendors it), transcribed for the informational cross-consumer
# report only. lib.rs:374-395 maps the property to the kernel's fbcon hint and
# then to clockwise degrees (FB_ROTATE_CW -> 90, FB_ROTATE_CCW -> 270), and
# lib.rs:318-331 maps buffer (x, y) -> scene (u, v). The image's launcher guard
# requires launcher 96feb08c, which carries it. Launcher 1e5a3d97 and older
# carried the pre-#101 table, which had Left and Right Side Up swapped (180
# degrees from the kernel).
FRAMEHOST_PROP = {"Normal": 0, "Left Side Up": 270, "Upside Down": 180, "Right Side Up": 90}


def framehost_source(rot, x, y, sw, sh):
    if rot == 0:
        return x, y
    if rot == 90:
        return y, sh - 1 - x
    if rot == 180:
        return sw - 1 - x, sh - 1 - y
    return sw - 1 - y, x


# ---- card: every pixel encodes its own scene coordinate ---------------------

def card_pixel(u, v, flag):
    return bytes((u & 0xFF, v & 0xFF, (u >> 8) | ((v >> 8) << 3) | flag, 0xFF))


def card_rows(x0, y0, w, h, flag):
    rows = []
    for v in range(y0, y0 + h):
        rows.append(b"".join(card_pixel(u, v, flag) for u in range(x0, x0 + w)))
    return rows


def expected_page(prop_name, stride, region_flag_rect=None):
    """Expected BGRX page for the card (optionally with the region frame's
    rectangle carrying flag 0x80), placed by the kernel formulas."""
    place, vxres, vyres = kernel_placement(prop_name)
    page = bytearray(stride * vyres)
    rx, ry, rw, rh = region_flag_rect or (0, 0, 0, 0)
    for v in range(SCENE_H):
        in_v = ry <= v < ry + rh
        for u in range(SCENE_W):
            flag = 0x80 if (in_v and rx <= u < rx + rw) else 0
            x, y = place(u, v)
            o = y * stride + x * 4
            page[o] = (u >> 8) | ((v >> 8) << 3) | flag   # B
            page[o + 1] = v & 0xFF                         # G
            page[o + 2] = u & 0xFF                         # R
            page[o + 3] = 0xFF                             # X
    return bytes(page)


# ---- harness ------------------------------------------------------------------

class Ctx:
    def __init__(self, work):
        self.work = work
        self.bin_new = os.path.join(work, "anim-new")
        self.bin_old = os.path.join(work, "anim-old")
        self.bin_prev = os.path.join(work, "anim-pre-release")
        self.shim = os.path.join(work, "fakefb.so")
        self.real_frames = os.path.join(APP, "frames")
        self.cropped = os.path.join(work, "crop-a", "frames")
        self.manifest_a = os.path.join(work, "crop-a", "frames.sha256")
        self.manifest_b = os.path.join(work, "crop-b", "frames.sha256")
        self.card_dir = os.path.join(work, "card-frames")
        self.report = []
        self.n = 0

    def note(self, line):
        self.report.append(line)
        print("    " + line)


class Run:
    def __init__(self, rc, stderr, events, fb, state, rusage=None):
        self.rc, self.stderr, self.events, self.fb, self.state = rc, stderr, events, fb, state
        self.rusage = rusage

    def pans(self):
        return [ln for ln in self.events if re.match(r"\d+ pan n=", ln)]

    def memory(self):
        for ln in self.events:
            m = re.search(r"vmhwm_kb=(-?\d+) rssanon_kb=(-?\d+) rssfile_kb=(-?\d+)", ln)
            if m:
                return tuple(int(x) for x in m.groups())
        return None

    def has(self, token):
        return any(token in ln for ln in self.events)

    def first(self, token):
        for i, ln in enumerate(self.events):
            if token in ln:
                return i
        return None


def geom_str(xres, yres, xv, yv, stride):
    return f"{xres},{yres},{xv},{yv},32,{stride}"


def run_animator(ctx, binary, *, geom, fb_id, drm="absent", fbcon=None, frames=None,
                 args=(), term_at=None, snap=(), timeout=30, nohash=False,
                 backlight=("backlight",), env_extra=None):
    """fbcon: None (no fbcon vtconsole) or (bound: bool, rotate: str).
    backlight: None (no /sys/class/backlight) or device names, each with a
    bl_power reading 4 (held dark); a name ending in ":dir" gets a directory
    where bl_power should be, so opening it for writing fails."""
    ctx.n += 1
    root = os.path.join(ctx.work, f"run-{ctx.n:03d}")
    state = os.path.join(root, "state")
    if backlight is not None:
        os.makedirs(os.path.join(root, "sys/class/backlight"))
        for dev in backlight:
            name, _, kind = dev.partition(":")
            d = os.path.join(root, "sys/class/backlight", name)
            os.makedirs(d)
            if kind == "dir":
                os.makedirs(os.path.join(d, "bl_power"))
            else:
                with open(os.path.join(d, "bl_power"), "w") as fh:
                    fh.write("4\n")
    os.makedirs(os.path.join(root, "sys/class/vtconsole/vtcon0"))
    os.makedirs(os.path.join(root, "sys/class/graphics/fbcon"))
    os.makedirs(os.path.join(root, "dev"))
    os.makedirs(state)
    with open(os.path.join(root, "sys/class/vtconsole/vtcon0/name"), "w") as fh:
        fh.write("(S) dummy device\n")
    with open(os.path.join(root, "sys/class/vtconsole/vtcon0/bind"), "w") as fh:
        fh.write("0\n")
    if fbcon is not None:
        os.makedirs(os.path.join(root, "sys/class/vtconsole/vtcon1"))
        with open(os.path.join(root, "sys/class/vtconsole/vtcon1/name"), "w") as fh:
            fh.write("(M) frame buffer device\n")
        with open(os.path.join(root, "sys/class/vtconsole/vtcon1/bind"), "w") as fh:
            fh.write("1\n" if fbcon[0] else "0\n")
        with open(os.path.join(root, "sys/class/graphics/fbcon/rotate"), "w") as fh:
            fh.write(fbcon[1] + "\n")
    open(os.path.join(root, "dev/kmsg"), "w").close()
    xres, yres, xv, yv, stride = geom
    backing = os.path.join(root, "fb0")
    with open(backing, "wb") as fh:
        fh.truncate(stride * yv)
    anim = frames or ctx.cropped
    env = dict(os.environ)
    env.update({
        "LD_PRELOAD": ctx.shim,
        "FAKEFB_STATE": state,
        "FAKEFB_BACKING": backing,
        "FAKEFB_GEOM": geom_str(*geom),
        "FAKEFB_ID": fb_id,
        "FAKEFB_DRM": drm,
        "FAKEFB_REDIRECT": ";".join([
            f"/sys={root}/sys",
            f"/dev/kmsg={root}/dev/kmsg",
            f"/opt/pocketforge/boot-anim/frames={anim}",
        ]),
        "FAKEFB_SNAP": ",".join(str(s) for s in snap),
    })
    if term_at is not None:
        env["FAKEFB_TERM_AT_PAN"] = str(term_at)
    if nohash:
        env["FAKEFB_NOHASH"] = "1"
    env.update(env_extra or {})
    p = subprocess.Popen([binary, *args], env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    while True:
        pid, status, rusage = os.wait4(p.pid, os.WNOHANG)
        if pid:
            break
        if time.monotonic() > deadline:
            p.kill()
            pid, status, rusage = os.wait4(p.pid, 0)
            raise AssertionError(f"animator did not exit within {timeout}s")
        time.sleep(0.01)
    p.returncode = os.waitstatus_to_exitcode(status)
    stderr = p.stderr.read().decode(errors="replace")
    p.stdout.close()
    p.stderr.close()
    events_path = os.path.join(state, "events.log")
    events = open(events_path).read().splitlines() if os.path.exists(events_path) else []
    with open(backing, "rb") as fh:
        fb = fh.read()
    run = Run(p.returncode, stderr, events, fb, state, rusage)
    run.root = root
    return run


def read_state(run, name):
    with open(os.path.join(run.state, name), "rb") as fh:
        return fh.read()


def kmsg_lines(run):
    with open(os.path.join(run.root, "dev/kmsg")) as fh:
        return [ln for ln in fh.read().splitlines() if ln]


def vtcon1_bind(run):
    path = os.path.join(run.root, "sys/class/vtconsole/vtcon1/bind")
    return open(path).read().strip() if os.path.exists(path) else None


def bl_power(run, name="backlight"):
    path = os.path.join(run.root, "sys/class/backlight", name, "bl_power")
    return open(path).read() if os.path.isfile(path) else None


BL_ON = "<6>pf-boot-splash: backlight on src=first-frame device={}"


# geometries: (xres, yres, xres_virtual, yres_virtual, line_length)
G_VENDOR = (1280, 720, 1280, 1440, 5120)          # disp2: landscape, double-buffered
G_DRM_PORTRAIT = (720, 1280, 720, 1280, 2880)     # 7.x DRM fbdev, OVERALLOC=100
G_DRM_PORTRAIT_PADDED = (720, 1280, 720, 1280, 3072)
G_DRM_LANDSCAPE = (1280, 720, 1280, 720, 5120)
DRM_ID = "sun4i-drmdrmfb"
VENDOR_ID = "legacy-disp2"
ORIENT_GEOM = {
    "Normal": G_DRM_LANDSCAPE, "Upside Down": G_DRM_LANDSCAPE,
    "Left Side Up": G_DRM_PORTRAIT_PADDED, "Right Side Up": G_DRM_PORTRAIT,
}


# ---- setup ------------------------------------------------------------------

def build(ctx):
    cc = os.environ.get("CC", "cc")
    src = os.path.join(APP, "src")
    subprocess.run([cc, *CFLAGS, "-I", src, "-o", ctx.bin_new, os.path.join(src, "main.c"), "-lm"],
                   check=True)
    old_src_dir = os.path.join(ctx.work, "old-src")
    os.makedirs(old_src_dir)
    old = subprocess.run(["git", "-C", REPO, "show",
                          f"{BASELINE_COMMIT}:apps/pocketforge-boot-animator/src/main.c"],
                         check=True, capture_output=True).stdout
    with open(os.path.join(old_src_dir, "main.c"), "wb") as fh:
        fh.write(old)
    subprocess.run([cc, *CFLAGS, "-I", src, "-o", ctx.bin_old,
                    os.path.join(old_src_dir, "main.c"), "-lm"], check=True)
    prev_src_dir = os.path.join(ctx.work, "pre-release-src")
    os.makedirs(prev_src_dir)
    prev = subprocess.run(["git", "-C", REPO, "show",
                           f"{PRE_RELEASE_COMMIT}:apps/pocketforge-boot-animator/src/main.c"],
                          check=True, capture_output=True).stdout
    with open(os.path.join(prev_src_dir, "main.c"), "wb") as fh:
        fh.write(prev)
    subprocess.run([cc, *CFLAGS, "-I", src, "-o", ctx.bin_prev,
                    os.path.join(prev_src_dir, "main.c"), "-lm"], check=True)
    subprocess.run([cc, "-O2", "-Wall", "-Wextra", "-fPIC", "-shared", "-o", ctx.shim,
                    os.path.join(HERE, "fakefb.c"), "-ldl"], check=True)


def make_card_frames(ctx):
    os.makedirs(ctx.card_dir)
    with open(os.path.join(ctx.card_dir, "frame-000.png"), "wb") as fh:
        fh.write(crop_frames.encode_png(SCENE_W, SCENE_H, card_rows(0, 0, SCENE_W, SCENE_H, 0),
                                        level=1))
    rx, ry, rw, rh = REGION
    with open(os.path.join(ctx.card_dir, "frame-001.png"), "wb") as fh:
        fh.write(crop_frames.encode_png(rw, rh, card_rows(rx, ry, rw, rh, 0x80),
                                        offs=(rx, ry), level=1))


# ---- tests ------------------------------------------------------------------

def test_crop_reproducible(ctx):
    """Build-time crop: deterministic manifest, expected region, frame-000 verbatim."""
    tool = os.path.join(APP, "tools", "crop_frames.py")

    def crop(tag):
        out = os.path.join(ctx.work, f"crop-{tag}")
        return subprocess.run([sys.executable, tool, "--src", ctx.real_frames,
                               "--out", os.path.join(out, "frames"),
                               "--manifest", os.path.join(out, "frames.sha256")],
                              capture_output=True, text=True)

    with ThreadPoolExecutor(2) as pool:
        ra, rb = list(pool.map(crop, ["a", "b"]))
    assert ra.returncode == 0 and rb.returncode == 0, ra.stderr + rb.stderr
    ma, mb = open(ctx.manifest_a, "rb").read(), open(ctx.manifest_b, "rb").read()
    assert ma == mb, "two crop runs produced different manifests"
    digest = hashlib.sha256(ma).hexdigest()
    assert b"region x=507 y=146 w=266 h=307" in ma, ma[:300]
    src0 = open(os.path.join(ctx.real_frames, "frame-000.png"), "rb").read()
    out0 = open(os.path.join(ctx.cropped, "frame-000.png"), "rb").read()
    assert src0 == out0 and hashlib.sha256(out0).hexdigest().startswith("ed689555"), \
        "frame-000 must be copied byte-for-byte"
    chk = subprocess.run(["sha256sum", "-c", "--strict", "--quiet", "frames.sha256"],
                         cwd=os.path.dirname(ctx.manifest_a), capture_output=True, text=True)
    assert chk.returncode == 0, chk.stdout + chk.stderr
    assert "frames.sha256" not in ma.decode().split("#")[-1], "manifest lists itself"
    total = sum(os.path.getsize(os.path.join(ctx.cropped, f)) for f in os.listdir(ctx.cropped))
    ctx.note(f"crop: manifest_sha256={digest} (identical on two runs); "
             f"frames {total} bytes vs {sum(os.path.getsize(os.path.join(ctx.real_frames, f)) for f in os.listdir(ctx.real_frames))} source")


def test_premise_main_refuses_drm_geometry(ctx):
    """Reproduction step 1: the pre-port binary on a 720x1280 DRM fb exits 1, paints nothing."""
    r = run_animator(ctx, ctx.bin_old, geom=G_DRM_PORTRAIT, fb_id=DRM_ID,
                     drm="prop:Right Side Up", frames=ctx.real_frames, timeout=10)
    assert r.rc == 1, r.rc
    assert "unexpected fb0 geometry; expected 1280x720 @32bpp" in r.stderr, r.stderr
    assert r.fb.count(0) == len(r.fb), "pre-port binary painted"
    assert not r.pans()
    ctx.note("premise: pre-port binary on 720x1280 drmfb -> exit 1, 'unexpected fb0 geometry', fb untouched")


def check_orientation_run(ctx, prop, r, stride):
    rx, ry, rw, rh = REGION
    page0 = read_state(r, "pan-0000.raw")
    page1 = read_state(r, "pan-0001.raw")
    exp0 = expected_page(prop, stride)
    assert page0 == exp0, f"{prop}: frame-000 placement differs from the kernel table"
    exp1 = expected_page(prop, stride, region_flag_rect=REGION)
    assert page1 == exp1, f"{prop}: region placement differs from the kernel table"
    return exp0


def test_orientation_goldens(ctx):
    """All four panel-orientation values: every pixel where the kernel's fbcon puts it."""
    first_pages = {}
    for prop, geom in ORIENT_GEOM.items():
        stride = geom[4]
        # loop mode: frame 000 then one region tick, stopped by SIGTERM after pan 1
        r = run_animator(ctx, ctx.bin_new, geom=geom, fb_id=DRM_ID, drm=f"prop:{prop}",
                         fbcon=(True, "0"), frames=ctx.card_dir, term_at=1, snap=(0, 1))
        assert r.rc == 0, (prop, r.rc, r.stderr)
        exp0 = check_orientation_run(ctx, prop, r, stride)
        # ordering: property read on a read-only card0 that is closed before
        # fbcon is unbound, and both before the fb is mapped/painted
        i_open, i_close = r.first("drm-open accmode=rdonly"), r.first("drm-close")
        i_unbind = r.first("vtcon1/bind w")
        i_mmap, i_pan = r.first("fb-mmap"), r.first(" pan n=0 ")
        assert None not in (i_open, i_close, i_unbind, i_mmap, i_pan), r.events
        assert i_open < i_close < i_unbind < i_mmap < i_pan, r.events
        assert not r.has("drm-forced-probe"), "GETCONNECTOR asked for a forced probe"
        assert r.has("vsync"), "region tick did not wait for vblank"
        assert vtcon1_bind(r) == "0", "fbcon not unbound"
        # the systemd animator never touches the backlight (tsp-3rd3.14)
        assert bl_power(r) == "4\n" and not r.has("backlight"), "animator mode wrote bl_power"
        # --first-frame: same frame 000, the marker, then the backlight
        # release; exit 0, no loop
        f = run_animator(ctx, ctx.bin_new, geom=geom, fb_id=DRM_ID, drm=f"prop:{prop}",
                         fbcon=(True, "0"), frames=ctx.card_dir, args=("--first-frame",))
        assert f.rc == 0, (prop, f.stderr)
        assert len(f.pans()) == 1 and f.fb[:len(exp0)] == exp0, prop
        rot = {"Normal": "ROTATE_0", "Upside Down": "ROTATE_180",
               "Left Side Up": "ROTATE_90", "Right Side Up": "ROTATE_270"}[prop]
        want = (f'<6>pf-boot-splash: first-frame presented src=first-frame rotation={rot} '
                f'orientation="{prop}" source=drm-connector pan=ok')
        assert kmsg_lines(f) == [want, BL_ON.format("backlight")], kmsg_lines(f)
        assert bl_power(f) == "0\n", bl_power(f)
        first_pages[prop] = exp0
        ctx.note(f"orientation {prop!r}: all {SCENE_W * SCENE_H} scene px match the kernel fbcon placement "
                 f"(frame 000 + region tick), card0 rdonly closed before unbind+paint")
    ctx.first_pages = first_pages


def test_orientation_fbcon_fallback(ctx):
    """No card0: bound fbcon rotate (derived from the same property) is used."""
    for rotate, prop in (("3", "Left Side Up"), ("1", "Right Side Up")):
        geom = ORIENT_GEOM[prop]
        r = run_animator(ctx, ctx.bin_new, geom=geom, fb_id=DRM_ID, drm="absent",
                         fbcon=(True, rotate), frames=ctx.card_dir, args=("--first-frame",))
        assert r.rc == 0, r.stderr
        assert r.fb[:len(ctx.first_pages[prop])] == ctx.first_pages[prop], rotate
        assert "source=fbcon" in kmsg_lines(r)[0]
    # a status-unknown connector counts when none is connected (kernel fallback)
    r = run_animator(ctx, ctx.bin_new, geom=ORIENT_GEOM["Left Side Up"], fb_id=DRM_ID,
                     drm="unknown-status:Left Side Up", frames=ctx.card_dir, args=("--first-frame",))
    assert r.rc == 0 and r.fb[:len(ctx.first_pages["Left Side Up"])] == ctx.first_pages["Left Side Up"]
    ctx.note("fallback: bound fbcon rotate=3/1 == Left/Right Side Up; status-unknown connector honoured")


def test_orientation_unknown_paints_nothing(ctx):
    """Unreadable/unknown orientation: log, paint nothing, exit 0."""
    cases = [
        ("no card0, no fbcon", "absent", None),
        ("no card0, fbcon UNBOUND reading 0", "absent", (False, "0")),
        ("property absent, no fbcon", "noprop", None),
        ("connected connectors disagree", "conflict", None),
        ("card0 ioctl EIO", "eio", None),
        ("value without enum name", "badname", None),
    ]
    for label, drm, fbcon in cases:
        r = run_animator(ctx, ctx.bin_new, geom=G_DRM_PORTRAIT, fb_id=DRM_ID, drm=drm,
                         fbcon=fbcon, frames=ctx.cropped)
        assert r.rc == 0, (label, r.rc, r.stderr)
        assert "panel orientation unknown" in r.stderr and "painting nothing" in r.stderr, label
        assert r.fb.count(0) == len(r.fb), f"{label}: painted"
        assert not r.pans() and not r.has("fb-mmap"), label
        assert kmsg_lines(r) == [], label
        assert bl_power(r) == "4\n", f"{label}: released the backlight with nothing painted"
        if fbcon is not None:
            assert vtcon1_bind(r) == ("1" if fbcon[0] else "0"), f"{label}: touched fbcon"
    # known orientation that cannot hold the 1280x720 scene: refuse, exit 1
    r = run_animator(ctx, ctx.bin_new, geom=G_DRM_PORTRAIT, fb_id=DRM_ID, drm="prop:Normal",
                     frames=ctx.cropped)
    assert r.rc == 1 and "unexpected fb0 geometry" in r.stderr and r.fb.count(0) == len(r.fb)
    ctx.note(f"unknown orientation: {len(cases)} cases exit 0 with no mmap/pan/kmsg; "
             "Normal on 720x1280 refused (exit 1)")


def test_backlight_release(ctx):
    """--first-frame on DRM: backlight on only after frame 000 is presented (tsp-3rd3.14)."""
    geom, prop = ORIENT_GEOM["Right Side Up"], "Right Side Up"
    marker = ('<6>pf-boot-splash: first-frame presented src=first-frame rotation=ROTATE_270 '
              'orientation="Right Side Up" source=drm-connector pan=ok')

    def first_frame(binary=None, **kw):
        kw.setdefault("drm", f"prop:{prop}")
        kw.setdefault("fbcon", (True, "0"))
        return run_animator(ctx, binary or ctx.bin_new, geom=kw.pop("geom", geom),
                            fb_id=kw.pop("fb_id", DRM_ID), frames=ctx.card_dir,
                            args=("--first-frame",), **kw)

    # released after the present: pan, one vblank, then bl_power
    r = first_frame()
    assert r.rc == 0, r.stderr
    assert kmsg_lines(r) == [marker, BL_ON.format("backlight")], kmsg_lines(r)
    assert bl_power(r) == "0\n", bl_power(r)
    i_pan, i_vsync = r.first(" pan n=0 "), r.first(" vsync")
    i_bl = r.first("open /sys/class/backlight/backlight/bl_power w -> 0")
    assert None not in (i_pan, i_vsync, i_bl), r.events
    assert i_pan < i_vsync < i_bl, r.events
    assert len(r.pans()) == 1

    # negative control: the helper before this change leaves the backlight
    # held, so the checks above fail on it
    old = first_frame(ctx.bin_prev)
    assert old.rc == 0 and len(old.pans()) == 1, old.stderr
    assert bl_power(old) == "4\n" and kmsg_lines(old) == [marker], (bl_power(old), kmsg_lines(old))

    # every backlight device is released
    r = first_frame(backlight=("backlight", "backlight-aux"))
    assert bl_power(r, "backlight") == "0\n" and bl_power(r, "backlight-aux") == "0\n"
    assert sorted(kmsg_lines(r)[1:]) == sorted([BL_ON.format("backlight"),
                                                BL_ON.format("backlight-aux")]), kmsg_lines(r)

    # FBIO_WAITFORVSYNC failing does not stop the release
    r = first_frame(env_extra={"FAKEFB_VSYNC_FAIL": "1"})
    assert r.rc == 0 and bl_power(r) == "0\n", r.stderr
    assert kmsg_lines(r) == [marker, BL_ON.format("backlight")], kmsg_lines(r)
    assert "FBIO_WAITFORVSYNC before backlight release" in r.stderr

    # nothing to release: logged, exit 0, frame still painted
    skipped = '<4>pf-boot-splash: backlight release skipped src=first-frame reason='
    r = first_frame(backlight=None)
    assert r.rc == 0 and len(r.pans()) == 1, r.stderr
    assert kmsg_lines(r) == [marker, skipped + '"/sys/class/backlight: No such file or directory"'], \
        kmsg_lines(r)
    r = first_frame(backlight=())
    assert r.rc == 0 and kmsg_lines(r) == [marker, skipped + '"no backlight device"'], kmsg_lines(r)

    # a write that fails is logged; the kernel fallback owns the backlight
    r = first_frame(backlight=("backlight:dir",))
    assert r.rc == 0, r.stderr
    assert kmsg_lines(r) == [marker, '<4>pf-boot-splash: backlight release failed '
                             'src=first-frame device=backlight error="Is a directory"'], kmsg_lines(r)

    # a failed pan releases nothing
    r = first_frame(env_extra={"FAKEFB_PAN_FAIL": "1"})
    assert r.rc == 0 and bl_power(r) == "4\n", (r.stderr, bl_power(r))
    assert kmsg_lines(r) == [marker.replace("pan=ok", "pan=failed"), skipped + '"pan failed"'], \
        kmsg_lines(r)

    # nothing painted (orientation unknown): nothing released, nothing logged
    r = first_frame(drm="noprop", fbcon=None)
    assert r.rc == 0 and not r.pans(), r.stderr
    assert bl_power(r) == "4\n" and kmsg_lines(r) == [], (bl_power(r), kmsg_lines(r))

    # legacy fbdev (vendor 4.9) has no hold: the backlight is not touched
    r = first_frame(geom=G_VENDOR, fb_id=VENDOR_ID, drm="absent", fbcon=None)
    assert r.rc == 0 and len(r.pans()) == 1, r.stderr
    assert bl_power(r) == "4\n" and not r.has("backlight"), r.events
    assert len(kmsg_lines(r)) == 1 and "src=first-frame" in kmsg_lines(r)[0], kmsg_lines(r)

    ctx.note("backlight release: after pan + vblank on DRM --first-frame only; every device; "
             "vsync failure tolerated; skip/fail logged with exit 0; none on pan failure, "
             "unknown orientation, legacy fbdev or animator mode; pre-release helper leaves it held")


def pan_series(run):
    out = []
    for ln in run.pans():
        m = re.search(r"pan n=(\d+) yoffset=(\d+) fnv=([0-9a-f]+)", ln)
        out.append((int(m.group(1)), int(m.group(2)), m.group(3)))
    return out


def test_vendor_byte_identical(ctx):
    """Vendor 1280x720 disp2: every presented page equals the pre-port animator's."""
    snaps = (0, 1, 2, 5, 6, 15, 16, 47, 48, 51)
    old = run_animator(ctx, ctx.bin_old, geom=G_VENDOR, fb_id=VENDOR_ID,
                       frames=ctx.real_frames, term_at=51, snap=snaps)
    new = run_animator(ctx, ctx.bin_new, geom=G_VENDOR, fb_id=VENDOR_ID,
                       frames=ctx.cropped, term_at=51, snap=snaps)
    assert old.rc == 0 and new.rc == 0, (old.stderr, new.stderr)
    po, pn = pan_series(old), pan_series(new)
    assert len(pn) == 52, len(pn)
    assert po[:52] == pn, "presented pages differ from the pre-port animator"
    for s in snaps:
        assert read_state(old, f"pan-{s:04d}.raw") == read_state(new, f"pan-{s:04d}.raw"), s
    # the pre-port binary cleared to black on SIGTERM and panned once more
    assert len(po) == 53 and po[52][2] == pan_series_black(old), po[52]
    assert not new.has("drm-open") and not new.has("vsync"), "vendor path touched DRM/vsync"
    ctx.note("vendor: 52 pans (intro 0-15, loop 16-47, wrap to 16) byte-identical to "
             f"{BASELINE_COMMIT[:8]} incl. page alternation; pre-port then cleared to black, port holds")
    ctx.vendor_old = old


def pan_series_black(run):
    # FNV-1a 64 of an all-zero 1280x720 page, computed the same way as the shim
    h = 1469598103934665603
    for _ in range(1280 * 720 * 4):
        h = ((h ^ 0) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def test_drm_region_matches_full_frames(ctx):
    """7.x path with the real cropped frames equals the pre-port full frames, rotated.

    The device case: the TSP panel DT rotation = <90> publishes Right Side Up
    (fbcon rotate 1). The four-orientation goldens cover the other values."""
    snaps = (0, 1, 5, 6)
    r = run_animator(ctx, ctx.bin_new, geom=G_DRM_PORTRAIT, fb_id=DRM_ID, drm="prop:Right Side Up",
                     fbcon=(True, "1"), frames=ctx.cropped, term_at=6, snap=snaps)
    assert r.rc == 0, r.stderr
    place, vxres, vyres = kernel_placement("Right Side Up")
    for s in snaps:
        src = read_state(ctx.vendor_old, f"pan-{s:04d}.raw")        # 1280x720 BGRX
        got = read_state(r, f"pan-{s:04d}.raw")
        exp = bytearray(len(got))
        for v in range(SCENE_H):
            row = src[v * 5120:(v + 1) * 5120]
            for u in range(SCENE_W):
                x, y = place(u, v)
                o = y * 2880 + x * 4
                exp[o:o + 4] = row[u * 4:u * 4 + 4]
        assert bytes(exp) == got, f"pan {s}: rotated region composition differs"
    ctx.note("7.x Right Side Up: pans 0,1,5,6 == pre-port full frames rotated by the kernel table")
    ctx.drm_run = r


def test_sigterm_holds_last_frame(ctx):
    """SIGTERM: no clear, no extra pan, exit 0, last frame stays in the buffer."""
    for label, geom, fb_id, drm, fbcon in (
            ("7.x drm", G_DRM_PORTRAIT, DRM_ID, "prop:Right Side Up", (True, "1")),
            ("vendor", G_VENDOR, VENDOR_ID, "absent", None)):
        r = run_animator(ctx, ctx.bin_new, geom=geom, fb_id=fb_id, drm=drm, fbcon=fbcon,
                         frames=ctx.cropped, term_at=6)
        assert r.rc == 0, (label, r.stderr)
        term = read_state(r, "term.raw")
        assert r.fb == term, f"{label}: fb changed after SIGTERM"
        assert r.fb.count(0) != len(r.fb), f"{label}: fb is black"
        assert len(r.pans()) == 7, f"{label}: pan after SIGTERM"
        assert "holding frame 6 on the panel (no clear)" in r.stderr, r.stderr
    ctx.note("SIGTERM: drm and vendor paths exit 0 with the buffer byte-equal to the last presented frame")


def parse_ticks(stderr):
    ticks = []
    for m in re.finditer(r"tick=(\d+) frame=(\d+) decode=([0-9.]+)ms blit=([0-9.]+)ms", stderr):
        ticks.append((int(m.group(1)), float(m.group(3)) + float(m.group(4))))
    return ticks


def test_cost_budget(ctx):
    """--measure: region tick <= 20 % of the pre-port full-frame tick, same host."""
    old = run_animator(ctx, ctx.bin_old, geom=G_VENDOR, fb_id=VENDOR_ID, nohash=True,
                       frames=ctx.real_frames, args=("--measure",), term_at=48)
    new = run_animator(ctx, ctx.bin_new, geom=G_DRM_PORTRAIT, fb_id=DRM_ID, nohash=True,
                       drm="prop:Right Side Up", frames=ctx.cropped, args=("--measure",), term_at=48)
    ven = run_animator(ctx, ctx.bin_new, geom=G_VENDOR, fb_id=VENDOR_ID, nohash=True,
                       frames=ctx.cropped, args=("--measure",), term_at=48)
    to = [t for k, t in parse_ticks(old.stderr) if k >= 1]
    tn = [t for k, t in parse_ticks(new.stderr) if k >= 1]
    tv = [t for k, t in parse_ticks(ven.stderr) if k >= 1]
    mo, mn, mv = statistics.median(to), statistics.median(tn), statistics.median(tv)
    ratio = mn / mo
    parts = []
    for label, r, geom in (("pre-port", old, G_VENDOR), ("7.x region", new, G_DRM_PORTRAIT),
                           ("vendor region", ven, G_VENDOR)):
        ru = r.rusage
        cpu_ms = (ru.ru_utime + ru.ru_stime) * 1000.0
        hwm, anon, filekb = r.memory()
        fbmap_kb = geom[4] * geom[3] // 1024
        parts.append(f"{label}: cpu {cpu_ms:.0f}ms/49 ticks ({cpu_ms / (49 * 62.5) * 100:.1f}% of a core), "
                     f"VmHWM {hwm / 1024:.1f}MiB (incl. <= {fbmap_kb / 1024:.1f}MiB file-backed fake fb), "
                     f"RssAnon at stop {anon / 1024:.1f}MiB")
    first_new = [t for k, t in parse_ticks(new.stderr) if k == 0][0]
    ctx.note(f"cost (host): median decode+blit per tick pre-port full={mo:.2f}ms, "
             f"7.x region rotated={mn:.2f}ms ({100 * ratio:.1f}%), vendor region={mv:.2f}ms "
             f"({100 * mv / mo:.1f}%); 7.x first full frame={first_new:.2f}ms")
    for p in parts:
        ctx.note("cost (host): " + p)
    assert ratio <= 0.20, f"region tick is {100 * ratio:.1f}% of the full-frame tick (> 20%)"
    hwm_new, anon_new, _ = new.memory()
    assert anon_new < 4 * 1024, f"7.x steady RssAnon {anon_new} KiB"
    assert "vm_hwm_kb=" in new.stderr


def test_static_link(ctx):
    """The initrd helper (tsp-3rd3.7) needs a static build of the same source."""
    cc = os.environ.get("CC", "cc")
    out = os.path.join(ctx.work, "anim-static")
    r = subprocess.run([cc, *CFLAGS, "-static", "-I", os.path.join(APP, "src"), "-o", out,
                        os.path.join(APP, "src", "main.c"), "-lm"], capture_output=True, text=True)
    if r.returncode != 0 and "cannot find -lc" in r.stderr:
        ctx.note("static link: SKIPPED (no static libc on this host)")
        return
    assert r.returncode == 0, r.stderr
    ctx.note(f"static link: ok ({os.path.getsize(out)} bytes, host)")


def unit(name):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read(os.path.join(REPO, "rootfs-overlay/etc/systemd/system", name))
    return parser


def test_unit(ctx):
    """Unit: no dev-fb0.device, root-fs-only ordering, Nice >= 0, verify clean."""
    path = os.path.join(REPO, "rootfs-overlay/etc/systemd/system/pocketforge-boot-animator.service")
    text = open(path).read()
    directives = [ln for ln in text.splitlines() if ln and not ln.lstrip().startswith("#")]
    body = "\n".join(directives)
    assert "dev-fb0.device" not in body, "animator still depends on dev-fb0.device"
    assert "sysinit.target" not in body, "animator still orders after sysinit.target"
    u = unit("pocketforge-boot-animator.service")
    assert u["Unit"].get("DefaultDependencies") == "no"
    assert "/dev/fb0" in u["Unit"].get("ConditionPathExists", "") or \
        "ConditionPathExists=/dev/fb0" in body
    assert u["Unit"].get("RequiresMountsFor", "").startswith("/opt/pocketforge/boot-anim")
    nice = int(u["Service"].get("Nice", "0"))
    assert nice >= 0, nice
    assert "--" not in u["Service"]["ExecStart"], "default boot must not pass diagnostic flags"
    # The MainUI hands off at start time, not by Conflicts= (bd tsp-3rd3.12: a
    # Conflicts= in the shared boot transaction deleted this unit's start). The
    # handoff itself is proven by tests/test-panel-owner-boot-handoff.py.
    shell = unit("pf-shell-selected.service")
    assert "pocketforge-boot-animator.service" not in shell["Unit"]["Conflicts"].split()
    assert "pocketforge-boot-animator.service" in shell["Unit"]["After"].split()
    shell_text = open(os.path.join(REPO, "rootfs-overlay/etc/systemd/system/pf-shell-selected.service")).read()
    assert "\nExecStartPre=-+/bin/systemctl stop pocketforge-boot-animator.service\nExecStart=" in shell_text
    assert u["Unit"].get("ConditionDirectoryNotEmpty") == "!/run/pocketforge-panel-owner"
    sa = shutil.which("systemd-analyze")
    if not sa:
        ctx.note("unit: static checks ok; systemd-analyze not installed, verify SKIPPED")
        return
    root = os.path.join(ctx.work, "unit-root")
    unit_dir = os.path.join(root, "etc/systemd/system")
    os.makedirs(unit_dir)
    os.makedirs(os.path.join(root, "opt/pocketforge/bin"))
    os.makedirs(os.path.join(root, "opt/pocketforge/boot-anim/frames"))
    shutil.copy(ctx.bin_new, os.path.join(root, "opt/pocketforge/bin/pocketforge-boot-animator"))
    for name in ("pocketforge-boot-animator.service", "pocketforge-splash-handoff.target",
                 "pocketforge-foreground.target"):
        shutil.copy(os.path.join(REPO, "rootfs-overlay/etc/systemd/system", name), unit_dir)
    r = subprocess.run([sa, "verify", f"--root={root}", "--man=no",
                        "/etc/systemd/system/pocketforge-boot-animator.service"],
                       capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    assert r.returncode == 0 and "pocketforge-boot-animator" not in out, out
    ctx.note(f"unit: systemd-analyze verify clean ({subprocess.run([sa, '--version'], capture_output=True, text=True).stdout.split()[1]}); "
             f"Nice={nice}; no dev-fb0.device; pf-shell-selected After= + start-time stop, no Conflicts=; yields to a live owner")


TESTS = [
    ("crop", test_crop_reproducible),
    ("premise", test_premise_main_refuses_drm_geometry),
    ("orient-goldens", test_orientation_goldens),
    ("orient-fallback", test_orientation_fbcon_fallback),
    ("orient-unknown", test_orientation_unknown_paints_nothing),
    ("backlight-release", test_backlight_release),
    ("vendor-identical", test_vendor_byte_identical),
    ("drm-region", test_drm_region_matches_full_frames),
    ("sigterm-hold", test_sigterm_holds_last_frame),
    ("cost", test_cost_budget),
    ("static", test_static_link),
    ("unit", test_unit),
]
DEPENDS = {"orient-fallback": ["orient-goldens"], "drm-region": ["vendor-identical"]}


def framehost_report(ctx):
    """Informational (gated in tsp-3rd3.10): would pf-framehost place the card
    the same way as the kernel?"""
    for prop in KERNEL_PROP_TO_DRM_ROTATION:
        place, vxres, vyres = kernel_placement(prop)
        rot = FRAMEHOST_PROP[prop]
        same = opposite = True
        for (x, y) in ((0, 0), (vxres - 1, 0), (0, vyres - 1), (vxres - 1, vyres - 1),
                       (vxres // 3, vyres // 5)):
            u, v = framehost_source(rot, x, y, SCENE_W, SCENE_H)
            kx, ky = place(u, v)
            same &= (kx, ky) == (x, y)
            opposite &= (kx, ky) == (vxres - 1 - x, vyres - 1 - y)
        verdict = "agrees" if same else ("DISAGREES by 180 degrees" if opposite else "DISAGREES")
        ctx.note(f"informational pf-framehost@runtime-2ad0ca76 source_coordinates vs kernel for {prop!r}: {verdict}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", help="run only tests whose name contains this")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="pf-anim-test-")
    ctx = Ctx(work)
    failed = []
    try:
        print("build: new animator, pre-port baseline, fakefb.so")
        build(ctx)
        make_card_frames(ctx)
        selected = [t for t in TESTS if not args.k or args.k in t[0]]
        names = {n for n, _ in selected}
        for n, _ in selected:
            for dep in DEPENDS.get(n, []):
                names.add(dep)
        if "crop" not in names:
            names.add("crop")          # everything else consumes the cropped set
        for name, fn in TESTS:
            if name not in names:
                continue
            t0 = time.monotonic()
            try:
                print(f"RUN  {name}: {fn.__doc__.strip().splitlines()[0]}")
                fn(ctx)
                print(f"PASS {name} ({time.monotonic() - t0:.1f}s)")
            except Exception:
                failed.append(name)
                print(f"FAIL {name}")
                traceback.print_exc()
        framehost_report(ctx)
    finally:
        if args.keep or failed:
            print(f"work dir kept: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    print(f"boot-animator tests: {'FAIL ' + ','.join(failed) if failed else 'PASS'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
