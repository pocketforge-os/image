# PocketForge Image Builder

Builds the bootable SD card image for the TrimUI Smart Pro. Composes:

- Debian 12 bookworm arm64 rootfs (`mmdebstrap` against a frozen
  `snapshot.debian.org` mirror)
- PowerVR fbdev DDK integration (vendor blobs from the private `blobs` repo)
- `libSDL3-pocketforge.so.0` (forward-ported sunxifb backend, from
  `libsdl3-sunxifb`)
- Steam Link first-boot bootstrap (signed-manifest `[fetch]` contract via the
  `pocketforge-kiosk-supervisor`)
- App install trees (from the `apps` monorepo)
- SD-boot layout (vendor SPL/BL31/U-Boot at raw offsets, mkbootimg `boot.img`
  on a named GPT partition)

Produces both `pocketforge-tsp-YYYY.MM.img.xz` (release) and
`pocketforge-tsp-dev-YYYY.MM.img.xz` (dev) variants from one pipeline,
controlled by a `--variant=dev|release` flag, as a GitHub Release.

Populated through **Phase 1**. See the
[pocketforge-os](https://github.com/pocketforge-os) org for the full repo set.

## Repo layout (early Phase 1)

```
image/
├── build/                     # cross-build container (this directory)
│   ├── Dockerfile             # pocketforge/build:10.3-2021.07-bookworm
│   ├── toolchain-arm-10.3-2021.07.cmake
│   ├── check-glibc-symver.sh  # CI gate: refuse any GLIBC_2.34+ binary
│   └── README.md              # container usage docs
├── BUILD-DEPENDENCIES.md      # tool inventory + version pins
├── container.pin              # sha256 digest of the built container (consumers pin by digest)
├── snapshot-date.txt          # apt snapshot.debian.org pin (single line, e.g. 20260601T000000Z)
├── README.md                  # this file
└── (Phase 1 M1.B+ adds: boards/, tools/dragonsecboot/, rootfs-packages.txt, Makefile, ...)
```

## Build the container

```sh
docker build \
    --build-arg "APT_SNAPSHOT_DATE=$(cat snapshot-date.txt)" \
    -t pocketforge/build:10.3-2021.07-bookworm \
    build/
```

Two-stage: stage 1 fetches the ARM A-Profile Toolchain `10.3-2021.07` (gcc 10.3
/ glibc 2.33), stage 2 builds the final image with all Phase 0+1 tooling on
`debian:bookworm-slim` against `snapshot.debian.org`. Final image size ~1.5 GB
(grew from Phase 0's 1.34 GB by ~150 MB for the new mmdebstrap/e2fsprogs/
faketime/disorderfs/parted/qemu/etc. tooling layer).

## After build: record the digest

```sh
echo "pocketforge/build:10.3-2021.07-bookworm@$(docker inspect \
    pocketforge/build:10.3-2021.07-bookworm --format '{{.Id}}')" \
    > container.pin
git add container.pin && git commit -m "image: bump container.pin"
```

`image-build` CI references the container by `@sha256:digest` from
`container.pin`, never by `:tag`. Tag-pinning lets a base-layer rebuild
silently break reproducibility.

## Phase 0 container (still required for libsdl3-sunxifb's CI)

The Phase 0 container `pocketforge/cross-build:10.3-2021.07-bookworm` is
retained under the tag `pocketforge/cross-build:phase0-archived`. It produces
`libSDL3-pocketforge.so.0` from the `libsdl3-sunxifb` repo. The
`pocketforge/build:10.3-2021.07-bookworm` container in this repo is its
superset (same toolchain + everything Phase 0 needed + the new Phase 1
image-composition tooling), so libsdl3-sunxifb can also build with the new
container if convenient — but it is not required to migrate.

## Pinning policy

Reproducibility is M1.E's gate but the container is the foundation:
- **Cross-toolchain**: SHA-256 + MD5 dual-pinned in the Dockerfile.
- **All apt tools**: pinned by `APT_SNAPSHOT_DATE` build-arg →
  `snapshot-date.txt` → `snapshot.debian.org` mirror.
- **The container itself**: pinned by `@sha256:digest` in `container.pin`.
- **Bumping any of the three** is an explicit operator action that requires a
  fresh build + re-record + commit in one PR.
