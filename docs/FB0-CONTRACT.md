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

**If your app is a systemd unit**, declare:

```ini
[Unit]
Requires=pocketforge-foreground.target
After=pocketforge-foreground.target
```

**If it is not**, use the sanctioned wrapper (needs root; HIL/test callers use
`sudo -n`):

```sh
pf-take-panel env SDL_VIDEODRIVER=sunxifb /opt/pocketforge/bin/testgles2 --quit-after-ms 15000
```

What happens: activating the target **stops the current owner first** (its
SIGTERM handler clears fb0 to black and exits 0), `After=` orders you behind
that stop, and when you exit the target deactivates (`StopWhenUnneeded=yes`)
and `OnSuccess=` restores the previous owner. A brief black flash at handoff is
accepted by design.

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

> **SDL apps must NOT hand-roll panning.** SDL's `sunxifb` backend already
> pans. This contract binds **raw fbdev writers only**. Adding manual
> `FBIOPAN_DISPLAY` calls around an SDL app is redundant at best — and
> historically SDL's pans carrying a *non-panning* owner's frames into scan-out
> is the origin of the old "z-fight" report.

**Conforming consumers** to copy from: `pf-collect-ui` (in
`pocketforge-os/runtime`) opens and mmaps fb0 and pans every frame;
`apps/pocketforge-placeholder` and `apps/pocketforge-boot-animator` in this
repo do the same, including clearing to black and panning once on SIGTERM so
the next owner inherits a clean panel.

## 3. Which rendering path actually works today

Measured on silicon on the base A133 on **2026-07-27** (`tsp-1pw9`, reported by
`tsp-osr-coord`) — not an opinion, and worth re-checking against that lane
before trusting it as current:

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
evidence rather than a single frame, and before trusting a *negative* verdict
run the positive control —

```sh
pf-take-panel env SDL_VIDEODRIVER=sunxifb /opt/pocketforge/bin/testgles2 --quit-after-ms 15000
```

If `testgles2` does not render, the boot is affected and your verdict is void:
reboot and re-run. If it renders, a negative verdict on your app is real.

---

References: `tsp-ikk0.11` (the seam), `tsp-7kpp` (pan-fight root cause),
`tsp-woy3` (pan-to-present), `tsp-1cl7.1` (launcher integration).
Team memory: `bd memories a133-display-app-contract --json`.
