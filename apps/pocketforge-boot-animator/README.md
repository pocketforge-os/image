# pocketforge-boot-animator (bd tsp-3rd3.4, open 7.x port tsp-3rd3.6)

Boot animator for `/dev/fb0`. It streams the tsp-3rd3.2 48-frame ember-sweep
set at 16 fps from early boot. It runs until a successor UI takes the panel,
then **holds its last frame** so the handoff has no black gap.

## What it does

1. Opens `/dev/fb0` and chooses a presentation path from **what fb0 is**, never
   from its geometry:
   - **DRM fbdev emulation** (open 7.x kernel). The fb id ends in `drmfb`,
     which the kernel documents as uAPI (`drm_fb_helper.c:1627-1634`).
     The buffer is in native panel coordinates, 720×1280 on the TSP.
   - **Legacy fbdev** (vendor 4.9 disp2). A landscape 1280×720 buffer, with
     the pre-port pan path (see "Pan-to-present").
2. **DRM path: reads the panel orientation** (see "Orientation") and rotates
   the logical 1280×720 scene into the buffer in software. If the orientation
   cannot be read, it logs the reason, **paints nothing, and exits 0**.
3. Unbinds the framebuffer console, found by the vtconsole name `frame buffer
   device` rather than by assuming `vtcon1`, so console text cannot bleed
   through. This happens only after the orientation read, because fbcon's
   rotate attribute is one of the orientation sources.
4. Paints **frame 000 in full once**, then writes one line to `/dev/kmsg`:
   `pf-boot-splash: first-frame presented src=… rotation=… orientation=… source=… pan=…`.
   The tsp-3rd3.9 boot-splash harness keys the lit-black gap on this line.
5. Plays frames **001..015 once** (the intro), then **loops 016..047**.
   Each tick decodes and blits only the **cropped changed region**
   (266×307, 8.9 % of the scene). On the DRM path it blits right after
   `FBIO_WAITFORVSYNC`, then pans to offset 0.
6. On SIGTERM it **holds the last frame**: no clear and no pan. It then
   unmaps and exits 0.

Frame 000 is byte-identical to the u-boot static logo
(`sha256=ed689555…09faed` = `assets/boot-logo/pocketforge-boot.png` in
`mission-control`).

## Orientation (DRM path)

The DRM connector's `panel orientation` property is read **read-only** from
`/dev/dri/card0`, and card0 is closed before anything is painted:

- It uses `GETCONNECTOR` with `count_modes=1`, so it never asks for a forced
  probe.
- It considers the connected connectors, or the status-unknown ones when none
  is connected, the same rule the kernel's fbdev client uses.

If card0 gives no usable value, the fallback is
`/sys/class/graphics/fbcon/rotate`, **but only while the fbcon vtconsole is
bound**. When fbcon is unbound, that attribute reads `0` whatever the panel
is. That `0` is a default, not a reading.

The mapping is the **kernel's**. It has no flags, no geometry guess and no
local policy:

| property value | kernel rotation (`drm_client_modeset.c:971-983`) | fbcon (`drm_fb_helper.c:1682-1702`) | scene (u,v) → buffer (x,y) |
|---|---|---|---|
| `Normal` | `ROTATE_0` | `UR` | (u, v) |
| `Upside Down` | `ROTATE_180` | `UD` | (1279−u, 719−v) |
| `Left Side Up` | `ROTATE_90`, counter-clockwise (`drm_mode.h:159-163`) | `CCW` | (v, 1279−u) |
| `Right Side Up` | `ROTATE_270` | `CW` | (719−v, u) |

The last column is exactly where fbcon draws the same console cell
(`fbcon_ccw.c:150-151`, `fbcon_cw.c:135-136`, `fbcon_ud.c:172-173`).
`Left Side Up` therefore puts the scene's top on the panel's native left
edge, which is the documented meaning (`drm_connector.h:369-370`). The TSP
device tree says `rotation = <270>`, which maps to `Left Side Up`.

This bead does **not** decide which way is physically upright:

- tsp-c2b70c69022327ff5fee owns the physical verdict.
- The launcher's pf-framehost currently maps the same property 180° apart
  (`lib.rs:349-356`, `:318`). The tests report that disagreement for
  information. Convergence is tsp-mc9m.60.21.3, and it is gated in
  tsp-3rd3.10.
- If the kernel's reading is wrong for this panel, the fix belongs in the
  device tree, so that every consumer follows it.

## Frames: build-time crop

Only 8.9 % of the scene changes after frame 000. At image build time,
`tools/crop_frames.py` crops frames 001..047 to the **union** of every pixel
that differs from frame 000. That union is x=507 y=146 w=266 h=307.

- **Placement.** Each crop records its position in a standard PNG `oFFs`
  chunk.
- **Self-check.** The tool recomposes every crop over frame 000 and fails the
  build unless each frame comes back byte-exact.
- **Manifest.** It writes `frames.sha256`, which is `sha256sum -c`
  compatible. The manifest never lists itself. The build installs it at
  `/opt/pocketforge/boot-anim/frames.sha256` and checks it.
- **Frame 000** is copied byte-for-byte, so `PROVENANCE` is unchanged.
- **Size.** 1.46 MB on disk instead of 5.73 MB.
- **Determinism.** The tool uses only the standard library with zlib at
  level 9, and every row uses the PNG Sub filter. Two runs give the same
  manifest. The frame bytes are identical between zlib 1.2.13 (build
  container) and 1.3; only the manifest's `# zlib` header line differs.

The animator also accepts uncropped frames. A frame with no `oFFs` chunk is
a full-scene region. Frame 000 must always be full.

## Pan-to-present (legacy vendor path, bd tsp-woy3)

On the vendor kernel, fb0's scan-out is a **g2d-rotated copy** of fb0
(`CONFIG_SUNXI_DISP2_FB_HW_ROTATION_SUPPORT`). The copy is refreshed only on
`FBIOPAN_DISPLAY`: `fb_g2d_rot` `apply()` rotates the panned page, then
`set_layer_config` commits it. **mmap writes alone never reach the panel.**
The animator therefore blits into the **back** page and pans to it,
alternating pages (`yres_virtual` ≥ 2×`yres`). On a single page it blits in
place and pans to yoffset=0.

The port keeps this path. Frame 000 is painted into both pages first, then
each tick writes the cropped region into the back page. The tests prove that
the page presented at every pan is byte-identical to the pre-port animator
(`08b0f163`) through intro, loop and wrap.

## Exit contract (takeover handshake)

Successors stop the animator through systemd:

- `pf-shell-selected` (MainUI), and the menu and the placeholder, stop it from
  their last `ExecStartPre=` (`-+/bin/systemctl stop ...`), ordered
  `After=` its start. They do **not** use `Conflicts=`. They start in the same
  boot transaction as the animator, and an owner-side `Conflicts=` made systemd
  delete the animator's start job, so it never ran (`tsp-3rd3.12`).
- `pocketforge-foreground.target` stops it for transient apps (`pf-take-panel`),
  and `pocketforge-splash-handoff.target` also stops it. Both use `Conflicts=`,
  and neither is in the boot transaction.

The animator yields to a live owner. While an owner holds
`RuntimeDirectory=pocketforge-panel-owner/%N`, its
`ConditionDirectoryNotEmpty=!/run/pocketforge-panel-owner` turns a later start
(for example a HIL script "restoring" the animator) into a skip. See
`docs/FB0-CONTRACT.md` §1 and `tests/test-panel-owner-boot-handoff.py`.

On SIGTERM the animator **holds its last frame** and exits 0 within
milliseconds. The successor's first present replaces the whole buffer, so
splash → successor has no black gap (design note §3.5). This replaces the
tsp-3rd3.4 contract "clear fb0 to black on SIGTERM".

Diagnosis consequence: an app that displaces the animator and never presents
now leaves a **still** splash frame on the panel, not a black one. See
`docs/FB0-CONTRACT.md` §1.

Nothing is required to wait on the animator. It is `Type=simple`, and a
stop completes as soon as the process exits.

## Unit and boot cost

The unit is `rootfs-overlay/etc/systemd/system/pocketforge-boot-animator.service`.

- **Ordering.** It orders only on the frame set's mount
  (`RequiresMountsFor=`) with `DefaultDependencies=no`. It does **not** wait
  for udev to tag `dev-fb0.device`, which happens around kernel 6.7 s on
  7.x. `/dev/fb0` is a devtmpfs node from about 2.7 s, and
  `ConditionPathExists=/dev/fb0` stays.
- **Priority.** `Nice=10` and the lowest best-effort I/O priority. Under boot
  load it drops frames, because its schedule is absolute, rather than delay
  boot.

Budget. Measured off-device by the hermetic `--measure` test on an x86 host;
A133 numbers are to be measured in tsp-3rd3.10:

| | pre-port (full frame) | port, 7.x region + rotation |
|---|---|---|
| decode+blit per tick (median) | 6.6–8.5 ms | 0.8–0.9 ms (11–12 % of pre-port; gate ≤ 20 %) |
| CPU over 49 ticks at 16 fps | ~16 % of a core | ~2.2 % of a core |
| first frame (full decode + rotated blit) | — | ~14 ms, once |
| VmHWM, including the file-backed test fb | 16.0 MiB | 9.0 MiB |
| RssAnon, steady | — | 0.8 MiB |

The design budget on the A133 is:

- **CPU:** at most 20 % of the pre-port per-tick cost. The pre-port animator
  was measured at about 100 % of a core on the vendor kernel (tsp-woy3).
- **Memory:** a peak VmHWM of about 12 MiB, reached while frame 000 is
  decoded. The steady state is under 2 MiB anonymous memory.
- **Guardrail:** `MemoryMax=32M`.

`--measure` prints `tick=… decode=… blit=… vsync=…` lines, then a summary
with `cpu_ms`, `vm_hwm_kb` and `rss_anon_kb`. It reports VmHWM rather than
`ru_maxrss`, because exec folds the forking parent's peak into `ru_maxrss`.
`acceptance.sh` parses the same `decode=` field as before.

## Modes

| argv | behaviour |
|---|---|
| *(none)* | Boot animator: loops until SIGTERM, then holds the last frame. |
| `--first-frame` | Resolves orientation, unbinds fbcon, paints frame 000, writes the kmsg marker with `src=first-frame`, and exits 0. For the initrd first-light helper (tsp-3rd3.7). |
| `--measure` | Per-tick timing and a CPU/RSS summary, sent to stderr (the journal). |
| `--frames-dir DIR` | Reads `frame-NNN.png` from DIR instead of `/opt/pocketforge/boot-anim/frames`. |

Exit status:

- **0:** painted, **or** orientation unknown (nothing painted).
- **1:** fb0 cannot be opened or queried, or the geometry does not fit the
  scene for the resolved orientation, or frame 000 is unusable.
- **2:** bad argv.

A caller must not gate boot on the exit status.

The binary uses only libc and libm, and it links statically:
`cc -static … src/main.c -lm`. The tests cover this.

## Tests (hermetic, no device)

```sh
apps/pocketforge-boot-animator/tests/test_animator.py        # ~1 min
apps/pocketforge-boot-animator/tests/test_animator.py -k orient
```

The tests compile `src/main.c` for the host and run the production binary
unmodified under `tests/fakefb.c` (LD_PRELOAD):

- A regular file stands in for `/dev/fb0`, with scripted fb ioctls, pan
  hashes and snapshots, and a SIGTERM after pan N.
- A scripted KMS device stands in for `/dev/dri/card0`, with the kernel's
  GETRESOURCES, GETCONNECTOR and GETPROPERTY copy semantics.
- `/sys`, `/dev/kmsg` and the frame directory are redirected into a
  per-test directory.

They cover:

- **Crop.** Reproducible manifest, the expected region, frame 000 copied
  verbatim.
- **Premise.** The pre-port binary exits 1 on a 720×1280 drmfb and paints
  nothing.
- **Orientation goldens.** All four property values are checked on every
  pixel of a card whose pixels encode their own scene coordinates. The
  expected values are recomputed from the fbcon formulas, not from `main.c`.
  The frame-000 paint and a region tick are both checked. Ordering is
  checked too: card0 is read-only and closed, then fbcon is unbound, then the
  fb is mapped and painted. The test also confirms there is no forced probe
  and that exactly one kmsg marker is written.
- **Fallback.** A bound fbcon rotate of 3 or 1; a connector with status
  unknown.
- **Unknown orientation.** Six cases exit 0 with no mmap, no pan and no kmsg
  line. One of them is an unbound fbcon reading 0.
- **Vendor.** 52 pans byte-identical to `08b0f163`.
- **7.x region.** The real cropped frames equal the pre-port full frames,
  rotated.
- **SIGTERM.** The last frame is held on both paths.
- **Cost.** The ≤ 20 % budget.
- **Static link.**
- **Unit.** `systemd-analyze verify`, and the pf-shell-selected start-time
  handoff (no `Conflicts=`) with the yield condition.

The tests also print, for information only, whether pf-framehost's
`source_coordinates` would place the card the same way as the kernel.

## Regenerating the frame set

The frames here are a committed copy of `mission-control/assets/boot-anim/`
(tsp-3rd3.2, owner-confirmed FINAL v2). The source of truth is
`mission-control/assets/boot-anim/generate-boot-anim.py`
(`./generate-boot-anim.py combo-final`). To refresh this copy:

```sh
cp -a mission-control/assets/boot-anim/frames/*.png \
    image/apps/pocketforge-boot-animator/frames/
sha256sum image/apps/pocketforge-boot-animator/frames/frame-000.png
# must still be ed689555…09faed for u-boot handoff continuity
```

Then run the tests. The expected crop region in `tests/test_animator.py`
(`REGION`) changes if the animated area moves.

## Cross-compile

The image build cross-compiles the animator inside the pinned
`pocketforge/build` container, via `scripts/build-rootfs.sh` (see
`PF_ANIMATOR_BIN`). The same step crops the frames (`PF_ANIM_FRAMES_DIR`).
A host build (`cc -O2 -Wall -I src -o /tmp/animator src/main.c -lm`) is
useful only for the tests.
