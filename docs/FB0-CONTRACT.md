# fb0 contract for app authors

What a display app must do to appear on the panel, and nothing more. This is a
**pointer to an existing mechanism**, not a new specification — the seam it
describes shipped in `tsp-ikk0.11`.

There are **two separate contracts**. Conflating them is the most common error
here, so they are kept apart below: **ownership** (which process may write fb0)
and **presentation** (how pixels reach the panel once you own it).

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

**Who is restored is image-dependent.** The target ships with no `OnSuccess=`;
`scripts/build-rootfs.sh` installs exactly one
`pocketforge-foreground.target.d/10-owner-{animator,menu}.conf` alongside the
enable symlink for whichever UI that image runs. If you edit that selection,
read `10-owner-menu.conf` first: `OnSuccess=` cannot be *overridden* by a
drop-in, only *selected*, because dependency-type settings ignore an empty
assignment and silently merge instead.

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

## 3. Before you trust a visual verdict

The A133 had a boot lottery in which the g2d iommu master enable could come up
off, so **nothing** rendered for **any** display client and the panel showed a
stale previous-boot frame. A black panel was not evidence your app failed, and
a plausible panel was not evidence it worked. The fix is **merged and pinned in
`platform.lock`** (`kernel-sunxi-4.9#19`, `platform#94`), with on-silicon
verification in flight under `tsp-woy3.1`.

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
