# PocketForge build container

Reproducible cross-build environment for `libSDL3-pocketforge.so.0`, the full
PocketForge SD-image pipeline, and every other Phase 1+ build artifact.
Targets the TrimUI Smart Pro: 64-bit ARM, Cortex-A53 / A133P SoC,
**glibc 2.33** rootfs.

The toolchain pin is non-negotiable. See [why](#why-the-toolchain-pin) below.

## Build the image

```sh
docker build \
    --build-arg "APT_SNAPSHOT_DATE=$(cat ../snapshot-date.txt)" \
    -t pocketforge/build:10.3-2021.07-bookworm \
    .
```

(Run from `image/build/`.) Two-stage: stage 1 fetches the ARM A-Profile
Toolchain `10.3-2021.07` (~250 MB), verifies SHA-256 + MD5, unpacks under
`/opt/arm-10.3-2021.07/`, strips docs/manpages. Stage 2 builds the final
image on `debian:bookworm-slim` against `snapshot.debian.org` (apt sources
all carry `[check-valid-until=no]` and resolve against the snapshot date).
Final image size ~1.5 GB.

A build-time hello-world + symver gate runs at the end of stage 2; if it
references any `GLIBC_2.34+` symbol the image build aborts. A separate
build-time tool inventory check verifies all Phase 1 image-composition tools
(mmdebstrap, faketime, disorderfs, parted, e2fsprogs, etc.) resolve and
report a version string.

## Use the image

The container expects a documented bind-mount layout:

| Mount | Mode | Purpose |
| --- | --- | --- |
| `/work/src` | read-only | source tree (e.g. `image` repo, `libsdl3-sunxifb` repo) |
| `/work/blobs` | read-only | private `blobs` repo (PowerVR DDK + vendor kernel + boot chain) |
| `/work/libsdl3` | read-only | `libSDL3-pocketforge.so.0` release artifact |
| `/work/cache` | read-write | apt cache, mmdebstrap cache (persisted) |
| `/work/out` | read-write | artifact output |

Run with `--user $(id -u):$(id -g)` so artifacts dropped into `/work/out`
are owned by the calling host user, not by root.

Example shape (cross-build SDL3 from `libsdl3-sunxifb`):

```sh
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$HOME/libsdl3-sunxifb:/work/src:ro" \
    -v "$HOME/blobs:/work/blobs:ro" \
    -v "$HOME/libsdl3-sunxifb/_build:/work/out" \
    pocketforge/build:10.3-2021.07-bookworm \
    bash /work/src/build/build-libsdl3.sh
```

## CMake toolchain file

Shipped at `/opt/cmake/toolchain-arm-10.3-2021.07.cmake`. Symlink convenience
path at `/opt/cmake/toolchain.cmake`. Pass it via `-DCMAKE_TOOLCHAIN_FILE=`.

Sysroot is `/opt/arm-10.3-2021.07/aarch64-none-linux-gnu/libc`. It has glibc
2.33 + drm headers + pthread.h + the migrated arm64-multiarch headers
(alsa/pulse/udev/dbus/drm), but **no EGL/GLES2** — those live in the PowerVR
DDK and bind-mount in via `/work/blobs`. Downstream CMake should append
`/work/blobs/path/to/ddk-includes` to `CMAKE_FIND_ROOT_PATH`; the toolchain
file is structured so this is purely additive.

The triplet is `aarch64-none-linux-gnu` (note the `-none-`, not the Linux
convention `-linux-`). SDL3's CMake doesn't care about the triplet; do NOT
manufacture short-name symlinks — the toolchain has zero by design.

## Verify a built artifact

```sh
docker run --rm \
    -v "$PWD/_build:/work/out:ro" \
    pocketforge/build:10.3-2021.07-bookworm \
    check-glibc-symver /work/out/some-binary.elf
```

Or run `check-glibc-symver.sh` directly on the host (only requires `readelf`
from binutils). The script exits non-zero if any binary references a
`GLIBC_2.34+` symbol — suitable as a CI gate before publishing artifacts.

## Why the toolchain pin

Stock Ubuntu 24.04 `gcc-aarch64-linux-gnu` is gcc-13 / glibc 2.34. TSP runs
glibc 2.33 and rejects 2.34-versioned binaries at startup with `version
'GLIBC_2.34' not found`. Workarounds investigated and **rejected**:

- `.symver`-wrap to redirect 2.34 symbols → fails because `__libc_start_main`
  is the typical 2.34 culprit and isn't user-facing
- musl-static → fails because vendor `libsrv_um.so` requires glibc-only
  symbols (`backtrace`, `backtrace_symbols`, `__strdup`)
- bundled glibc 2.39 → fails because vendor libs transitively link
  `librt.so.1` from glibc 2.33 and reject 2.39's `GLIBC_PRIVATE` symbols

**The pinned canonical toolchain is ARM A-Profile `10.3-2021.07`**:

- URL: `https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu-a/10.3-2021.07/binrel/gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu.tar.xz`
- SHA-256: `1e33d53dea59c8de823bbdfe0798280bdcd138636c7060da9d77a97ded095a84`
- MD5 (Arm-published): `07bbe2b5277b75ba36a924e9136366a4`
- gcc 10.3.1, glibc 2.33

Both checksums are pinned in the Dockerfile and verified at fetch time. If
Arm rotates the URL, **do not silently substitute** — surface to the user;
archived-URL fallback is documented in
`build-integration-reference.md` §3.6.

For full forensics see:
- `build-integration-reference.md` §3.6 — toolchain pin rationale
- `hardware-firmware-probes.md` §11.5 — failed-workaround inventory
- `pocketforge-plan.md` §15 row 15 — Risk #15 (build-host cross-toolchain pin)

## Migration from Phase 0

This Dockerfile is the M1.B migration of the Phase 0 cross-build container
that lived in `libsdl3-sunxifb/build/`. Renamed
`pocketforge/cross-build:10.3-2021.07-bookworm` →
`pocketforge/build:10.3-2021.07-bookworm` (drop the `cross-` prefix; image
build is the primary user from now on).

The Phase 0 image is retained under the tag
`pocketforge/cross-build:phase0-archived` so libsdl3-sunxifb's CI continues
to resolve. The new `pocketforge/build` is a strict superset of Phase 0's
container (same toolchain + everything Phase 0 needed + the new Phase 1
tooling), so libsdl3-sunxifb can also build with the new container if
convenient — but is not required to migrate.

Phase 1 additions on top of Phase 0:

- `mmdebstrap` (>= 1.5.x, bookworm-backports): reproducible Debian rootfs
  builder — replaces `debootstrap` for M1.C+
- `e2fsprogs` (>= 1.47.1, bookworm-backports): provides `mke2fs -d <tar>`
  with stable inode order — required by the deterministic-ext4 recipe in M1.E
- `faketime`: wall-clock spoofing for tools that embed timestamps
  (dragonsecboot, genimage)
- `disorderfs`: sorted directory listings during rootfs assembly
- `parted`: GPT partition layout for SD images
- `gnupg` (gpg): signature verification for `[fetch]` and signed releases
- `binutils-aarch64-linux-gnu` (Phase 0 carried this; still needed for the
  symver gate)
- `zstd`: archive-handling additions

Filed as bead `tsp-iuz.1.1`; landed as part of the M1.B opening.

## Fallback if the container becomes burdensome

Per `AGENTS.md`: if the container pipeline blocks Phase 1 progress for more
than ~half a day (slow iteration, opaque failures), **stop and ask the user**
before pivoting. The fallback is bare cross-compile on the host with the
toolchain unpacked at `/opt/arm-10.3-2021.07/` (same toolchain, same sysroot
— just no container layer). The toolchain file at
`/opt/cmake/toolchain-arm-10.3-2021.07.cmake` works identically on host and
container because all paths are absolute. The new Phase 1 tools all install
on Ubuntu 24.04 too (mmdebstrap from bookworm-backports if needed; the rest
from Ubuntu 24.04 main).
