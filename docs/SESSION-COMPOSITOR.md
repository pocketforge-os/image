# PocketForge G0 session display architecture

Status: **design only; implementation blocked**

Evidence date: 2026-10-03

Owner decision: Gamescope-first, exact commit
`5fb8dce4a09d0a68d097b9faf9513782106bc843`; A133 remains **UNPROVEN until
G1 on the device**.

## Decision

PocketForge has one compositor-agnostic display/input ownership ABI and three
composition tiers. Gamescope is the G0 candidate for A133 and the default for
real-GPU devices. A133 is admitted only if G1 proves that Gamescope can leave a
pre-rotated fullscreen client on one Display Engine plane and place the system
overlay on another without changing the client plane. If Gamescope recomposites
each frame, A133 selects a small planes-first owner; Gamescope remains the
high-tier compositor. CPU/Pixman rendering is reserved for rarely changing
recovery UI and is not the A133 target.

This supersedes the earlier interim-Weston choice. Weston is dormant fallback
research, activated only by a G1 failure and then subject to the fallback entry
criteria below. No Weston package or Gamescope gap patch is implemented by this
design change.

Risk is retired in this order:

1. source-build the exact closure and fix only the five G0 initialization,
   synchronization, staging, and rotation gaps;
2. immediately run the minimal A133 G1 plane test—before launcher, production
   socket, input, overlay product UI, or Steam Link integration;
3. only after that primary test passes, measure forced GPU composition and
   memory use; and
4. only after G1 admission, implement G2 integration behind the common ABI.

## Exact pins and reproducibility boundary

### Gamescope

The source is
[`ValveSoftware/gamescope`](https://github.com/ValveSoftware/gamescope/tree/5fb8dce4a09d0a68d097b9faf9513782106bc843)
at commit `5fb8dce4a09d0a68d097b9faf9513782106bc843`, tree
`74d70414bbbbe4f3f009ecd3cf6a3a07bfdccf27`, committed 2026-08-03.
The top-level BSD-2-Clause `LICENSE` SHA-256 is
`907dd845489cd09c25f18b6819f476805285e2adcad8c099e3506260023e9e5f`.
The complete in-tree gitlink closure is:

| Dependency | Exact commit |
| --- | --- |
| `src/reshade` | `696b14cd6006ae9ca174e6164450619ace043283` |
| `subprojects/libdisplay-info` | `47a5590e9c4eb35d67651b8c05a55f1a48259329` |
| `subprojects/libliftoff` | `8b08dc1c14fd019cc90ddabe34ad16596b0691f4` |
| `subprojects/openvr` | `ff87f683f41fe26cc9353dd9d9d7028357fd8e1a` |
| `subprojects/vkroots` | `5106d8a0df95de66cc58dc1ea37e69c99afc9540` |
| `subprojects/wlroots` | `88a869855742281c98c22cab9641b317b8d065ef` |
| `subprojects/SPIRV-Headers` | `d790ced752b5bfc06b6988baadef6eb2d16bdf96` |

The wrap revisions are GLM
`0af55ccecd98d4e5a8d1fad7de25ba429d60e863` and stb
`5736b15f7ea0ffb08dd38af21067c314d6a3aae9`. Gamescope forces its
libliftoff and vkroots fallbacks
([`meson.build:9-16`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/meson.build#L9-L16));
the build requires libdrm >=2.4.113 and a static wlroots 0.19.x
([`src/meson.build:13-32`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/meson.build#L13-L32))
and libliftoff >=0.5,<0.6
([`src/meson.build:127-140`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/meson.build#L127-L140)).

The package must be source-built for aarch64 from an offline, digest-locked
distfile set. The lock includes every gitlink, wrap archive, Xwayland, Vulkan
loader, wayland-protocols, libinput, libdrm, shader compiler, and enabled
optional library—not just the top commit. The build runs without `.git` or
network, records compiler/sysroot/flags, emits SPDX plus license digests, and
must reproduce byte-for-byte in two clean build roots. A moving distro package,
tag, branch, subproject HEAD, or unrecorded patch fails G0.

### Admitted adjacent evidence

| Repository/evidence | Exact object at admission | Use |
| --- | --- | --- |
| image `origin/main` | `652b0b3a63781d54fc8ec8ce11a63fc70d5dc8a6` | design base; re-check before handoff |
| runtime | `1dd87ecc2952584a7ef1473c5dcb872662b7c0cb` | authority and input-broker contract; read-only linked worktree |
| launcher | `e27f2c45271fb6b9d695b36c0163e7ade051583a` | single app path; read-only linked worktree |
| Mesa/PVR | commit `eac0a8f445924f0db592352412eb48c9ad39040e`, tree `4fa710967870d01e6130d85795c4e0bb45906a01` | current driver target; separately reviewed/pinned |
| A133 kernel audit | `40ea8fd9dcaeb9526b8032038f1dc820216d7959` | plane/no-rotation baseline; re-pin the actual G1 kernel |

Local reports are evidence indexes, not substitutes for source or device data:

- `/home/matt/recovery/gpu14/compositor-lane-g1.md`, SHA-256
  `da5454137e4b269d34443ecf018fc1448f9712489c623c916c39ea47c33baace`;
- `/home/matt/recovery/gamescope-feasibility/report.md`, SHA-256
  `a811b9ff2da3c1c7c1caf1ae677b64ec24143df01209779e2b6a05caf1fd2434`.

All QEMU, headless, VKMS, and lavapipe results below are **logic-only**. Every
PVR synchronization, format, performance, recovery, and plane result stays
**UNPROVEN until G1**.

### Work ownership (non-overlapping)

| Lane | Owns | Does not own |
| --- | --- | --- |
| GPUCAP (`tsp-mc9m.41.924.29`, run `pft-2ad95cd0e2737af9b9a60cd9`) | Mesa/PVR and kernel capability fixes and evidence, including storage support/limits for the LINEAR scanout modifier and opaque timeline-semaphore FD | Gamescope patches, packaging, session integration, or the device admission verdict |
| COMPOSITOR | Gamescope-side optimal-to-LINEAR staging, Vulkan portrait rotation, direct-DRM present-ID/wait gating, source packaging, this session/plane qualification plan | Any new Mesa/PVR worker or uncoordinated `platform.lock` GPU pin |
| CX-DEPUTY | Device work, GPU bench3, `pf-bench`, GPU fixes already in flight, and coordination of allowed pin windows | Rewriting the accepted session ABI or masking a failed G1 threshold |

GPUCAP will comment exact child bead IDs on the existing gap beads; the
coordinator adds those dependencies. COMPOSITOR does not invent duplicate Mesa
work. Every Mesa/kernel fact depends on an exact GPUCAP receipt and is still
device-unproved until G1. No `platform.lock` gpu-um-tsp movement occurs under a
sealed bench; CX-DEPUTY coordinates a new pin window first.

## One ownership ABI, three device tiers

The display producer changes by tier; authority, paths, lifecycle, and client
protocol do not.

| Tier | Display policy | Overlay behavior | GPU policy |
| --- | --- | --- | --- |
| 256 MiB projector/theater | Plane-only owner; at least video + OSD planes | Pause updates and freeze the client's last framebuffer on its plane, then show/hide opaque OSD on a higher plane. No whole-output composition. | No required Vulkan. Pixman may redraw infrequent recovery/status surfaces only. |
| A133 1 GiB / GE8300 | Planes-first at native 720x1280. Four LINEAR DE planes with zpos/alpha are the audited hypothesis; KMS rotation is absent. Landscape UI must produce a physically pre-rotated 720x1280 buffer. | Client plane plus independent higher-z system-overlay plane. Gamescope is admitted only by G1. | GPU composition begins disabled/unqualified. Secondary G1 may qualify it; it is not required for the primary tier. |
| 8–12 GiB real-GPU | Full Gamescope GPU composition, with direct planes as an optimization | Gamescope external overlay; composition is allowed | Vulkan 1.2 or newer, exact platform qualification required |

### Device capability vocabulary

The existing per-device source is
`platform/devices/<id>/capabilities.toml`, staged verbatim at
`/usr/share/pocketforge/devices/<id>/capabilities.toml`. Extend each
`[[screens]]` row and its schema with these exact fields:

```toml
native_mode = { w = 720, h = 1280, refresh_mhz = 60000 }
composition_tier = "planes-first" # plane-only | planes-first | gpu
plane_count = 4
plane_modifiers = ["LINEAR"]
plane_alpha = true
plane_zpos = true
kms_rotations = ["normal"]
gpu_composition = false            # false until secondary G1 qualifies it
vulkan_level = "1.2-unproven"
```

The schema must reject unknown enum values and inconsistent combinations (for
example `plane-only` with `gpu_composition=true`, or `plane_count=1` with an
overlay-plane requirement). These are platform facts consumed by the display
owner selector; they do not enter or rename the launcher-facing application
capability vocabulary in `/usr/share/pocketforge/platform-capabilities.toml`.
The A133 descriptor remains an expectation until G1 replaces
`1.2-unproven` and the conservative GPU flag with measured truth.

## Compositor-agnostic session ABI

The system supervisor owns `/run/pocketforge/session` (`root:pf-session`, mode
0750) and the generation counter. The selected display owner creates exactly:

- Wayland socket `/run/pocketforge/session/wayland-0`, mode 0660;
- environment record `/run/pocketforge/session/environment`; and
- optional `/run/pocketforge/session/Xauthority`, mode 0640, only for an
  X11-authorized app.

The environment record is data, never shell-evaluated, and contains a strict
allow-list:

```text
PF_SESSION_ABI=1
PF_SESSION_GENERATION=<unsigned decimal>
PF_SESSION_COMPOSITOR=gamescope|plane-owner|weston-fallback
XDG_RUNTIME_DIR=/run/pocketforge/session
WAYLAND_DISPLAY=wayland-0
```

`DISPLAY` and `XAUTHORITY` appear only for an opt-in Xwayland app. The
supervisor waits for a connectable socket and required Wayland globals, writes
an environment temporary file, fsyncs it, and renames it into place. It refuses
an existing socket unless recorded PID, start time, generation, and inode prove
that its own previous producer is dead; it never unlinks an unknown path. On a
compositor restart it removes only the matched dead socket, increments the
generation exactly once, and republishes the same canonical path. Existing
clients are stopped and relaunched by the authority; they never silently cross
generations.

There remains one `pf-session-authority`, one
`pf-app@<id>.service` -> `/usr/bin/pf-app-launch %i` path, and one `app.toml`
descriptor. Native apps and `pf-shell` remain ordinary xdg-shell clients and
must not link a Gamescope, Weston, DRM, or vendor-shell API. G1 uses a private
bench runtime and deliberately precedes production socket integration.

## Source audit at the Gamescope pin

### Vulkan admission and G0 gaps

Gamescope rejects devices below Vulkan 1.2 and selects a compute-capable queue
([`rendervulkan.cpp:328-369`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L328-L369)).
On direct DRM it demands dma-buf external memory, external semaphore FD, and
robustness extensions
([`rendervulkan.cpp:555-607`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L555-L607))
and enables timeline semaphores, scalar layout, YCbCr conversion, and null
descriptors
([`rendervulkan.cpp:616-693`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L616-L693)).
Direct DRM explicitly does not use a Vulkan swapchain
([`DRMBackend.cpp:3948-3951`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/Backends/DRMBackend.cpp#L3948-L3951)).

Five gaps are therefore blocking, not optional optimizations:

The existing work-order mapping is L `tsp-fc58886d2e6d2d6a9589`, M semaphore
`tsp-e6a8dcfcd86fd80e96a1`, M rotation `tsp-b25264113c4580010832`, S
`tsp-2fee73c5e3fc363beede`, and M packaging
`tsp-op5a.440.1`. The Weston/Pixman packaging bead
`tsp-0c9b666ac3daca7d5aed` is fallback-only and cannot satisfy a G0 gap. GPUCAP
child IDs are dependencies when its owner posts exact receipts; they are not
replaced here.

| ID / size | RED source fact at exact pins | Required patch and source test | G1 proof |
| --- | --- | --- | --- |
| L | Gamescope chooses LINEAR tiling for `bLinear`, adds STORAGE for composition, and creates storage/flippable targets ([`rendervulkan.cpp:2026-2044`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L2026-L2044), [`3287-3313`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L3287-L3313)). PVR exposes linear sampled/transfer, but STORAGE only for optimal tiling ([`pvr_arch_formats.c:39-51,101-107`](https://github.com/pocketforge-os/gpu-um-tsp/blob/eac0a8f445924f0db592352412eb48c9ad39040e/src/imagination/vulkan/pvr_arch_formats.c#L39-L51); [`pvr_formats.c:266-353,473-519,628-669`](https://github.com/pocketforge-os/gpu-um-tsp/blob/eac0a8f445924f0db592352412eb48c9ad39040e/src/imagination/vulkan/pvr_formats.c#L266-L353)). | **COMPOSITOR:** compose into optimal STORAGE; rotate/copy into a same-format LINEAR, dma-buf-exportable TRANSFER_DST scanout image; test selection, exact extents, barriers, reuse, and errors on lavapipe. **GPUCAP dependency:** receipt for PVR optimal/LINEAR usage and modifier limits. | PVR creates both images, produces correct pixels, exports/scans out staging, and runs without fault. |
| M semaphore | Gamescope exports/imports timeline semaphores specifically as `OPAQUE_FD` ([`rendervulkan.cpp:1381-1481`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L1381-L1481)). PVR's current sync-file winsys path is not proof of opaque timeline FD, and the extension is gated by `PVR_USE_WSI_PLATFORM`; the admitted `-Dplatforms=[]` recipe disables that gate ([`pvr_physical_device.h:30-37`](https://github.com/pocketforge-os/gpu-um-tsp/blob/eac0a8f445924f0db592352412eb48c9ad39040e/src/imagination/vulkan/pvr_physical_device.h#L30-L37); [`pvr_physical_device.c:121-140`](https://github.com/pocketforge-os/gpu-um-tsp/blob/eac0a8f445924f0db592352412eb48c9ad39040e/src/imagination/vulkan/pvr_physical_device.c#L121-L140)). | **GPUCAP:** advertise only after capability queries and export/import/wait/signal tests pass, then provide exact child-bead/commit/tree/test receipts. CX-DEPUTY coordinates the image pin window; COMPOSITOR creates no Mesa worker. | Same-process and cross-process FD round trips, monotonically increasing values, Gamescope wait/signal, no timeout/fault. |
| M rotation | Current DRM orientation is converted into KMS plane `rotation` ([`DRMBackend.cpp:2250-2290`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/Backends/DRMBackend.cpp#L2250-L2290), [`2676-2699`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/Backends/DRMBackend.cpp#L2676-L2699)); A133 has no audited rotation property. | **COMPOSITOR:** add explicit no-KMS-rotation policy. Direct scanout requires a physical 720x1280 pre-rotated buffer and `DRM_MODE_ROTATE_0`; forced composition rotates 1280x720 into 720x1280 LINEAR staging. **GPUCAP dependency:** exact kernel plane/rotation capability receipt. | External-camera marker orientation and 720x1280 plane rectangles are correct with KMS rotation normal. |
| S | Present-ID/wait extensions are appended only for swapchain backends ([`rendervulkan.cpp:557-567`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L557-L567)), but their feature structs are unconditionally chained with `VK_TRUE` ([`624-650`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/rendervulkan.cpp#L624-L650)). PVR reports these features false. | Query and enable extension + feature as one pair only for a backend that uses them; direct DRM must omit/disable both. A fake capability matrix covers extension absent, feature false, and supported cases. | Direct DRM starts with both disabled; no validation error or feature-dependent call occurs. |
| M packaging | Upstream source has a nontrivial subproject and system dependency closure. | Exact source/gitlink/wrap lock, offline cross-build, minimal feature set, license/SBOM, two-root reproducibility, ELF arch/NEEDED/RPATH audit, and patch digests. | Installed files match the manifest and recorded hashes on the G1 image. |

Mesa source establishes only that GE8300 reports Vulkan 1.2 and a
graphics+compute+transfer queue
([`pvr_physical_device.c:495-502,1204-1210`](https://github.com/pocketforge-os/gpu-um-tsp/blob/eac0a8f445924f0db592352412eb48c9ad39040e/src/imagination/vulkan/pvr_physical_device.c#L495-L502)),
and LINEAR format support is deliberately narrow
([`pvr_formats.c:473-527,812-893`](https://github.com/pocketforge-os/gpu-um-tsp/blob/eac0a8f445924f0db592352412eb48c9ad39040e/src/imagination/vulkan/pvr_formats.c#L473-L527)).
It does not prove that the device executes these paths correctly.

### Smallest offline RED/GREEN probe (logic-only)

The COMPOSITOR gap series must ship one deterministic runner. It builds the
exact Gamescope pin plus reviewed patch commits, starts a headless or VKMS DRM
session with lavapipe, drives a CPU-generated asymmetric client, and emits one
JSON record containing source SHAs, Vulkan capabilities, buffer dimensions,
plane/FB snapshots, composition/staging counters, output CRC, and verdict.

- **RED transform:** submit 1280x720 with a 90-degree buffer transform. The
  A133 policy parser must reject direct admission; metadata cannot make it the
  required physical 720x1280 buffer.
- **RED overlay:** force `bDoComposite` with base + overlay. The primary gate
  parser must fail even when pixels are correct.
- **GREEN state machine:** submit 720x1280 LINEAR with transform normal, then
  exercise synthetic off/on/off base+overlay atomic snapshots. The base plane
  tuple must remain identical and the overlay tuple must appear at higher zpos.
- **GREEN composition logic:** force optimal composition, exact 1280x720 to
  720x1280 rotation, and copy into LINEAR staging; compare the output CRC with a
  CPU reference and exercise unsupported-format and failed-fence paths.

VKMS/QEMU may validate the patch logic, parser, synchronization order, failure
handling, and trace schema. Its planes, driver, memory system, and lavapipe are
not GE8300/DE evidence, so even a fully GREEN offline record cannot satisfy G1.

### Direct planes and pre-rotation

The audited A133 kernel constructs VI0/VI1 as overlay planes, UI0 as primary,
and UI1 as overlay
([`sun8i_mixer.c:368-431`](https://github.com/pocketforge-os/kernel-sunxi-7.x/blob/40ea8fd9dcaeb9526b8032038f1dc820216d7959/drivers/gpu/drm/sun4i/sun8i_mixer.c#L368-L431));
it exposes zpos and alpha/blend controls
([`sun8i_vi_layer.c:434-459`](https://github.com/pocketforge-os/kernel-sunxi-7.x/blob/40ea8fd9dcaeb9526b8032038f1dc820216d7959/drivers/gpu/drm/sun4i/sun8i_vi_layer.c#L434-L459),
[`sun8i_ui_layer.c:286-308`](https://github.com/pocketforge-os/kernel-sunxi-7.x/blob/40ea8fd9dcaeb9526b8032038f1dc820216d7959/drivers/gpu/drm/sun4i/sun8i_ui_layer.c#L286-L308)).
Formats/modifiers remain plane-specific
([`sun8i_vi_layer.c:303-340`](https://github.com/pocketforge-os/kernel-sunxi-7.x/blob/40ea8fd9dcaeb9526b8032038f1dc820216d7959/drivers/gpu/drm/sun4i/sun8i_vi_layer.c#L303-L340),
[`sun8i_ui_layer.c:225-250`](https://github.com/pocketforge-os/kernel-sunxi-7.x/blob/40ea8fd9dcaeb9526b8032038f1dc820216d7959/drivers/gpu/drm/sun4i/sun8i_ui_layer.c#L225-L250)).
No rotation property was found in the bounded plane-property audit. The panel
mode is native portrait 720x1280
([`sun50i-a133-pocketforge-tsp.dts:248-280`](https://github.com/pocketforge-os/kernel-sunxi-7.x/blob/40ea8fd9dcaeb9526b8032038f1dc820216d7959/arch/arm64/boot/dts/allwinner/sun50i-a133-pocketforge-tsp.dts#L248-L280)).

Gamescope feeds FB, fence, zpos, alpha/blend, rectangles, and rotation into
libliftoff
([`DRMBackend.cpp:2621-2699`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/Backends/DRMBackend.cpp#L2621-L2699))
and rejects any libliftoff result requiring partial composition
([`2810-2862`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/Backends/DRMBackend.cpp#L2810-L2862)).
When the direct atomic preparation succeeds it skips composition and commits
the layers; otherwise it falls back to composition
([`3574-3654`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/Backends/DRMBackend.cpp#L3574-L3654)).
The first frame is deliberately composed (`3601-3604`), so G1 excludes warmup.

Four transforms must stay distinct:

1. **UI transform:** the application's logical landscape coordinate system.
2. **Buffer transform:** Wayland metadata. At this pin the commit/import/paint
   path imports the texture and sizes it from the committed buffer
   ([`wlserver.cpp:219-260`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/wlserver.cpp#L219-L260),
   [`steamcompmgr.cpp:2082-2149`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/steamcompmgr.cpp#L2082-L2149));
   this audit found no propagation of `wl_surface.buffer_transform` into the DRM
   layer. Metadata alone is therefore not accepted as rotation proof.
3. **Compositor scene transform:** needed only on the forced-composition path;
   the patch rotates the final Vulkan image.
4. **KMS plane transform:** must be `DRM_MODE_ROTATE_0` on A133.

The G1 client must allocate an actual 720x1280 XRGB8888 LINEAR dma-buf whose
pixels are already rotated for portrait scanout, set buffer transform to
`normal`, and render its landscape UI mapping internally. A 1280x720 buffer plus
rotation metadata is the RED counterexample and must not pass.

### Overlay Path A/B/C

The prior Weston Path B decision is superseded. For Gamescope:

| Path | Decision | Reason |
| --- | --- | --- |
| A: native layer-shell external overlay | **Selected for G1/G2.** A minimal trusted system client submits ARGB8888 or XRGB8888 LINEAR. | Gamescope creates layer-shell v4 and marks these surfaces `isExternalOverlay` ([`wlserver.cpp:1982-1993,2105-2123`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/wlserver.cpp#L1982-L1993)); it assigns external-overlay zpos ([`steamcompmgr.cpp:2191-2224`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/steamcompmgr.cpp#L2191-L2224)) and paints it as a second layer ([`2673-2683`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/steamcompmgr.cpp#L2673-L2683)). Ordinary apps remain xdg-shell. |
| B: draw overlay into Gamescope's Vulkan composition | Diagnostic/secondary only. | It cannot satisfy the primary invariant because the app framebuffer is replaced by a composed framebuffer. |
| C: second DRM sidecar/lease | Rejected. | It creates two display authorities, races DRM master/atomic state, and breaks the common session ABI. |

Source proves only that Gamescope attempts the two-layer libliftoff state. Plane
availability, format/modifier compatibility, zpos, alpha, fence behavior, and
unchanged base assignment are all G1 questions.

## Input ownership and Xwayland reachability

The existing app-session topology remains authoritative:

- `pf-input-decode` exposes `/dev/input/pf-gamepad`;
- `pf-input-broker` alone takes its `EVIOCGRAB`, canonicalizes events, creates
  `PocketForge Input (<id>)`, and passes a read fd by
  `Acquire("input")` + `SCM_RIGHTS`;
- the broker consumes guide/`BTN_MODE` press and release and sends exactly one
  `safe_return` request to `pf-session-authority`; the app never sees Menu; and
- broker lifetime stays bound to the single app unit and never becomes a
  boot-enabled service.

This is implemented in the admitted runtime at
`crates/pf-input-broker/src/evdev.rs:38-68`,
`src/broker.rs:417-486,677-723`, and `src/safe_return.rs:1-41`, and documented
in this repository at `docs/DEFAULT-APPS.md:734-825`. Gamescope/libinput must be
filtered from both the physical source and broker-created gamepad; the app gets
the broker fd directly. In overlay mode the same broker exclusively routes
sanitized navigation/confirm/cancel to the trusted overlay and suppresses them
from the app. No second open, second grab, or dual delivery is allowed. Power
and other device-class system keys use a distinct protected device/path and
never enter the app stream. G1 has no input integration; this work begins in G2.

Gamescope at this pin really does use wlroots' Xwayland server API
([`wlserver.cpp:1779-1790`](https://github.com/ValveSoftware/gamescope/blob/5fb8dce4a09d0a68d097b9faf9513782106bc843/src/wlserver.cpp#L1779-L1790));
that fact must not be projected backward onto Weston. Xwayland is opt-in per
app, starts `-nolisten tcp` with a per-generation MIT-MAGIC-COOKIE, and exposes
only its filesystem socket plus that cookie inside the app's private root.
Never project the host `/tmp/.X11-unix` directory. Linux abstract X11 sockets
ignore mount namespaces, so the app must have a network namespace in which the
host abstract socket is unreachable, or Xwayland must be configured without
one. The sandbox test must prove that the projected display succeeds and all
other filesystem, abstract, and TCP displays fail. Native Wayland is preferred.

## G1: first-device gate after pf-bench

G1 freezes the actual image, kernel, Mesa/PVR, Gamescope+patch, firmware, DT,
and test-client commits before power-on. It uses one native Wayland test client;
no launcher, production session socket, broker, product overlay, or Steam Link.
All thresholds are registered in the bench record before the run and may not be
relaxed after seeing results.

### Primary A133 PASS gate

After 10 s warmup, run 120 s at 720x1280@60 with a moving asymmetric marker,
then freeze one submitted framebuffer and toggle the minimal Path A overlay 100
times. Collect:

- `/sys/kernel/debug/dri/0/state` before, during, and after every toggle;
- DRM atomic/vblank tracepoints with monotonic timestamps;
- a small exact-pin Gamescope trace patch reporting `bDoComposite`, layer
  count, composition dispatch, staging copy, selected plane and FB ID;
- `pidstat` at 1 s, device GPU-busy counter, and kernel journal PVR fault/guilty
  signatures; and
- external-camera evidence of the asymmetric physical orientation. `modetest`
  is preflight inventory only and must not steal DRM master.

All of these are mandatory:

1. Client buffer is 720x1280 XRGB8888 LINEAR, pre-rotated in memory,
   `buffer_transform=normal`; KMS rotation is normal.
2. After warmup, Gamescope records zero composite dispatches and zero staging
   copies. Mean is 59.0–61.0 fps, p99 frame interval <=20.0 ms, no interval is
   >33.34 ms, Gamescope CPU is <=5% mean and <=10% p99 of one core, and GPU-busy
   delta over the frozen-client idle baseline is <=2.0 percentage points.
3. Overlay-on uses a distinct higher-z plane with a nonzero FB. Overlay-off
   disables that plane.
4. Across overlay off/on/off, the client plane ID, FB_ID, CRTC_ID, format,
   modifier, SRC/CRTC rectangles, and rotation are byte-for-byte unchanged.
5. There are zero failed atomic commits, zero GPU faults, zero guilty lockups,
   and no compositor recovery.

Any scored frame with `bDoComposite=true`, any changed client-plane assignment,
or a missing independent overlay plane is **G1 PRIMARY FAIL for Gamescope on
A133**. Select the lightweight planes-first owner and keep Gamescope for the
high tier. Do not try to rescue the result by lowering the frame rate, accepting
per-frame GPU composition, or relabeling a composed framebuffer as direct.

### Secondary forced-composition characterization

Only after the primary sequence passes, force full composition for 600 s. Use
logical 1280x720, an optimal STORAGE composition image, final portrait rotation,
and a 720x1280 LINEAR scanout staging image. Thresholds:

- 59.0–61.0 mean fps, p99 interval <=20.0 ms, zero intervals >33.34 ms;
- Gamescope CPU <=35% mean and <=75% p99 of one core; GPU busy <=75%;
- measured DRAM traffic above the frozen-client idle baseline <=1.50 GiB/s and
  <=50% of independently measured sustainable bandwidth;
- Gamescope PSS <=128 MiB, Xwayland PSS <=96 MiB, test-client PSS <=128 MiB,
  combined PSS <=384 MiB, summed RSS <=512 MiB, and system `MemAvailable`
  >=192 MiB, sampled every second; and
- correct external-camera orientation, zero atomic failures, zero PVR faults,
  and zero guilty lockups.

This bandwidth estimate is analytical, not a measurement. At 720x1280x60
there are 921,600 pixels/frame and 55,296,000 pixels/s. One RGBA read+write is
442,368,000 B/s lower bound; one layer plus a staging copy is 884,736,000 B/s
lower bound and approximately 0.99–1.07 GiB/s after 20–30% overhead. Two-layer
read+output is 663,552,000 B/s lower bound; bilinear four-tap read+write is
1,105,920,000 B/s lower bound. These exclude client rendering, display fetch,
cache/tiling effects, fences, and ALU. `pf-bench` records measured memory
controller traffic and the same idle subtraction.

Secondary failure marks `gpu_composition=false` for A133 but does not overturn
a clean primary planes-first pass unless it faults or violates recovery safety.
Secondary success permits a separately reviewed descriptor change to true.

### Fault containment and recovery

Source tests can prove state transitions, timeouts, cgroup kill order, socket
generation behavior, and mocked fault-log classification. They cannot prove a
PVR engine reset or DRM recovery. Evidence from `tsp-mc9m.41.924.28.1` and
`.28.2` shows real Fragment DM guilty lockups from invalid extents; B26 still
left MainUI rendering, but no receipt proves kernel recovery. The corrected Mesa
pin fixed the inverted-blit extent/layer defect, and the B42r11 four-arm run had
zero fault signatures and exact pixels where comparable. That proves the fixed
test sequence, not Gamescope isolation.

The authority and broker run outside the compositor cgroup and GPU dependency
chain. On a client fault: freeze/remove its surface, stop its cgroup, and retain
the system session. On compositor heartbeat loss or a guilty lockup: stop the
client first; stop Gamescope with a bounded deadline; release/reacquire DRM in
the supervisor; display a CPU dumb-buffer or plane-safe recovery screen; bump
the session generation exactly once; and restart the compositor at most once.
SafeReturn remains available through the broker. No restart loop or new GPU
submission is allowed until the incident is acknowledged.

The recovery screen deadline is 3 s. `pf-session-authority` and
`pf-input-broker` must not restart, their PID/start-time continuity is recorded,
and exactly one compositor restart/generation increment is allowed. Deliberate
device fault injection is out of scope without a separately approved bench.
Any naturally occurring fault makes G1 fail immediately; preserve logs and
then evaluate whether the recovery invariants held.

## Dependency and RED/GREEN matrix

| Order | Dependency | RED | Source/logic GREEN | Device GREEN / effect |
| --- | --- | --- | --- | --- |
| 0 | exact package closure | unresolved build inputs or nonreproducible output | offline two-root build, SPDX, patch/dependency hashes | installed hashes match; permits bench image |
| 1 | S present feature gate | direct DRM requests unsupported present feature | fake Vulkan matrix passes without using disabled feature | PVR direct DRM initializes |
| 2 | M opaque timeline FD (GPUCAP) | extension/capability absent or FD roundtrip fails | GPUCAP-reviewed gpu-um tests and exact receipt; CX-DEPUTY later coordinates repin | Gamescope wait/signal completes |
| 3 | L staging (COMPOSITOR + GPUCAP receipt) | LINEAR+STORAGE rejected | optimal-to-LINEAR Gamescope copy tests plus GPUCAP usage/modifier limits | scanout image is correct/fault-free |
| 4 | M rotation (COMPOSITOR + GPUCAP receipt) | KMS rotation requested or wrong extents | asymmetric lavapipe mapping plus GPUCAP kernel capability receipt | KMS normal, camera correct |
| 5 | `pf-bench` and sealed manifest (CX-DEPUTY) | collectors or pins can change during a run | calibrate collectors, freeze exact image/kernel/Mesa/Gamescope/client objects | authorizes the first device bench |
| 6 | G1 primary | any recomposition or plane churn | QEMU/VKMS exercises state/trace parser only | selects Gamescope or lightweight A133 owner |
| 7 | G1 secondary | no A133 performance/memory fact | estimate and collectors validated | qualifies or disables A133 GPU composition |
| 8 | G2 | no production integration | authority/socket/input fault tests | product feature sequence below |

No implementation child may treat a logic GREEN as device proof. Gap changes
remain independently reviewed/pinned and the design bead does not implement
them.

## Claim / evidence / counterexample adjudication

| Claim | Evidence | Counterexample or falsifier | Verdict |
| --- | --- | --- | --- |
| G0 uses Gamescope at an exact object. | Commit, tree, gitlinks, wraps, license hash, and Meson fallbacks are pinned above. | A package assembled from another tag/tree or moving dependency. | Accepted, subject to reproducible package GREEN. |
| B1/Pixman is not the A133 answer. | Gamescope has direct libliftoff plane flow; Pixman CPU rendering adds full-frame traffic and cannot satisfy near-zero compositor work. | Pixman is still useful for rare recovery UI; this does not qualify it for 60 Hz A133 composition. | Prior broad “no backend plane promotion” claim is not reused; Weston is fallback-only. |
| B2 has one raw gamepad owner. | Existing broker EVIOCGRAB/uinput/SCM_RIGHTS and Menu withholding are exact source behavior. | Gamescope/libinput opening either gamepad node, Menu reaching an app, or overlay/app dual delivery. | Accepted with explicit filtering and G2 tests. |
| B3 overlay preserves the app plane. | Gamescope creates an external-overlay layer and attempts two-layer libliftoff. | libliftoff needs composition, changes app FB/plane, or overlay lacks its own higher-z plane. | Source-plausible, device-unproved; G1 is decisive. |
| B4 pins are reproducible. | Full object/closure/license table and build rules. | Unlocked system dependency, patch, or toolchain. | Accepted only after packaging GREEN. |
| B5 compositor APIs are not interchangeable. | Gamescope actually uses wlroots Xwayland; Weston 14 uses its own API. Private-root reachability is separately specified. | Calling Weston with a wlroots API, or relying on a bind mount to hide abstract X11. | Corrected and accepted. |
| Pre-rotation enables direct scanout without KMS rotation. | Native dimensions, normal KMS transform, and direct layer path are explicit. | 1280x720 + metadata, wrong modifier, scale, or non-normal KMS transform. | Device-unproved until G1. |
| Fault containment preserves the system session. | Authority/broker isolation and mockable restart state machine. | Authority PID changes, repeated restart, missing recovery screen, or unrecovered DRM. | Source-testable in part; device recovery remains unproved. |

## Fallback decision tree

```text
exact Gamescope package + five G0 gaps GREEN
  -> A133 G1 primary
       PASS -> A133 Gamescope planes-first
                 -> secondary PASS: gpu_composition=true may be reviewed
                 -> secondary perf FAIL: keep gpu_composition=false
       FAIL because every frame is composed, overlay is not independent,
       or app plane changes -> select lightweight planes-first A133 owner
       FAIL because Gamescope cannot initialize safely -> same selection
  -> high-tier real-GPU devices keep Gamescope and qualify independently
  -> 256 MiB devices use plane-only owner regardless
```

Weston evaluation begins only after an explicit G1 Gamescope fail. The dormant
pins are Weston 14.0.2 commit
`015b3b4d4c05da44a22349ea6e651d1a8f678c59`, tree
`a247d7edd31594ac2974390ccba76b7fe0a0c1f1`, and Pixman 0.42.2 commit
`37216a32839f59e8dcaa4c3951b3fcfc3f07852c`, tree
`63108dee63862b0af0645b42119f73eacfa21c5f`. They are not build recommendations.
Fallback admission must freshly prove all three earlier premises at those exact
objects: (1) hardware Mesa EGL/Zink clients import through linux-dmabuf with no
software fallback, (2) a pre-rotated LINEAR 720x1280 buffer reaches a KMS plane
with effective/KMS transform normal, and (3) an independent higher-z overlay
plane appears without changing the app plane. Pixman may service static
recovery UI only.

## G2 after G1 PASS

Implement and qualify in this strict order:

1. `pf-shell` as an ordinary xdg-shell client;
2. canonical session socket/environment/generation contract;
3. input broker, protected system keys, and exclusive overlay routing;
4. Gamescope external-overlay Path A; and
5. Steam Link handoff through the existing `pf-app@<id>.service` + `app.toml`
   path, including its documented coarse input exception.

Every step retains the authority/broker recovery tests and can be reverted to
the previously qualified display owner without changing client code or paths.

## Success criteria and deferred facts

G0 is complete when this design and fixture are accepted and each named gap has
an independently owned executable RED/GREEN work order. It does not itself make
the driver or compositor ready. G1 admits Gamescope on A133 only under the
primary thresholds above. G2 cannot start earlier.

Deferred facts include all real PVR semaphore behavior, optimal/linear copy
execution, plane assignment, overlay alpha/zpos, no-rotation presentation,
60 Hz pacing, memory bandwidth, RSS/PSS, thermal headroom, and guilty-lockup
recovery. They must be reported as measurements with exact image/kernel/Mesa/
Gamescope/test SHAs; none may be promoted from hypothesis by QEMU, VKMS,
lavapipe, source reading, or this document.
