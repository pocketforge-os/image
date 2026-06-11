# BUILD-DEPENDENCIES — pocketforge/build container

Tool inventory for `pocketforge/build:10.3-2021.07-bookworm`. This container
is the single build environment for Phase 1+ image-composition work. The Phase
0 container (`pocketforge/cross-build:10.3-2021.07-bookworm`) is retained as
`pocketforge/cross-build:phase0-archived` so libsdl3-sunxifb's CI / any Phase 1
patch builds against the SDL3 forward-port still resolve.

For container-pin-by-digest see `image/container.pin`. For the apt-snapshot
pin see `image/snapshot-date.txt`.

## Cross-toolchain (pinned input, NOT from apt)

| Item | Version / pin | Provenance |
|---|---|---|
| ARM A-Profile Toolchain | `10.3-2021.07` | `armkeil.blob.core.windows.net`; SHA-256 + MD5 dual-pinned in Dockerfile |
| gcc | `10.3.1` | from the toolchain |
| glibc (sysroot) | `2.33` | from the toolchain (matches TSP) |
| Triplet | `aarch64-none-linux-gnu` | (note `-none-`, not `-linux-`; do NOT add symlinks) |
| Sysroot path | `/opt/arm-10.3-2021.07/aarch64-none-linux-gnu/libc` |  |
| CMake toolchain file | `/opt/cmake/toolchain-arm-10.3-2021.07.cmake` (also symlinked at `toolchain.cmake`) |  |

## apt-installed tools (resolved at container build time against snapshot.debian.org)

The Dockerfile pins `APT_SNAPSHOT_DATE` (default in `image/snapshot-date.txt`,
currently `20260601T000000Z`) so two clean container builds resolve identical
package versions. To re-resolve at a newer snapshot date, bump
`image/snapshot-date.txt` (a deliberate operator action, never automatic), then
rebuild and re-record `image/container.pin` with the new image digest.

Versions resolved at `APT_SNAPSHOT_DATE=20260601T000000Z` (recorded for audit;
the Dockerfile does NOT pin `=<version>` in `apt install` — it relies on the
snapshot date for determinism, so apt picks "latest at that date" for each
package, which is unique per snapshot date).

### Cross-build basics

| Package | Source | Notes |
|---|---|---|
| `cmake` | bookworm | |
| `ninja-build` | bookworm | |
| `pkg-config` | bookworm | |
| `make`, `patch`, `xxd` | bookworm | |
| `git`, `curl`, `gnupg`, `gpg` | bookworm | source acquisition + signature verify |
| `xz-utils`, `zstd`, `cpio` | bookworm | archive handling (`cpio` assembles the hand-rolled initrd, bead `tsp-iuz.1.6`) |
| `python3` | bookworm | scripting glue |
| `binutils-aarch64-linux-gnu` | bookworm | `aarch64-linux-gnu-readelf` for the symver gate |

### Image composition (Phase 1 M1.B + M1.E)

| Package | Source | Min version | Notes |
|---|---|---|---|
| `mmdebstrap` | **bookworm-backports** | **>= 1.5.0** | Reproducible Debian rootfs builder. Resolved as `1.5.6-4~bpo12+1` at the pinned snapshot date. Stock bookworm has 1.3.x — too old for the G-reproducible-gate determinism mmdebstrap 1.5+ guarantees. |
| `e2fsprogs` | **bookworm-backports** | **>= 1.47.1** | Provides `mke2fs -d <tar>` with stable inode order. Resolved as `1.47.2-3~bpo12+1`. Stock bookworm has 1.47.0 — missing the recipe Reproducible-Builds.org documents. |
| `faketime` | bookworm | any | Wall-clock spoofing for tools that embed timestamps (dragonsecboot, genimage). NOT to be combined with parallel `make -jN` (libfaketime races). |
| `disorderfs` | bookworm | any | Sorted directory listings during rootfs assembly. |
| `parted` | bookworm | any | GPT partition layout for SD images. |
| `debootstrap` | bookworm | any | Carry-over from Phase 0 (mmdebstrap is the actual tool we use; debootstrap stays for fallback). |
| `qemu-user-static` | bookworm | any | aarch64-on-amd64 emulation for mmdebstrap rootfs setup hooks. |
| `binfmt-support` | bookworm | any | binfmt_misc registration helper. |
| `device-tree-compiler` | bookworm | any | Provides `dtc` for compiling per-device DTBs. |
| `abootimg` | bookworm | any | Android-style `boot.img` packing (kernel + initrd + cmdline). |
| `genimage` | bookworm | any | SD image stitching from a YAML descriptor. |
| `dosfstools` | bookworm | any | FAT32 for the boot-resource partition. |
| `mtools` | bookworm | any | FAT manipulation without root. |
| `sunxi-tools` | bookworm | any | Provides `sunxi-fel` (FEL recovery) and related Allwinner utilities. |

### SDL3 cross-build deps (arm64 multiarch, Phase 0 carry-over)

| Package | Source | Notes |
|---|---|---|
| `libasound2-dev:arm64` | bookworm | ALSA dev headers (audio) |
| `libpulse-dev:arm64` | bookworm | PulseAudio dev (SDL3 builds with both ALSA + Pulse) |
| `libudev-dev:arm64` | bookworm | udev (joystick/input) |
| `libdbus-1-dev:arm64` | bookworm | DBus IPC |
| `libdrm-dev:arm64` | bookworm | DRM headers (we don't use KMS but SDL3's CMake checks for `drm.h`) |

These are migrated into the cross-toolchain's sysroot at container build time
(see Dockerfile stage 2's "Migrate the arm64-multiarch artifacts" RUN step) so
SDL3's CMake + pkg-config + find_package work without per-build
`CMAKE_FIND_ROOT_PATH` overrides.

### Baked-in initrd payload (arm64, NOT on the host PATH)

| Item | Path in container | Notes |
|---|---|---|
| `busybox-arm64` | `/opt/pocketforge/initrd-payload/busybox-arm64` | Statically-linked AArch64 `busybox-static` (Debian, from the snapshot mirror), extracted at container-build time. SHA-256 recorded at `…/busybox-arm64.sha256`. The hand-rolled initrd (`tsp-iuz.1.6`) uses it as `/init`'s first process. Baked in (not apt-installed) because the initrd build runs as a non-root `--user` that can't `apt-get download`, and `busybox-static:arm64` collides with the amd64 busybox on `/usr/bin/busybox`. A snapshot bump that changes busybox surfaces as a changed SHA in the container build log. |

### dragonsecboot (vendored source tree, not apt)

`dragonsecboot` is **vendored** at `image/tools/dragonsecboot/dragonsecboot`
(precompiled static x86_64 binary with `-pack`, from `bkleiner/hdzero-goggle-tools`
commit `66703c7b…`, the upstream of KNULLI's `host-allwinner-utils`). Bead
`tsp-iuz.1.4` (closed). It is consumed from the bind-mounted `/work/src`, not
installed into the container. (Retraction: an earlier draft cited FriendlyARM's
`h3_lichee` commit `75b584e2…`; that is an older H3-era binary without `-pack`.)

## Bind-mount layout (runtime, not baked in)

The container runs as `--user $(id -u):$(id -g)` (no `USER` directive in the
image). Documented bind-mount paths:

| Mount | Mode | Purpose |
|---|---|---|
| `/work/src` | read-only | source tree (e.g. `image` repo checkout, `libsdl3-sunxifb` checkout) |
| `/work/blobs` | read-only | clone of the private `blobs` repo (PowerVR DDK + vendor kernel `Image` + `/lib/modules/` + WiFi firmware + boot chain — the latter three added in M1.B/M1.C) |
| `/work/libsdl3` | read-only | `libSDL3-pocketforge.so.0` release artifact from `libsdl3-sunxifb`'s CI |
| `/work/cache` | read-write | apt cache, mmdebstrap cache (persisted across runs) |
| `/work/out` | read-write | final artifacts |

## Pinning policy

- The cross-toolchain is pinned by SHA-256 + MD5 in the Dockerfile.
- All apt-resolved tools are pinned by the `APT_SNAPSHOT_DATE` build-arg →
  `image/snapshot-date.txt`. Bumping the snapshot date is a deliberate operator
  action (never automatic) that requires a fresh image build and a re-recorded
  `image/container.pin`.
- Consumers of the container (image-build CI, libsdl3-sunxifb CI) reference
  the container by `@sha256:digest` from `image/container.pin`, never by `:tag`.
  Tag-pinning lets a base-layer rebuild silently break reproducibility.

> **`container.pin` is STALE as of 2026-06-12 (bead `tsp-iuz.1.6`).** The
> Dockerfile gained a baked-in `busybox-arm64` initrd payload + `cpio` this
> session and was rebuilt locally (image id `fadc8f24a05a`), but the container
> was **not** re-pushed to the registry, so `container.pin` still holds the
> previous digest (`sha256:98fed4f9…`). Re-pin on the next deliberate
> container-publish pass (natural fit for M1.E's CI hardening): push the rebuilt
> container, then `docker inspect … RepoDigests` → write the new
> `image@sha256:` line into `container.pin` in one commit. The local rebuild is
> what every initrd/image build this session ran against; reproducibility of the
> *initrd artifact* is already verified (`logs/m1b-initrd-build-verification.txt`).

## Fallback if the container becomes burdensome

Per `AGENTS.md`: if the container pipeline blocks Phase 1 progress for more
than ~half a day (slow iteration, opaque failures), **stop and ask the user**
before pivoting. The fallback is bare cross-compile on the host with the
toolchain unpacked at `/opt/arm-10.3-2021.07/` (same toolchain, same sysroot —
just no container layer). The CMake toolchain file's absolute paths work
identically on host and container. `mmdebstrap`/`faketime`/`disorderfs` etc.
are the same Debian binaries; they install on Ubuntu 24.04 from
bookworm-backports if needed.
