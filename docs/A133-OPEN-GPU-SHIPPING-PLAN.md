# A133 open-GPU shipping integration plan

Status: scoped 2026-08-30 for `tsp-mc9m.41.748`. This document is a plan,
not an implementation. The existing `a133` image remains the shipping baseline.

## Decision and boundary

Add an opt-in `a133-open` device profile and prove a complete 6.x image before
changing `a133`. Do not switch `a133` in place. The proven open-render bundle is
a deliberately small GPU vehicle; it proves that `powervr.ko`, the open Mesa ICD,
and the firmware can render on the A133, but it does not prove that the 6.x tree is
a shipping replacement for the board's 4.9 kernel.

The cutover gate is therefore wider than GPU initialization. A candidate must boot
the normal full image and prove panel/display, storage, XR829 Wi-Fi, input MCU and
keys, audio, USB, PMIC/regulators/battery/power-supply reporting, suspend/resume (if
claimed), and the normal application/runtime services. It must also prove real
on-panel applications, not only the off-screen A17 capture, and measure the memory
and bandwidth impact of the GE8300 2x-backing mitigation.

## Current `a133` resolution and stage map

### Profile and lock resolution

`platform/devices/a133/profile.toml` resolves the following inputs through
`platform/platform.lock`:

| Profile field | Current resolution |
|---|---|
| `kernel.repo/ref` | `kernel-sunxi-4.9` / `device/a133`; lock SHA `a7cfec247898bb2c22e51bb705a7f18fd5910285`; `pocketforge_tsp_defconfig`; `pocketforge_tsp.dtb`; release 4.9.191 |
| `gpu.repo/ref/modules` | `gpu-km-tsp` / `main`; lock SHA `36196a9ec75c1e3c54c67ca75099e09f0fdf81f2`; `pvrsrvkm.ko`, `dc_sunxi.ko` |
| blob groups | `pvr-ddk-22.102.54.38`, `sunxi-a133-boot-chain`, `sunxi-a133-wifi-firmware` |
| other relevant pins | `image`, `blobs`, `vendor-manifest`, `libsdl3-sunxifb`, `wpa-supplicant-tsp`, and `runtime` |

`platform/core/profile.py` deep-fills variant profiles from `[device].base`, then
exports `PF_KERNEL_REPO`, `PF_KERNEL_REF`, `PF_KERNEL_DEFCONFIG`, `PF_KERNEL_DTB`,
`PF_GPU_REPO`, `PF_GPU_REF`, `PF_GPU_MODULES`, and sorted `PF_BLOB_GROUPS`. It maps
repository names to exact lock SHAs. `platform/core/pf-build.sh` archives those
exact SHAs and supplies named Docker build contexts (`kernel-src`, `gpu-src`, and
the common source/blob contexts). Thus a profile addition is enough to select a
different locked kernel, but the build currently has only one `gpu-src` concept
and treats it as an out-of-tree KM repository.

### `build/Dockerfile.pf`

The relevant stage graph is:

1. `fetch` reads the pinned vendor manifest and CAR, iterates sorted
   `PF_BLOB_GROUPS`, verifies CID and SHA-256, and stages the group paths in `/out`.
2. `kernel` builds the locked 4.9 archive with the profile defconfig and DTB,
   produces `Image`, the DTB, `modules_install`, and a configured build tree plus
   `Module.symvers`. Its reproducibility and vermagic checks are the ABI handoff.
3. `gpu-km` copies that configured kernel tree and `gpu-km-tsp`. For A133 it runs
   kbuild with `CONFIG_DRM_IMG_ROGUE=m PVR_SYSTEM=sunxi_a133`, using the DDK's
   `build/pvr-buildopts.mk`; it collects exactly `pvrsrvkm.ko` and `dc_sunxi.ko`
   and rejects a module whose vermagic differs from the kernel.
4. `sdl` copies fetched blobs and builds `libsdl3-sunxifb`. Its device gate is
   `PF_GPU_REPO == gpu-km-tsp`, and the build links the closed PowerVR UM from
   `/work/blobs/sunxi/a133/22.102.54.38`.
5. `wpa` and `runtime` also use `PF_GPU_REPO == gpu-km-tsp` as a proxy for “A133”.
   That proxy would incorrectly disable A133-specific Wi-Fi and input-runtime
   artifacts in an open profile.
6. `rootfs` dispatches to `scripts/build-rootfs.sh` only when
   `PF_GPU_REPO=gpu-km-tsp`, copying the kernel modules, DDK KM output, SDL, WPA,
   runtime, and fetched blobs.
7. `assemble` copies the same kernel and KM outputs and calls
   `scripts/build-sd-image.sh`; that script currently asserts that
   `pvrsrvkm.ko` exists even though rootfs has already been assembled.

### Closed userspace, KM, and firmware installation

The pinned vendor manifest's `pvr-ddk-22.102.54.38` group contains the helper,
two closed firmware files, eight closed UM libraries, and binary KM copies. The
hermetic fetch preserves the manifest paths under
`sunxi/a133/22.102.54.38` in the current reorganized blob tree.

`scripts/build-rootfs.sh` verifies `libEGL.so` and the DDK firmware, then installs
`libEGL.so`, `libGLESv2.so`, `libGLES_CM.so`, `libIMGegl.so`, `libsrv_um.so`,
`libusc.so`, `libglslcompiler.so`, and `libpvrNULL_WSEGL.so` into
`/usr/lib/pvr-rogue`. It writes `/etc/ld.so.conf.d/00-pvr.conf`, runs `ldconfig`,
and creates unversioned `libEGL.so`, `libGLESv2.so`, and `libGLES_CM.so` links in
`/usr/lib/aarch64-linux-gnu` for the vendor driver's `dlopen` behavior. It installs
the source-built `pvrsrvkm.ko` and `dc_sunxi.ko`, selected 4.9 modules, and XR829
modules into a hard-coded `/lib/modules/4.9.191`, then runs `depmod 4.9.191`. The
closed `rgx.fw.*` and `rgx.sh.*` files go directly in `/lib/firmware`.

This means dropping only the blob group is not viable: rootfs verification,
install, SDL linkage, module paths, module names, and assemble assertions all
encode the closed stack.

## Open-stack map and recipe to lift

The validated stack consists of:

- `kernel-sunxi-6.x` `device/a133`, configured with the A133 defconfig,
  `CONFIG_DRM_POWERVR=m`, and the full-board
  `sun50i-a133-pocketforge-tsp.dtb` (not the older minimal/incorrect bundle DTB);
- in-tree `drivers/gpu/drm/imagination/powervr.ko`, replacing both DDK modules;
- `gpu-um-tsp` at or after merged mitigation SHA `43fc908`, producing the open
  Mesa PowerVR Vulkan ICD;
- unmodified firmware `fw-6976702` at commit `b571cdd9`, installed as
  `/lib/firmware/powervr/rogue_22.102.54.38_v1.fw`.

`pocketforge-automation/scripts/gpu-openrender-capture.sh` is the working recipe:

1. Fetch a selected `kernel-sunxi-6.x` ref, use its built `.config` and
   `Module.symvers`, require `CONFIG_DRM_POWERVR=m` and reject the alternate
   `DRM_POWERVR_ROGUE` ABI, run `olddefconfig`/`modules_prepare`, then build
   `M=drivers/gpu/drm/imagination` and take
   `drivers/gpu/drm/imagination/powervr.ko`.
2. Call `gpu-um-tsp/docker/build-ge8300-mesa-cross.sh`. That script archives the
   selected commit, pins `SOURCE_DATE_EPOCH`, and uses
   `docker/Dockerfile.ge8300-mesa-cross`; its current artifact is
   `libvulkan_powervr_mesa.so`, which the capture strips.
3. Replace `powervr.ko` and
   `opt/odyssey/pvr-testbed-lean/opt/mesa-pvr-drm/lib/aarch64-linux-gnu/libvulkan_powervr_mesa.so`
   in the minimal initramfs, and retain/replace both firmware copies with the
   unmodified firmware. The runtime load path is the standard
   `/lib/firmware/powervr/rogue_22.102.54.38_v1.fw`.

The image build should lift the build inputs and ABI checks, not copy the capture
bundle layout. In particular:

- the kernel stage already builds all in-tree modules, so `powervr.ko` should be
  taken from its `modules_install` output (and optionally checked explicitly),
  not rebuilt in a DDK-shaped stage;
- add a separate `gpu-um-src` locked context and `gpu-um` stage using the committed
  cross-build recipe or equivalent commands inside the pinned image container;
- stage Mesa's complete install tree, not only the capture's single ICD `.so`.
  The integration must install the Vulkan ICD JSON under
  `/usr/share/vulkan/icd.d` (with its `library_path` matching the installed
  `libvulkan_powervr_mesa.so`) and the applicable Mesa/GLVND EGL, GLES, GL, GBM,
  and DRI outputs/symlinks under the normal multiarch paths. The exact output
  inventory is an acceptance artifact of the Mesa-stage bead: the current
  `build-ge8300-mesa-cross.sh` exports only the Vulkan library and therefore is
  not yet a shipping libGL/EGL build recipe.
- remove `/usr/lib/pvr-rogue`, `00-pvr.conf`, vendor client-API links, `pvrsrvctl`,
  and DDK firmware/module installs from the open rootfs path. Run `ldconfig`,
  `depmod` using the discovered 6.x kernel release, and validate the ICD JSON
  against the staged filesystem.

### Firmware custody gap found during scoping

The currently pinned `vendor-manifest` (`5c3c412…`) has no independent open
PowerVR firmware group: its only PowerVR group combines closed UM, closed DDK KM,
and the old `rgx.*` firmware. The currently pinned `blobs` record likewise does
not expose `fw-6976702` under a fetchable open-firmware group. Therefore “drop
closed UM, keep firmware” requires a small custody change, not merely deleting
`pvr-ddk-22.102.54.38` from the profile: add an open-firmware-only manifest group
for the already preserved unmodified bytes, with the required
`powervr/rogue_22.102.54.38_v1.fw` destination, then pin the resulting blobs and
vendor-manifest commits. Do not keep the composite DDK group, because doing so
would continue fetching all closed UM/KM bytes even if rootfs stopped installing
them.

## File-by-file change set

### Step B is adoption, not a greenfield schema

Scoping for step B found the KM/UM split is already half-built, so B's job is
**decoupling the is-A133 proxy from `PF_GPU_REPO`**, not designing the schema
from scratch:

- `platform/platform.lock` already pins both `gpu-km-tsp` and `gpu-um-tsp`
  (at merged mitigation SHA `43fc908`) as ordinary name/url/ref/sha entries —
  no lock-schema change is needed.
- `platform/core/profile.py` `env_lines()`/`build_args()` already emit
  `PF_GPU_KM_MODEL`/`PF_GPU_KM_REPO`/`PF_GPU_KM_REF`/`PF_GPU_KM_SHA` (falling
  back to the legacy `repo` field) and `PF_GPU_UM_REPO`/`PF_GPU_UM_REF`/
  `PF_GPU_UM_SHA`. These are currently dead: `build/Dockerfile.pf` still reads
  only the legacy `PF_GPU_REPO`.
- `platform/devices/a133-open/profile.toml` already exists with
  `km_model=in-tree-6.x`, `km_repo=kernel-sunxi-6.x`, `um_repo=gpu-um-tsp`,
  and `modules=[powervr.ko]`; base-profile inheritance already respects its
  explicit `repo=""` override.
- `platform/core/pf-build.sh` already stages the `gpu-um-src` archive context
  (gated on `PF_GPU_MODEL=open`) and passes it as a named Docker build
  context — nothing consumes it yet; that consumer is step C's Mesa stage,
  not B.

So step B's remaining work is narrower than a schema design: wire the
already-emitted KM/UM args so step C can consume them, and — the part this
plan was missing — decouple the four *device-identity* gates below from
`PF_GPU_REPO`, which is a GPU-model value, not a device-identity value.

### Decoupling the is-A133 proxy

`PF_GPU_REPO == gpu-km-tsp` (or `!=`) doubles as an "is this an A133 device"
proxy in several `Dockerfile.pf` stages. That breaks once `PF_GPU_REPO` is
empty under `a133-open` (the open profile's GPU repo field), which would
wrongly NOT-SHIP components that have nothing to do with the GPU choice.
Four stages are affected, of two different kinds:

- **Pure device-identity proxies (zero GPU relation)** — must ship for every
  A133 variant regardless of GPU model:
  - `wpa` stage — the owned XR829 `wpa_supplicant` fork.
  - `runtime` stage — `pf-input-decode`, `pf-session-authorityd`, `pf-prefsd`.
  - `launcher` stage — `pf-shell`.
- **GPU-adjacent but mis-keyed** — `sdl` (`libsdl3-sunxifb`) legitimately
  depends on the GPU choice (it links the PowerVR userspace), but keying it
  on the *closed*-KM value specifically wrongly NOT-SHIPs it for
  `a133-open`; it must be selected for both A133 GPU models, then link
  whichever userspace the model resolves to (that link recipe is step C's
  concern — B only needs to stop excluding the stage).

The fix is a declarative is-A133 signal, not a `PF_GPU_REPO` string compare —
following the precedent already in-tree: the `assemble` stage was migrated
off this same proxy onto `PF_BOOT_PROTO` (see the Dockerfile.pf comment
"declarative, not the `PF_GPU_REPO` proxy"). The candidate signal is `PF_SOC`
(`sun50iw10p1` for A133, `sun55iw3` for A523) — already exported by
`profile.py`'s `env_lines()` but not yet by `build_args()` — or an explicit
`PF_DEVICE_FAMILY` field if a self-documenting boolean is preferred; either
way it must be base-profile-inherited so `a133-open` picks it up without a
per-variant override. `rootfs`'s master per-device dispatch
(`case "$PF_GPU_REPO"`) needs the same treatment, so `a133-open` takes the
A133 rootfs branch; only the GPU-module install sub-step inside that branch
stays keyed on `PF_GPU_MODEL` (closed vs open).

### Residual hardcodes left for step D

Decoupling the proxy *gates* does not remove the closed-stack assumptions
still baked into the rootfs branch's *contents* — step D's removal targets,
left untouched by B:

- the hard-coded `/lib/modules/4.9.191` install/`depmod` path (must become
  the discovered 6.x release for `a133-open`);
- the closed-vs-open kernel-module divergence itself: `pvrsrvkm.ko` +
  `dc_sunxi.ko` (closed DDK) vs the in-tree `powervr.ko` (open), which
  selects a different initrd/module-install set, not merely a different
  file list.

### `platform`

- `platform.lock`: add exact pins for `kernel-sunxi-6.x` (`device/a133`) and
  `gpu-um-tsp` (at least `43fc908`); bump the manifest/blob pins after the
  firmware-only group lands. Keep the 4.9 and DDK pins for `a133` rollback.
- `devices/a133-open/profile.toml`: inherit `a133`, set `id=a133-open`, override
  kernel repo/ref/defconfig/DTB, select an explicit open GPU-stack model, set the
  in-tree module list to `powervr.ko`, identify `gpu-um-tsp`, and replace the DDK
  blob group with the firmware-only group. Profile schema should model KM and UM
  separately rather than overload the existing `gpu.repo` field.
- `core/profile.py` and schema/tests: export separate KM model/repo and UM
  repo/ref/SHA fields; preserve inheritance and fail closed when the open profile
  lacks either pin or its firmware group.
- `core/pf-build.sh` and tests: create/export a `gpu-um-src` archive/context and
  its SHA/epoch. Device-specific stages must gate on `PF_DEVICE_ID` or a declared
  capability, not on `PF_GPU_REPO`.

### `image`

- `build/Dockerfile.pf`: add the `gpu-um-src` context and Mesa stage; make the
  DDK `gpu-km` stage closed-profile-only; for the open model extract and verify
  in-tree `powervr.ko` from the kernel stage. Copy the Mesa install tree into
  rootfs. Re-point the `wpa`, `runtime`, `launcher` (`pf-shell`), and `sdl`
  stage gates, and the `rootfs` stage's master `case "$PF_GPU_REPO"` dispatch,
  off the `PF_GPU_REPO` proxy so `a133-open` retains all four A133-specific
  components and reaches rootfs assembly, without linking `sdl` against the DDK.
- `scripts/build-rootfs.sh` (or a narrowly separate open-A133 customizer): remove
  hard-coded `4.9.191`; install the full kernel modules tree and run `depmod` for
  its discovered release; install Mesa/ICD and open firmware; do not install any
  DDK UM/KM artifact. Preserve XR829 firmware and other board services, while
  auditing whether the 6.x tree supplies compatible XR829 modules.
- `scripts/build-sd-image.sh`: replace the unconditional `pvrsrvkm.ko` assertion
  with a profile/model-specific GPU artifact check; accept the 6.x DTB name/path.
- tests for Docker stage selection, rootfs file inventory, ICD JSON resolution,
  module release/vermagic, negative absence of the eight closed UM libraries and
  two DDK modules, and closed-`a133` non-regression.
- `libsdl3-sunxifb` is a separate risk: it currently links the vendor UM and is
  gated by the DDK identity. Either add a DRM/KMS + Mesa backend for open A133 or
  select a different shipping display/compositor path; do not silently reuse the
  vendor-linked binary in the “open” image.

### `vendor-manifest` and `blobs`

- add a firmware-only group and custody record for the unmodified
  `fw-6976702`/`b571cdd9` bytes; preserve CID and SHA-256 provenance;
- ensure its manifest destination is the kernel firmware-loader path;
- leave `pvr-ddk-22.102.54.38` unchanged for the closed profile, but omit it from
  `a133-open`.

## 4.9 dependency and peripheral risk audit

No other device profile selects `kernel-sunxi-4.9`; `a523` independently selects
`kernel-sunxi-5.15`. However, both `a133-owned` and any future profile inheriting
`a133` receive 4.9 unless they override it. More importantly, the image contains
behavioral 4.9 dependencies: hard-coded release paths, XR829 module discovery,
the vendor fbdev/disp2-oriented `libsdl3-sunxifb` path, `videobuf2-dma-contig`
selection, and A133 gating by the DDK repo name.

The 6.x tree has a full-board-looking TSP DTS with panel/DSI, MMC, XR829 node,
AXP717-as-AXP2202 regulators/battery, USB, and GPU wiring, and its defconfig
enables the open DRM driver and relevant display/input/power families. That is
source evidence of intent, not proof of shipping function. The open-render run
used a minimal bundle and a GPU-specific DTB contract. Treat every peripheral
above as unproven until the full image's collector/test reports pass.

## Ordered implementation beads

Each bead below must end with its own commit/push/PR/merge gate. Dependencies are
listed by sequence label so the coordinator can translate them to bead IDs.

| # | Tier | Repo and files | Acceptance | Depends on |
|---|---|---|---|---|
| A | `exec` | `blobs`, `vendor-manifest`: firmware custody record, manifest group, fetch test | Firmware-only group fetches the exact preserved SHA/CID to `powervr/rogue_22.102.54.38_v1.fw`; group contains no DDK UM/KM file; existing DDK group unchanged | none |
| B | `think` | `platform`: `platform.lock`, profile schema, `core/profile.py`, `core/pf-build.sh`, tests; `image`: `build/Dockerfile.pf` is-A133 gate re-point (`wpa`, `runtime`, `launcher`, `sdl`, `rootfs` dispatch) | Lock resolves exact 6.x and Mesa SHAs; separate KM/UM fields and `gpu-um-src` context resolve for a fixture; missing pin/group fails; existing `a133`, `a133-owned`, and `a523` resolved outputs unchanged. **Required, not optional:** the `wpa`, `runtime`, `launcher`, and `sdl` stages are re-pointed off the `PF_GPU_REPO` proxy onto the declarative is-A133 signal (`PF_SOC`/`PF_DEVICE_FAMILY`) — an `a133-open` build must SELECT (not NOT-SHIP) all four stages. The `rootfs` stage's master per-device dispatch (`case "$PF_GPU_REPO"`) is re-pointed the same way, so `a133-open` reaches rootfs assembly instead of being excluded from it. B is not done while any of the four gate stages, or the rootfs dispatch, still keys on `PF_GPU_REPO` | A |
| C | `think` | `image`: `build/Dockerfile.pf`, Mesa build/stage tests (and `gpu-um-tsp/docker/*` only if its reusable recipe must export a full install tree) | Hermetic source build emits `powervr.ko` from the locked kernel plus a complete Mesa install tree; ICD JSON resolves to an AArch64 library; provenance includes both SHAs; no DDK build or closed input is consumed in open mode | B |
| D | `think` | `image`: `scripts/build-rootfs.sh` or open customizer, `build-sd-image.sh`, SDL/display selection, rootfs tests | **Explicit hardcode removal (required):** the `/lib/modules/4.9.191` install/`depmod` path is replaced with the discovered 6.x kernel release; the closed `pvrsrvkm.ko`/`dc_sunxi.ko` DDK pair is replaced by the in-tree `powervr.ko` module in the open rootfs branch; `build-sd-image.sh`'s unconditional `pvrsrvkm.ko`-exists assertion is replaced by a profile/model-specific GPU artifact check. Synthetic/open rootfs also has open firmware, Mesa GL/EGL/GLES/Vulkan/GBM/ICD wiring, and XR829/runtime services; the `sdl` stage links the open Mesa userspace (not the closed UM) for `a133-open`; contains none of the closed PowerVR libraries, `pvrsrvkm.ko`, or `dc_sunxi.ko`; closed A133 fixture remains unchanged | C |
| E | `exec` | `platform`: `devices/a133-open/profile.toml` and profile/lock tests | `pf resolve/build --device a133-open --dry-run` selects 6.x, open KM/UM, and firmware-only group; `a133` still selects 4.9/DDK/composite group; `a133-owned` inheritance is unchanged | B, D |
| F | `think` | `image` + `platform` candidate refs; full image build on modelmaker only | Canonical full `a133-open` build passes, is reproducible at pinned refs, records artifact SHA-256, module/firmware/ICD inventory, and closed-blob absence; no device action in this bead | E |
| G | `think` | `kernel-sunxi-6.x` DTS/config/drivers as findings require; automation `pf-test` collectors/envelopes if missing | On the held bench DUT through sanctioned automation: boot/current kernel, rootfs/storage, panel/backlight, Wi-Fi, input, audio, USB, PMIC/regulators/battery, and claimed suspend/resume pass; every failure becomes a bounded source-first follow-up and the same candidate is rebuilt/retested | F |
| H | `exec` | device-validation bead using existing automation; `gpu-um-tsp` only via follow-up fixes | On-panel real UI/cube/application is full-frame by camera review; Vulkan ICD/device is open PowerVR; repeated runs are stable; memory peak, allocation failures, frame rate, and bandwidth/thermal proxies are recorded against the closed baseline; mitigation limitations (mipmapped/oversized/explicit-modifier cases) are exercised or explicitly release-blocking | G |
| I | `think` | release/cutover across `platform` profile and docs | Owner/coordinator accepts G/H evidence; change the default `a133` mapping with a documented rollback to the preserved closed profile; build and verify the exact release candidate; independent review and all merge gates pass | H |

Beads B-D, F-G, and I are `think` because a plausible error can silently select
the wrong source/ABI or break boot and peripherals. A and E are bounded schema/data
work after the design is fixed. H is `exec` only when its commands and pass bars
are fully specified by G; any newly discovered presentation architecture work is
a separate `think` bead.

## Cutover rule

Do not reinterpret “open-render capture reached 100% coverage” as “the open image
is ready.” Keep `a133` closed and shippable until A-H are merged and the exact
full-image candidate passes both the peripheral matrix and real on-panel workload
gate. Only then dispatch I. If 6.x peripheral bring-up or the Mesa/SDL presentation
path is incomplete, continue shipping `a133` and keep `a133-open` as the explicit
integration target; do not mix open userspace with the 4.9 DDK KM or retain the
closed composite blob group under an “open” label.
