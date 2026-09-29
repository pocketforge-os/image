# fb0 contract for app authors

What a display app must do to appear on the panel, and nothing more. This is a
**pointer to an existing mechanism**, not a new specification — the seam it
describes shipped in `tsp-ikk0.11`.

There are **two separate contracts**. Conflating them is the most common error
here, so they are kept apart below: **ownership** (which process may write fb0)
and **presentation** (how pixels reach the panel once you own it).

§1–2 are the contract and are stable. §3–4 are **current platform status**, and
every claim there is attributed and dated because it moves — twice on
2026-07-27 a plausible, well-sourced claim about this subsystem turned out to be
wrong on silicon. Check with the lane named before relying on it.

---

## 1. Ownership — join `pocketforge-foreground.target`

fb0 has **exactly one writer at all times**. The boot animator owns it from
early boot and loops until a successor takes over. You do not negotiate this
per app; you join the slot and systemd enforces it.

Before systemd there is one more writer, and it never overlaps the slot: on
initrds built for a DRM-fbdev display (the open 7.x profiles), `/init` runs the
same animator binary in `--first-frame` mode to paint frame 000 at first light,
and kills and reaps it before `switch_root` (`boards/tsp/initrd/init`, FIRST
LIGHT; `tsp-3rd3.7`). No systemd unit can start before that reap.

**The boot-enabled panel owner** is `pf-shell-selected` (MainUI), or the menu or
placeholder on those variants. It hands off from the animator **at start time,
not by `Conflicts=`** (`tsp-3rd3.12`). The animator (`basic.target.wants`) and
the owner (`multi-user.target.wants`) are started by ONE boot transaction. An
owner-side `Conflicts=pocketforge-boot-animator.service` puts a stop job for the
animator into that transaction, and systemd resolves the start/stop pair by
deleting the animator's start. With that `Conflicts=`, the animator never ran
on any owner image.

Instead, each owner:

- orders `After=` the animator's start;
- stops the animator synchronously as its last `ExecStartPre=`
  (`-+/bin/systemctl stop ...`: SIGTERM, hold, exit), so the MainUI waits for
  that stop and never for the animation;
- holds `RuntimeDirectory=pocketforge-panel-owner/%N` while it runs.

The animator's `ConditionDirectoryNotEmpty=!/run/pocketforge-panel-owner` then
makes any later `systemctl start pocketforge-boot-animator` a skip while an
owner holds the panel: the animator yields, and it neither stops the owner nor
writes alongside it. Never add a `Conflicts=` on the animator to a unit enabled
at boot. `tests/test-panel-owner-boot-handoff.py` proves all of this on the real
boot transaction (`systemd --test`) and in a live systemd run.

**If your app is a systemd unit**, declare:

```ini
[Unit]
Requires=pocketforge-foreground.target
After=pocketforge-foreground.target
```

**If it is not**, use the sanctioned wrapper (needs root; HIL/test callers use
`sudo -n`). The SDL video driver depends on the image's GPU profile:

```sh
# closed DDK (vendor PowerVR EGL)
pf-take-panel env SDL_VIDEODRIVER=sunxifb /opt/pocketforge/bin/testgles2 --quit-after-ms 15000
# open GPU (Mesa; /etc/pocketforge-build-id says device=a133-open-*)
pf-take-panel env SDL_VIDEODRIVER=kmsdrm /opt/pocketforge/bin/testgles2 --quit-after-ms 15000
```

The closed-DDK SDL has `sunxifb` and no KMSDRM. The open-GPU SDL has KMSDRM
and no `sunxifb` (`tsp-f3fm.218`, libsdl3-sunxifb#22). sunxifb's window
surface is an EGL surface on native window 0, which only the vendor DDK
accepts, so on Mesa every window failed with `sunxifb: Can't create EGL window
surface`. Naming `kmsdrm` explicitly is also correct on open images built
before that change: their SDL still contains sunxifb and would try it first.
A KMSDRM app becomes DRM master and presents through DRM page flips, not
through fb0. As of 2026-09-29 that path is not yet verified on device (GBM
scanout from Mesa into sun4i-drm, rotated present, fb0 restore after exit).
The checks are `tsp-mc9m.41.924.16.12` (testgles2 on kmsdrm) and the
`tsp-f3fm.215` Poolsuite run.

What happens: activating the target **stops the current owner first**, `After=`
orders you behind that stop, and when you exit the target deactivates
(`StopWhenUnneeded=yes`) and `OnSuccess=` restores the previous owner.

**What the panel shows between the stop and your first present depends on the
owner you displaced** (changed 2026-09-29, `tsp-3rd3.6`):

- The **boot animator holds its last frame**: its SIGTERM handler unmaps fb0
  and exits 0 without clearing or panning. There is no black gap; your first
  full-buffer present replaces the splash frame. So paint the whole buffer on
  your first present, not just the parts you changed.
- The menu and placeholder still clear to black on exit
  (`apps/pocketforge-menu/src/main.c` explains why that clear is kept for
  diagnosis).

A consequence for diagnosis: an app that never presents now leaves a **still**
splash frame after displacing the animator, not a black panel. A still frame
is therefore not evidence that the animator is running. Judge with
burst/motion evidence, as in §4.

An app started **outside** this contract pan-fights the current owner on the
double-buffered fb0 and the panel alternates frames — the symptom originally
misreported as GLES z-fighting (`tsp-7kpp`).

**Environment does not cross into a transient unit.** `systemd-run` does not
inherit your shell's environment, so pass variables *inside* the command line
with `env VAR=x ...`, as above.

**Who is restored is image-dependent — the enabled UI is the restored UI.** The
target ships with no `OnSuccess=`; `scripts/build-rootfs.sh` picks the panel
owner once (`PF_PANEL_OWNER`) and derives both the enable symlink and exactly
one `pocketforge-foreground.target.d/10-owner-{animator,menu,placeholder}.conf`
from it. An unknown owner fails the build rather than shipping a slot with no
restore. If you add a UI variant, add its drop-in in the same change — and read
`10-owner-menu.conf` first: `OnSuccess=` cannot be *overridden* by a drop-in,
only *selected*, because dependency-type settings ignore an empty assignment and
silently merge instead.

## 2. Presentation — pan, or be invisible (raw fbdev writers only)

fb0's scan-out is a **g2d-rotated copy** that refreshes **only on
`FBIOPAN_DISPLAY`**. The panel never scans fb0's own memory. So a raw fbdev
writer that mmaps and blits but never pans is **completely invisible while
being perfectly correct** — its pixels land in a page nothing scans out.

If you write `/dev/fb0` directly: draw into the back page, `msync`, set
`yoffset`, then `FBIOPAN_DISPLAY` — every frame.

> **SDL apps must NOT hand-roll panning.** SDL's `sunxifb` backend (closed
> DDK) already pans, and SDL's KMSDRM backend (open GPU) does not use fb0 at
> all. This contract binds **raw fbdev writers only**. Adding manual
> `FBIOPAN_DISPLAY` calls around an SDL app is redundant at best — and
> historically SDL's pans carrying a *non-panning* owner's frames into scan-out
> is the origin of the old "z-fight" report.

**Conforming consumers** to copy from: `pf-collect-ui` (in
`pocketforge-os/runtime`) opens and mmaps fb0 and pans every frame;
`apps/pocketforge-placeholder` and `apps/pocketforge-boot-animator` in this
repo do the same. The placeholder clears to black and pans once on SIGTERM;
the animator holds its last frame (§1).

### Open 7.x kernel (DRM fbdev emulation)

On the open 7.x kernel (`kernel-sunxi-7.x`, `CONFIG_FB_DEVICE=y` since
`tsp-mc9m.41.923.48`), fb0 is the kernel's DRM fbdev emulation, not disp2. As
of 2026-09-29 this is from kernel source; device confirmation is pending in
`tsp-3rd3.10`.

- Its `FBIOGET_FSCREENINFO` id ends in `drmfb`, which the kernel documents as
  uAPI (`drm_fb_helper.c:1627-1634`).
- The buffer is in **native panel coordinates**: 720×1280 on the TSP, one
  page (`CONFIG_DRM_FBDEV_OVERALLOC=100`). Nothing rotates it for you (the
  sun8i mixer has no plane rotation). A landscape writer rotates in software
  by the DSI connector's `panel orientation` property. That property takes
  its kernel meaning: `Left Side Up` is `DRM_MODE_ROTATE_90`, counter-clockwise,
  the same rotation fbcon uses. `apps/pocketforge-boot-animator/src/main.c`
  holds the table and its kernel citations.
- pf-framehost reads that property with the same kernel meaning from runtime
  `2ad0ca76` (runtime#101), which launcher `96feb08c` (launcher#145) vendors. The
  image's build guards require that pair. Launcher `1e5a3d97` and older read it
  180° apart.
  Physical truth is owned by `tsp-c2b70c69022327ff5fee`, and convergence by
  `tsp-mc9m.60.21.3`.
- It is not yet device-verified whether mmap writes reach the panel without a
  pan. The design note presumes they do, because sun4i has no dirty callback.
  The animator issues `FBIOPAN_DISPLAY` with offset 0 after each update
  anyway.

## 3. Which rendering path actually works today

Measured on silicon on the base A133 on **2026-07-27** (`tsp-1pw9`, reported by
`tsp-osr-coord`) — not an opinion, and worth re-checking against that lane
before trusting it as current. This is the **closed-DDK** stack. On the open
GPU model, SDL uses KMSDRM instead (§1), and its device status is pending:

| Path | Status |
| --- | --- |
| Raw fbdev + `FBIOPAN_DISPLAY` | **Works.** What this repo's own display apps use. |
| Raw GLES2 with your own EGL context (no `SDL_Renderer`) | **Works** — `testgles2` rendered a spinning cube, visible, upright, ~60 fps. |
| `SDL_Renderer` on `sunxifb` | **Currently non-functional. Do not build on it yet.** |

The `SDL_Renderer` failure is *clean*, not a crash, which is why it went
unnoticed: the old `libIMGegl.so` NULL dereference **is** fixed (`testsprite`
runs with `kernel_fault_count=0`, no `SEGV_MAPERR si_addr=0x8`), but on the same
run `SDL_CreateRenderer(win, NULL)` returns **"Couldn't find matching render
driver"**, forcing `--renderer opengles2` gives **"EGL context already
created"**, and the `SDL_WINDOW_OPENGL` variant never reaches the draw loop. GPU,
panel, EGL and presentation are all fine on that same boot — the failure is
specific to SDL's renderer-creation path. Tracked by `tsp-osr-coord` as a
successor defect to `tsp-osr`; **"the `tsp-osr` crash is fixed" does not mean
"SDL RENDER is safe to use".**

If you need GLES today, drive EGL yourself as `testgles2` does.

## 4. Before you trust a visual verdict

The A133 had a boot lottery in which the g2d iommu master enable could come up
off, so **nothing** rendered for **any** display client and the panel showed a
stale previous-boot frame. A black panel was not evidence your app failed, and
a plausible panel was not evidence it worked. Per `tsp-osr-coord` (2026-07-27)
the fix is **merged and pinned in `platform.lock`** (`kernel-sunxi-4.9#19`,
`platform#94`), with on-silicon verification **in flight** under `tsp-woy3.1` —
so treat it as hardened but not yet proven.

Until that verification lands, keep the protocol: judge with **burst/motion**
evidence rather than a single frame.

**Closed DDK only: positive control.** Before trusting a *negative* verdict,
run —

```sh
pf-take-panel env SDL_VIDEODRIVER=sunxifb /opt/pocketforge/bin/testgles2 --quit-after-ms 15000
```

If `testgles2` does not render, the boot is affected and your verdict is void:
reboot and re-run. If it renders, a negative verdict on your app is real. This
inference holds only on the closed DDK, where this `testgles2` path is proven on
silicon (§3).

**Open GPU: informational only, not a positive control.** The open image's SDL
presents through KMSDRM, and that path is not yet verified on device (GBM
scanout from Mesa into sun4i-drm, rotated present, fb0 restore after exit;
§1). A `testgles2` failure there may be that unverified path failing, not the
boot, so it does **not** void a verdict on your app. Run it and record both
results side by side —

```sh
pf-take-panel env SDL_VIDEODRIVER=kmsdrm /opt/pocketforge/bin/testgles2 --quit-after-ms 15000
```

— and judge your app on its own burst/motion evidence. This line becomes a
positive control only after gpu-14's testgles2 KMSDRM rotated-present bench,
`tsp-mc9m.41.924.16.12`, verifies the path on device. Promote it here when
that bead closes with a device PASS.

---

References: `tsp-ikk0.11` (the seam), `tsp-7kpp` (pan-fight root cause),
`tsp-woy3` (pan-to-present), `tsp-1cl7.1` (launcher integration),
`tsp-3rd3.6` (animator hold-last-frame and the open 7.x port).
Team memory: `bd memories a133-display-app-contract --json`.
