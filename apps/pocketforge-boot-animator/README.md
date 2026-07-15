# pocketforge-boot-animator (bd tsp-3rd3.4)

Kernel-handoff fb0 boot animator. Streams the tsp-3rd3.2 48-frame ember-sweep
set to `/dev/fb0` at 16 fps starting from the moment the kernel registers fb0,
and exits cleanly on the takeover handshake — leaving the panel clean-black
for whatever owns the display next.

## What it does

1. Unbinds the framebuffer console (`/sys/class/vtconsole/vtcon1/bind` → 0)
   so kernel console messages cannot bleed through between frames.
2. `mmap`s `/dev/fb0`, verifies geometry (1280×720 @ 32 bpp, stride 5120),
   and logs the R/G/B/A offsets to the journal.
3. Plays frames **000..015 once** (the intro — the motion field ramps in from
   the static logo), then **loops frames 016..047 forever** (`loop_start=16`;
   the loop is periodic by construction, so wrap has no visible discontinuity).
4. On SIGTERM: clears fb0 to black, `msync`, `munmap`, and exits 0.

Frame `000` is byte-identical to the u-boot static logo
(`sha256=ed689555…09faed` = `assets/boot-logo/pocketforge-boot.png` in
`mission-control`), so the u-boot → animator handoff is seamless by
construction — no re-scale, no format drift.

## Exit contract (takeover handshake)

`pocketforge-boot-animator.service` declares
`Conflicts=pocketforge-splash-handoff.target`.
Activating the handoff target sends the animator SIGTERM.

A future MainUI / kiosk service wires itself in with:

```ini
[Unit]
Requires=pocketforge-splash-handoff.target
After=pocketforge-splash-handoff.target
```

Until then, **nothing activates the target** — the animator loops forever.
That is the correct "no MainUI yet" behavior: the animated splash IS the
device's steady state until a real successor exists.

**History (2026-07-14 fix):** the first cut of this bead shipped a paired
oneshot `pocketforge-splash-handoff-default.service` that fired the target
500 ms after `multi-user.target` as an "interim safety net". On the v5
combined image (rootfs `3200a999`) tsp-431c.2's captured evidence showed the
oneshot killed the animator at `Duration=1.687s` — before the intro even
finished (owner saw no logo). The oneshot has been deleted; the animator
loops forever until a real UI arrives.

## Footprint

| Item | Value |
|------|-------|
| Language | C (glibc, dynamically linked) |
| External deps | libc + libm — nothing else on device |
| PNG decoder | vendored `stb_image.h` (public domain, single header) |
| Stripped binary | ~90 KB (target aarch64) |
| Steady-state RSS | ~10–12 MiB (one 3.52 MiB decoded frame + PNG file buffer + code) |
| Frame set on disk | 5.5 MiB (48 PNG, `/opt/pocketforge/boot-anim/frames/`) |
| Decode budget | ~7 ms per frame on x86_64 (measured); ~30–60 ms on A133 (1 GHz) — well under the 62.5 ms/frame tick |
| Blit | RGBA → XRGB8888 per-pixel swap, ~15 ms per frame on A133 |
| RSS ceiling | ≤ 20 MiB (systemd `MemoryMax=32M` guardrail) |

RSS budget breakdown (steady state, one frame in flight):

| Region | Size |
|--------|------|
| One decoded RGBA frame | 3.52 MiB |
| One PNG file buffer (peak) | ≤ 200 KiB |
| stb_image transient allocs | ≤ 2 MiB during decode |
| Code + libc + stack | ~4 MiB |
| **Total (steady peak)** | **~10–12 MiB** |

## Streaming decode

The kickoff contract calls out that 48 raw frames (≈177 MiB) MUST NOT be
pre-decoded. This animator decodes **exactly one frame at a time**
synchronously — the classic "small resident ring" of size 1. Decode + blit +
sleep-to-tick form the whole loop; there is no in-memory frame cache.

The absolute-schedule timer (`ns_since(t0)` vs `(k+1) * TICK_NS`) means a
single slow decode does not desync the animation — the next tick catches up
by sleeping less. Only a >62.5 ms decode overrun causes a one-frame stutter,
which for a boot splash is visually acceptable.

If on-device measurement (`--measure`) shows unacceptable jitter, the code has
room for a producer thread + double-buffer without changing the interface. The
absolute-schedule / synchronous design is deliberately the simplest thing that
correctly satisfies streaming-decode and the timing contract.

## Verify the u-boot handoff continuity

The build's rootfs-customize step stamps
`/opt/pocketforge/boot-anim/PROVENANCE` with `frame-000.png`'s sha256.
An on-device check is:

```sh
grep -q 'ed689555505f644a859f1b7082275935f145ced3d7093e82929ab3701109faed' \
    /opt/pocketforge/boot-anim/PROVENANCE
```

## Regenerating the frame set

The frames here are a committed copy of `mission-control/assets/boot-anim/`
(tsp-3rd3.2, owner-confirmed FINAL v2). The source of truth is the generator
in `mission-control/assets/boot-anim/generate-boot-anim.py`; frames are
regenerable byte-identically from the SVG masters with:

```sh
./generate-boot-anim.py combo-final
```

To refresh this vendored copy after a frame-set update:

```sh
cp -a mission-control/assets/boot-anim/frames/*.png \
    image/apps/pocketforge-boot-animator/frames/
sha256sum image/apps/pocketforge-boot-animator/frames/frame-000.png
# must still be ed689555…09faed for u-boot handoff continuity
```

## Cross-compile locally (out-of-container smoke)

```sh
gcc -O2 -Wall -o /tmp/animator-x64 src/main.c -lm
```

The x64 build is only useful for the decoder path — running against a real
`/dev/fb0` requires an aarch64 build. The image build system does that
cross-compile inside the `pocketforge/build` container via
`scripts/build-rootfs.sh` (see `PF_ANIMATOR_BIN` there).
