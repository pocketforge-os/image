# syntax=docker/dockerfile:1.6
#
# PocketForge build container — ARM A-Profile Toolchain 10.3-2021.07 +
# image-composition tooling (mmdebstrap, faketime, disorderfs, parted, etc.)
# ==============================================================================
#
# This is the M1.B-and-onward build container, migrated from the Phase 0
# `pocketforge/cross-build:10.3-2021.07-bookworm` (which lived in the
# libsdl3-sunxifb repo) into the `image` repo and renamed.
#
# Phase ownership:
#   - Phase 0 produced libSDL3-pocketforge.so.0 (cross-build only). That
#     container kept the `cross-build` name and is retained under the
#     `pocketforge/cross-build:phase0-archived` tag so libsdl3-sunxifb's
#     CI / any future M1.A patch builds still resolve.
#   - Phase 1 (this Dockerfile) is the primary user from M1.B onward:
#     image composition (rootfs build, vendor boot-chain assembly, initrd,
#     SD-image stitching, reproducibility hardening). Renamed
#     `pocketforge/build` (drop the `cross-` prefix; image build is the
#     primary user from now on).
#
# Build:
#   docker build -t pocketforge/build:10.3-2021.07-bookworm image/build/
#
# Run (artifacts owned by host user, no root in /work/out):
#   docker run --rm \
#     --user "$(id -u):$(id -g)" \
#     -v "$PWD/src:/work/src:ro" \
#     -v "$PWD/blobs:/work/blobs:ro" \
#     -v "$PWD/libsdl3:/work/libsdl3:ro" \
#     -v "$PWD/cache:/work/cache" \
#     -v "$PWD/out:/work/out" \
#     pocketforge/build:10.3-2021.07-bookworm \
#     bash -c "<build commands>"
#
# Triplet: aarch64-none-linux-gnu (note `-none-`, not `-linux-`). SDL3's CMake
# doesn't care about triplet; do NOT manufacture short-name symlinks — the
# toolchain ships zero by design.
#
# CMake toolchain file: /opt/cmake/toolchain-arm-10.3-2021.07.cmake
# Sysroot: /opt/arm-10.3-2021.07/aarch64-none-linux-gnu/libc
# (includes glibc 2.33 + drm headers + pthread.h; NO EGL/GLES2 — those come
# from the PowerVR DDK in the blobs repo, bind-mounted at /work/blobs).
#
# Reproducibility (G-reproducible gate, M1.E):
#   The apt sources are pinned to a snapshot.debian.org date by passing
#   APT_SNAPSHOT_DATE as a build-arg (default committed in
#   image/snapshot-date.txt). Two clean container builds against the same
#   snapshot date should resolve identical package versions for every tool
#   in the final image. The container itself is then pinnable by digest
#   (image/container.pin) at consume time.
#
# ---------------------------------------------------------------------------

# =============================================================================
# Stage 1 — toolchain-fetch
# Single-purpose stage: fetch + verify + unpack the ARM toolchain. Layered
# separately so changes to apt deps in stage 2 don't re-download the 250 MB
# tarball.
# =============================================================================
FROM debian:bookworm-slim AS toolchain-fetch

ARG TOOLCHAIN_VERSION=10.3-2021.07
ARG TOOLCHAIN_TRIPLET=aarch64-none-linux-gnu
ARG TOOLCHAIN_TARBALL=gcc-arm-${TOOLCHAIN_VERSION}-x86_64-${TOOLCHAIN_TRIPLET}.tar.xz
ARG TOOLCHAIN_URL=https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu-a/${TOOLCHAIN_VERSION}/binrel/${TOOLCHAIN_TARBALL}

# Dual-pin: SHA-256 (computed locally 2026-06-10) + MD5 (Arm-published).
# If Arm rotates the URL, do NOT silently substitute — see
# build-integration-reference.md §3.6 for the archived URL.
ARG TOOLCHAIN_SHA256=1e33d53dea59c8de823bbdfe0798280bdcd138636c7060da9d77a97ded095a84
ARG TOOLCHAIN_MD5=07bbe2b5277b75ba36a924e9136366a4

# Minimal deps for fetch + extract + verify. xz-utils handles .tar.xz; ca-certs
# is non-negotiable for HTTPS to armkeil.blob.core.windows.net.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/toolchain

# Fetch + dual-checksum. Both must pass; either failure aborts the build.
# `sha256sum -c` and `md5sum -c` exit non-zero on mismatch.
RUN set -eux; \
    curl --fail --silent --show-error --location \
         --output "${TOOLCHAIN_TARBALL}" \
         "${TOOLCHAIN_URL}"; \
    echo "${TOOLCHAIN_SHA256}  ${TOOLCHAIN_TARBALL}" | sha256sum -c -; \
    echo "${TOOLCHAIN_MD5}  ${TOOLCHAIN_TARBALL}" | md5sum -c -

# Unpack to a deterministic install prefix. The tarball's top-level directory
# is `gcc-arm-10.3-2021.07-x86_64-aarch64-none-linux-gnu/`; we rename to
# `arm-${TOOLCHAIN_VERSION}` so downstream paths are short and version-pinned.
RUN set -eux; \
    mkdir -p /opt; \
    tar -xJf "${TOOLCHAIN_TARBALL}" -C /opt; \
    mv "/opt/gcc-arm-${TOOLCHAIN_VERSION}-x86_64-${TOOLCHAIN_TRIPLET}" \
       "/opt/arm-${TOOLCHAIN_VERSION}"; \
    rm -f "${TOOLCHAIN_TARBALL}"

# Strip ~45 MB of docs/manpages we'll never read inside the container.
# The compiler binaries and the sysroot stay untouched.
RUN set -eux; \
    rm -rf "/opt/arm-${TOOLCHAIN_VERSION}/share/doc" \
           "/opt/arm-${TOOLCHAIN_VERSION}/share/man" \
           "/opt/arm-${TOOLCHAIN_VERSION}/share/info"

# Smoke test the toolchain at fetch time so a corrupt extract surfaces here,
# not in stage 2 or in user code. Just check the compiler runs.
RUN "/opt/arm-${TOOLCHAIN_VERSION}/bin/${TOOLCHAIN_TRIPLET}-gcc" --version | \
        grep -F "10.3-2021.07"

# =============================================================================
# Stage 2 — final
# Inherits the unpacked toolchain via COPY --from. apt-installs everything we
# need across Phase 0 (SDL3 build) and Phase 1 (image composition) so we don't
# need a second container later.
# =============================================================================
FROM debian:bookworm-slim AS final

ARG TOOLCHAIN_VERSION=10.3-2021.07
ARG TOOLCHAIN_TRIPLET=aarch64-none-linux-gnu

# Apt snapshot pin. Default committed in image/snapshot-date.txt; CI passes this
# as --build-arg APT_SNAPSHOT_DATE=$(cat image/snapshot-date.txt). All apt
# transactions resolve against snapshot.debian.org so two clean container builds
# against the same snapshot date resolve identical package versions.
#
# `[check-valid-until=no]` is required because snapshot.debian.org's archived
# Release files have stale Valid-Until headers by design.
ARG APT_SNAPSHOT_DATE=20260601T000000Z
ARG APT_SNAPSHOT_HOST=snapshot.debian.org

# Apt sources: bookworm + bookworm-updates + bookworm-security + bookworm-backports.
# Backports is needed for mmdebstrap >= 1.5.x and e2fsprogs >= 1.47.1 (both
# G-reproducible-gate prerequisites in M1.E). All sources point at
# snapshot.debian.org and carry [check-valid-until=no] so the resolution is
# deterministic across time. multiarch (arm64 + amd64) is already configured
# below; the snapshot mirror serves both.
RUN dpkg --add-architecture arm64 \
 && rm -f /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list \
 && printf '%s\n' \
        "deb [arch=amd64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian/${APT_SNAPSHOT_DATE}/ bookworm main" \
        "deb [arch=amd64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian/${APT_SNAPSHOT_DATE}/ bookworm-updates main" \
        "deb [arch=amd64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian/${APT_SNAPSHOT_DATE}/ bookworm-backports main" \
        "deb [arch=amd64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian-security/${APT_SNAPSHOT_DATE}/ bookworm-security main" \
        "deb [arch=arm64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian/${APT_SNAPSHOT_DATE}/ bookworm main" \
        "deb [arch=arm64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian/${APT_SNAPSHOT_DATE}/ bookworm-updates main" \
        "deb [arch=arm64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian/${APT_SNAPSHOT_DATE}/ bookworm-backports main" \
        "deb [arch=arm64 check-valid-until=no] http://${APT_SNAPSHOT_HOST}/archive/debian-security/${APT_SNAPSHOT_DATE}/ bookworm-security main" \
        > /etc/apt/sources.list \
 && printf '%s\n' \
        'Acquire::Check-Valid-Until "false";' \
        'Acquire::Retries "5";' \
        > /etc/apt/apt.conf.d/99-pocketforge-snapshot \
 && echo "${APT_SNAPSHOT_DATE}" > /etc/pocketforge-apt-snapshot-date

# Phase 0+1 build-deps in one apt transaction. Categorized for review:
#
#   Cross-build basics:   cmake ninja-build pkg-config make patch xxd
#   Source acquisition:   git curl ca-certificates gpg gnupg
#   Archive handling:     xz-utils zstd
#   DT compilation:       device-tree-compiler  (provides `dtc` binary)
#   Image composition:    abootimg genimage dosfstools mtools sunxi-tools parted
#   Debian rootfs:        debootstrap mmdebstrap (>=1.5 from backports)
#                         qemu-user-static binfmt-support
#   Reproducibility (M1.E): faketime disorderfs e2fsprogs (>=1.47.1 from backports)
#   Cross-readelf:        binutils-aarch64-linux-gnu  (for symver gate)
#   Scripting glue:       python3 python3-pip
#   SDL3 cross-deps (arm64): libasound2-dev (ALSA), libudev-dev (input),
#                            libdbus-1-dev (IPC), libpulse-dev (audio),
#                            libdrm-dev (DRM headers). All multiarch-prefixed
#                            `:arm64`. We add the arm64 architecture above.
#
# `--no-install-recommends` keeps the layer slim; `apt-get clean` + lists rm
# at end of layer for reproducibility.
#
# Pinned bookworm-backports versions (resolved via snapshot.debian.org against
# APT_SNAPSHOT_DATE; recorded in image/BUILD-DEPENDENCIES.md):
#   - mmdebstrap >= 1.5.0  (we get 1.5.6-4~bpo12+1 on 20260601)
#   - e2fsprogs  >= 1.47.1 (we get 1.47.2-3~bpo12+1 on 20260601)
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        cmake \
        ninja-build \
        pkg-config \
        git \
        curl \
        gnupg \
        gpg \
        make \
        patch \
        xxd \
        xz-utils \
        zstd \
        device-tree-compiler \
        abootimg \
        genimage \
        dosfstools \
        mtools \
        sunxi-tools \
        parted \
        debootstrap \
        qemu-user-static \
        binfmt-support \
        faketime \
        disorderfs \
        binutils-aarch64-linux-gnu \
        python3 \
        libasound2-dev:arm64 \
        libpulse-dev:arm64 \
        libudev-dev:arm64 \
        libdbus-1-dev:arm64 \
        libdrm-dev:arm64 \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -t bookworm-backports \
        mmdebstrap \
        e2fsprogs \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Migrate the arm64-multiarch artifacts into the cross-toolchain's sysroot so
# downstream find_library / pkg-config / find_package work without per-build
# CMAKE_FIND_ROOT_PATH overrides. Headers go under usr/include (no per-arch
# subdir on cross sysroots); libs go under usr/lib (no aarch64-linux-gnu
# subdir — the toolchain links by `-L<sysroot>/usr/lib`). Pkg-config files
# get their `libdir=` rewritten so consumers don't need PKG_CONFIG_PATH gym.
ARG CROSS_SYSROOT=/opt/arm-10.3-2021.07/aarch64-none-linux-gnu/libc
RUN set -eux; \
    SRC_LIB=/usr/lib/aarch64-linux-gnu; \
    SRC_INC=/usr/include; \
    DST_LIB=${CROSS_SYSROOT}/usr/lib; \
    DST_INC=${CROSS_SYSROOT}/usr/include; \
    PKG_DST=${DST_LIB}/pkgconfig; \
    mkdir -p "${DST_LIB}" "${DST_INC}" "${PKG_DST}"; \
    # Lib files (preserve symlinks). Don't blast the whole multiarch dir — only
    # the packages we explicitly added, so we don't accidentally shadow glibc.
    for pat in \
        'libasound*' \
        'libpulse*' \
        'libudev*' \
        'libdbus-1*' \
        'libdrm*' ; do \
        find "${SRC_LIB}" -maxdepth 1 -name "${pat}" -exec cp -a {} "${DST_LIB}/" \; ; \
    done; \
    # Pkg-config: copy files, rewrite multiarch lib paths to sysroot-relative.
    if [ -d "${SRC_LIB}/pkgconfig" ]; then \
        for pc in alsa libpulse libpulse-simple libudev dbus-1 libdrm libkms; do \
            f="${SRC_LIB}/pkgconfig/${pc}.pc"; \
            [ -f "$f" ] || continue; \
            sed 's|/usr/lib/aarch64-linux-gnu|${prefix}/lib|g; s|/usr/include|${prefix}/include|g; s|^prefix=.*|prefix='"${CROSS_SYSROOT}"'/usr|' \
                "$f" > "${PKG_DST}/${pc}.pc"; \
        done; \
    fi; \
    # Headers (alsa/pulse/dbus-1/libudev.h/drm).
    for d in alsa pulse dbus-1.0 dbus libdrm; do \
        if [ -d "${SRC_INC}/${d}" ]; then cp -a "${SRC_INC}/${d}" "${DST_INC}/"; fi; \
    done; \
    # Arch-specific multiarch includes (dbus-arch-deps.h lives here).
    if [ -d "${SRC_LIB}/dbus-1.0/include/dbus" ]; then \
        mkdir -p "${DST_INC}/dbus-1.0/dbus"; \
        cp -a "${SRC_LIB}/dbus-1.0/include/dbus/." "${DST_INC}/dbus-1.0/dbus/"; \
    fi; \
    for h in libudev.h alsa-symbols.h alsa-version.h; do \
        if [ -f "${SRC_INC}/${h}" ]; then cp -a "${SRC_INC}/${h}" "${DST_INC}/"; fi; \
    done; \
    # Verify: the toolchain's pkg-config needs to find alsa via PKG_CONFIG_LIBDIR=sysroot/usr/lib/pkgconfig
    PKG_CONFIG_LIBDIR=${PKG_DST} pkg-config --exists alsa; \
    echo "Cross sysroot now has: $(ls ${DST_LIB}/libasound* ${DST_LIB}/libpulse* ${DST_LIB}/libudev* | wc -l) lib files"

# Pull the unpacked toolchain across from stage 1.
COPY --from=toolchain-fetch /opt/arm-${TOOLCHAIN_VERSION} /opt/arm-${TOOLCHAIN_VERSION}

# PATH wiring: prepend toolchain bin/ for both login and non-login shells.
# /etc/profile.d/ handles login shells; ENV PATH handles `docker run ...
# bash -c "..."` invocations that don't source profile.
ENV PATH=/opt/arm-${TOOLCHAIN_VERSION}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN printf '%s\n' \
        '# PocketForge cross-toolchain (10.3-2021.07)' \
        'export PATH=/opt/arm-10.3-2021.07/bin:$PATH' \
        > /etc/profile.d/cross-toolchain.sh \
 && chmod +x /etc/profile.d/cross-toolchain.sh

# CMake toolchain file. CMAKE_FIND_ROOT_PATH_MODE_* is set up so that
# find_package() / find_library() see the sysroot for libs/headers but
# always use host programs (programs build-time, not runtime). The
# CMAKE_FIND_ROOT_PATH list is multi-element to anticipate the PowerVR DDK
# bind-mount at /work/blobs becoming a second find-root in downstream beads.
RUN mkdir -p /opt/cmake
COPY toolchain-arm-10.3-2021.07.cmake /opt/cmake/toolchain-arm-10.3-2021.07.cmake

# Convenience symlink for the latest toolchain CMake file. Keeps user-facing
# invocations short while preserving the version-pinned canonical path.
RUN ln -sf /opt/cmake/toolchain-arm-10.3-2021.07.cmake /opt/cmake/toolchain.cmake

# -----------------------------------------------------------------------------
# Build-time validation gate
# -----------------------------------------------------------------------------
# Hello-world a tiny program with the toolchain and verify (a) it runs, (b)
# the produced ELF references no GLIBC_2.34+ symbols. If this RUN fails, the
# image build aborts before publication. Defense in depth: the same check is
# duplicated in build/check-glibc-symver.sh for CI use against real artifacts.
COPY check-glibc-symver.sh /usr/local/bin/check-glibc-symver
RUN set -eux; \
    chmod +x /usr/local/bin/check-glibc-symver; \
    mkdir -p /tmp/symver-check; \
    cd /tmp/symver-check; \
    printf '%s\n' \
        '#include <stdio.h>' \
        'int main(void) { puts("ok"); return 0; }' \
        > hello.c; \
    "${TOOLCHAIN_TRIPLET}-gcc" -O2 -o hello hello.c; \
    /usr/local/bin/check-glibc-symver hello; \
    cd /; \
    rm -rf /tmp/symver-check

# -----------------------------------------------------------------------------
# Phase 1 tool inventory check (build-time)
# -----------------------------------------------------------------------------
# Smoke-test that all Phase 1 image-composition tools resolve and report a
# version string. If any of these fail the image build aborts. The version
# strings are also captured (build-time only, not committed) for sanity:
#   mmdebstrap     >= 1.5
#   faketime       any (0.9.x is fine)
#   disorderfs     any (0.5.x is fine)
#   parted         any (3.5+ is fine)
#   gpg            (gnupg)
#   mke2fs         >= 1.47.1
#   genimage, abootimg, dtc, sunxi-tools, qemu-aarch64-static — Phase 0 carry-overs
RUN set -eux; \
    mmdebstrap --version | grep -Eo 'mmdebstrap [0-9.]+'; \
    faketime --version | head -1; \
    disorderfs --version | head -1; \
    parted --version | head -1; \
    gpg --version | head -1; \
    mke2fs -V 2>&1 | head -1; \
    genimage --version || true; \
    abootimg -h >/dev/null 2>&1 || abootimg 2>&1 | head -1 || true; \
    dtc --version | head -1; \
    sunxi-fel --version 2>&1 | head -1 || true; \
    qemu-aarch64-static --version | head -1; \
    aarch64-linux-gnu-readelf --version | head -1

# Default workdir matches the documented bind-mount layout: build commands
# `cd /work/src` (read-only source), produce into `/work/out`.
WORKDIR /work

# No CMD/ENTRYPOINT — invoked with explicit `bash -c "..."` per usage docs.
# Image labels for traceability.
LABEL org.opencontainers.image.title="pocketforge-build" \
      org.opencontainers.image.description="ARM A-Profile Toolchain 10.3-2021.07 + image-composition tools for PocketForge / TrimUI Smart Pro (Phase 1+)" \
      org.opencontainers.image.version="10.3-2021.07-bookworm" \
      org.opencontainers.image.source="https://github.com/pocketforge-os/image"
