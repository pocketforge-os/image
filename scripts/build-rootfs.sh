#!/usr/bin/env bash
# =============================================================================
# build-rootfs.sh — Build the PocketForge Debian rootfs (TrimUI Smart Pro)
# =============================================================================
# Creates a Debian 12 bookworm arm64 rootfs via mmdebstrap, installs all
# PocketForge-specific components (PowerVR DDK, kernel modules, firmware,
# libSDL3, configs), and assembles a deterministic ext4 filesystem image.
#
# Runs INSIDE the pocketforge/build container AS ROOT (mmdebstrap needs
# real chroot/mount privileges for cross-arch builds). The container
# provides the isolation boundary — this script never touches the host.
# Output files are chown'd to the caller's uid:gid at the end.
#
# Inputs via bind mounts:
#   /work/src       (ro)  — this image repo
#   /work/blobs     (ro)  — blobs repo checkout
#   /work/libsdl3   (ro)  — libSDL3-pocketforge.so.0 release artifact
#   /work/out       (rw)  — build output (userdata.ext4 written here)
#
# Usage:
#   build-rootfs.sh [--variant dev|release] [--owner UID:GID]
#
# Environment:
#   SOURCE_DATE_EPOCH  — reproducible timestamp (default: git head commit)
#
# bd: tsp-iuz.2.1
# =============================================================================
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SRC_DIR="${SRC_DIR:-/work/src}"
BLOBS_DIR="${BLOBS_DIR:-/work/blobs}"
# GPU model discriminator (tsp-mc9m.41.924.2 / B4): "ddk" (closed PowerVR DDK, default —
# preserves today's behavior) or "open" (a133-open's in-tree Mesa/PowerVR KM). Gates ONLY
# the pvrsrvkm.ko/dc_sunxi.ko-vs-powervr.ko module-install sub-step below; the closed-UM
# .so + firmware install stays UNCONDITIONAL for THIS bead (step D removes/reworks it —
# see the tsp-mc9m.41.924.2 bead comment for the full handoff list).
PF_GPU_MODEL="${PF_GPU_MODEL:-ddk}"
LIBSDL3_DIR="${LIBSDL3_DIR:-/work/libsdl3}"
# The C1 open-Mesa install tree (tsp-mc9m.41.924.6 / C4): its own /usr/local/{include,lib}
# meson DESTDIR install — only meaningful (non-marker-only) for PF_GPU_MODEL=open.
GPU_UM_MESA_DIR="${GPU_UM_MESA_DIR:-/work/gpu-um-mesa}"
WPA_DIR="${WPA_DIR:-/work/wpa}"
RUNTIME_DIR="${RUNTIME_DIR:-/work/runtime}"   # E2 runtime binaries (pf-input-decode) from the runtime stage (tsp-e1b.11)
LAUNCHER_DIR="${LAUNCHER_DIR:-/work/launcher}"
OUT_DIR="${OUT_DIR:-/work/out}"
BOARD_DIR="${SRC_DIR}/boards/tsp"

VARIANT="dev"
SUBSTRATE="owned"
OWNER_UID=""
OWNER_GID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --variant)     VARIANT="$2"; shift 2 ;;
        --owner)       OWNER_UID="${2%%:*}"; OWNER_GID="${2##*:}"; shift 2 ;;
        --substrate)   SUBSTRATE="$2"; shift 2 ;;
        *) echo "build-rootfs.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Phase 2 owned-substrate paths (bind-mounted by the Makefile)
KERNEL_TSP_DIR="${KERNEL_TSP_DIR:-/work/kernel-tsp}"
GPU_KM_TSP_DIR="${GPU_KM_TSP_DIR:-/work/gpu-km-tsp}"

if [ "$VARIANT" != "dev" ] && [ "$VARIANT" != "release" ]; then
    echo "FATAL: --variant must be 'dev' or 'release', got '${VARIANT}'" >&2
    exit 2
fi

# Reproducible timestamp
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    if git -C "${SRC_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        SOURCE_DATE_EPOCH="$(git -C "${SRC_DIR}" log -1 --format=%ct)"
    else
        SOURCE_DATE_EPOCH=1700000000
    fi
fi
export SOURCE_DATE_EPOCH

# Load committed UUIDs
# shellcheck source=boards/tsp/fs-uuids.env
source "${BOARD_DIR}/fs-uuids.env"

# Frozen snapshot mirror
SNAPSHOT_DATE="$(cat "${SRC_DIR}/snapshot-date.txt")"
SNAPSHOT_URL="http://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE}/"

# Working directory
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "========================================================================"
echo "PocketForge rootfs builder"
echo "========================================================================"
echo "  variant:   ${VARIANT}"
echo "  substrate: ${SUBSTRATE}"
echo "  epoch:     ${SOURCE_DATE_EPOCH}"
echo "  snapshot:  ${SNAPSHOT_URL}"
echo "  blobs:     ${BLOBS_DIR}"
echo "  kernel-tsp: ${KERNEL_TSP_DIR}"
echo "  gpu-km-tsp: ${GPU_KM_TSP_DIR}"
echo "  libsdl3:   ${LIBSDL3_DIR}"
echo "  out:       ${OUT_DIR}"
echo "========================================================================"

mkdir -p "${OUT_DIR}"

# ---- step 1: merge package list --------------------------------------------
echo ""
echo "=== Step 1/4: Merge package list ==="

PKG_FILE="${SRC_DIR}/rootfs-packages.txt"
PKG_DEV_FILE="${SRC_DIR}/rootfs-packages-dev.txt"

[ -f "${PKG_FILE}" ] || { echo "FATAL: ${PKG_FILE} not found" >&2; exit 1; }

# Strip comments and blank lines, merge into comma-delimited list
PKG_LIST="$(grep -v '^\s*#' "${PKG_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"

if [ "${VARIANT}" = "dev" ] && [ -f "${PKG_DEV_FILE}" ]; then
    DEV_PKGS="$(grep -v '^\s*#' "${PKG_DEV_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"
    PKG_LIST="${PKG_LIST},${DEV_PKGS}"
    echo "  variant=dev: added dev-only packages (${DEV_PKGS})"
fi

# Zink needs the Khronos Vulkan loader, but the open GPU model is opt-in.
# Keep the shared package set byte-identical for closed a133 by appending the
# loader only to the package list passed to this open-model mmdebstrap run.
if [ "${PF_GPU_MODEL}" = "open" ]; then
    PKG_LIST="${PKG_LIST},libvulkan1"
    echo "  gpu_model=open: added open-GPU package (libvulkan1)"
fi

echo "  package list: ${PKG_LIST}"

# ---- step 2: verify prerequisites ------------------------------------------
echo ""
echo "=== Step 2/4: Verify prerequisites ==="

# Verify qemu-aarch64 binfmt is working (host kernel, propagated into container).
# The F flag on the host binfmt registration means the kernel handles dispatch
# transparently — /proc/sys/fs/binfmt_misc/ may not be visible inside the
# container, so we test actual arm64 execution instead of checking the proc entry.
if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "  binfmt: qemu-aarch64 registered (proc entry visible)"
elif command -v qemu-aarch64-static >/dev/null 2>&1; then
    # Try running the baked-in arm64 busybox to verify binfmt dispatch works
    BB_ARM64="/opt/pocketforge/initrd-payload/busybox-arm64"
    if [ -f "${BB_ARM64}" ] && "${BB_ARM64}" true 2>/dev/null; then
        echo "  binfmt: arm64 execution verified (busybox-arm64 ran successfully)"
    else
        echo "  binfmt: qemu-aarch64-static present; assuming binfmt F-flag dispatch works"
    fi
else
    echo "FATAL: no arm64 binfmt support detected" >&2
    echo "  Install qemu-user-static + binfmt-support on the HOST and restart binfmt-support." >&2
    exit 1
fi

# Verify blobs exist (closed-DDK model only — tsp-mc9m.41.924.2 / B4 review fix: the
# a133-open blob groups carry NO closed GPU blob group at all, so this spot-check would
# FATAL every open-model rootfs dispatch before it ever reaches the DEFERRED marker
# below. Step C/D wire the open-Mesa equivalent; the DEFERRED gates in the customize
# hook below are what actually skip the closed install.)
if [ "${PF_GPU_MODEL}" = "ddk" ]; then
    for f in \
        "${BLOBS_DIR}/sunxi/a133/22.102.54.38/lib/libEGL.so" \
        "${BLOBS_DIR}/sunxi/a133/22.102.54.38/firmware/rgx.fw.22.102.54.38"; do
        [ -f "$f" ] || { echo "FATAL: required blob not found: $f" >&2; exit 1; }
    done
else
    # Open GPU model (tsp-mc9m.41.924.6 / C4): verify the C1 gpu-um-mesa stage produced a
    # REAL install tree, not just its NOT-SHIPPED-for-ddk marker (which would mean the
    # Dockerfile's PF_GPU_MODEL/gpu-um-mesa-${PF_GPU_MODEL} selector picked the wrong stage).
    for f in \
        "${GPU_UM_MESA_DIR}/usr/local/lib/libEGL.so" \
        "${GPU_UM_MESA_DIR}/usr/local/lib/libGLESv2.so" \
        "${GPU_UM_MESA_DIR}/usr/local/lib/libgbm.so" \
        "${GPU_UM_MESA_DIR}/usr/local/lib/gbm/dri_gbm.so"; do
        [ -f "$f" ] || { echo "FATAL: open Mesa userspace not found: $f (gpu-um-mesa stage did not build for gpu_model=open?)" >&2; exit 1; }
    done
    echo "  open Mesa GLES/EGL/GBM userspace: ${GPU_UM_MESA_DIR}/usr/local (spot-check passed)"
fi

# GPU modules from gpu-km-tsp, kernel modules from kernel-tsp. The closed-KM file names
# (pvrsrvkm.ko/dc_sunxi.ko) are DDK-model-specific — gated on PF_GPU_MODEL.
if [ "${PF_GPU_MODEL}" = "ddk" ]; then
    [ -f "${GPU_KM_TSP_DIR}/pvrsrvkm.ko" ] || { echo "FATAL: pvrsrvkm.ko not found at ${GPU_KM_TSP_DIR}/pvrsrvkm.ko" >&2; exit 1; }
    [ -f "${GPU_KM_TSP_DIR}/dc_sunxi.ko" ] || { echo "FATAL: dc_sunxi.ko not found at ${GPU_KM_TSP_DIR}/dc_sunxi.ko" >&2; exit 1; }

    KERNEL_VB2="$(find "${KERNEL_TSP_DIR}" -name 'videobuf2-dma-contig.ko' -type f | head -1)"
    [ -n "${KERNEL_VB2}" ] || { echo "FATAL: videobuf2-dma-contig.ko not found in kernel-tsp" >&2; exit 1; }
    # WiFi modules: the closed 4.9 kernel-tsp builds xr829_* (not xradio_*).
    KERNEL_WIFI_MAC="$(find "${KERNEL_TSP_DIR}" -name 'xr829_mac.ko' -type f | head -1)"
    KERNEL_WIFI_CORE="$(find "${KERNEL_TSP_DIR}" -name 'xr829_core.ko' -type f | head -1)"
    KERNEL_WIFI_WLAN="$(find "${KERNEL_TSP_DIR}" -name 'xr829_wlan.ko' -type f | head -1)"
    # All three are required: the closed install loop below FATALs on any missing one and
    # modules-load.d/pocketforge-wifi.conf loads the full triplet at boot. Spot-check
    # all three here so a broken kernel-tsp wifi build fails fast, before mmdebstrap.
    [ -n "${KERNEL_WIFI_MAC}" ] && [ -n "${KERNEL_WIFI_CORE}" ] && [ -n "${KERNEL_WIFI_WLAN}" ] \
        || { echo "FATAL: xr829 wifi module triplet (mac/core/wlan) not all found in kernel-tsp" >&2; exit 1; }
else
    # Open GPU model (tsp-mc9m.41.924.6 / C2/C4): the open KM is IN-TREE in kernel-sunxi-6.x
    # (devices/a133-open/profile.toml km_model="in-tree-6.x"), so powervr.ko comes from the
    # KERNEL stage's own modules_install output (KERNEL_TSP_DIR) — NOT gpu-km-tsp, which
    # DEFERS entirely for the open model (no DDK repo to build against). Spot-check it here.
    KERNEL_POWERVR="$(find "${KERNEL_TSP_DIR}" -name 'powervr.ko' -type f | head -1)"
    [ -n "${KERNEL_POWERVR}" ] || { echo "FATAL: powervr.ko not found in kernel-tsp (kernel-sunxi-6.x in-tree KM build)" >&2; exit 1; }
    KERNEL_VB2="$(find "${KERNEL_TSP_DIR}" -name 'videobuf2-dma-contig.ko' -type f | head -1)"
    [ -n "${KERNEL_VB2}" ] || { echo "FATAL: videobuf2-dma-contig.ko not found in kernel-tsp (open model)" >&2; exit 1; }
    # kernel-sunxi-6.x builds the upstream-shaped XR829 driver as one xradio.ko,
    # unlike the closed 4.9 tree's xr829_mac/core/wlan triplet.
    KERNEL_WIFI="$(find "${KERNEL_TSP_DIR}" -name 'xradio.ko' -type f | head -1)"
    [ -n "${KERNEL_WIFI}" ] || { echo "FATAL: xradio.ko not found in kernel-tsp (open model)" >&2; exit 1; }
    KERNEL_RELEASE_DIR="$(find "${KERNEL_TSP_DIR}" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "${KERNEL_RELEASE_DIR}" ] || { echo "FATAL: no kernel release dir under kernel-tsp (open model)" >&2; exit 1; }
    echo "  powervr.ko (in-tree, kernel-tsp): ${KERNEL_POWERVR}"
fi
# WiFi firmware still from blobs (same firmware regardless of module name)
[ -f "${BLOBS_DIR}/sunxi/a133/wifi-firmware/fw_xr829.bin" ] || { echo "FATAL: WiFi firmware not found in blobs" >&2; exit 1; }
echo "  blobs + kernel-tsp + gpu-km-tsp: spot-check passed"

# Verify libSDL3 artifact exists. The sdl stage builds a real sunxifb .so for BOTH
# GPU models now (tsp-mc9m.41.924.6 / C3 wires the open-Mesa link that used to leave a
# DEFERRED marker here for PF_GPU_MODEL=open — B3/tsp-mc9m.41.924.2), so this check no
# longer needs to branch on PF_GPU_MODEL.
LIBSDL3_SO="$(find "${LIBSDL3_DIR}" -name 'libSDL3-pocketforge.so*' -type f | head -1)"
[ -n "${LIBSDL3_SO}" ] || { echo "FATAL: libSDL3-pocketforge.so.* not found in ${LIBSDL3_DIR}" >&2; exit 1; }
echo "  libsdl3: ${LIBSDL3_SO}"

# Verify the owned wpa_supplicant artifact exists (wpa stage output; tsp-myp1.8.2).
# The a133 wlan supplicant is the owned wpa-supplicant-tsp fork — a missing
# artifact means a broken wpa stage, so fail fast (mirrors the libSDL3 gate)
# rather than silently shipping stock Debian wpasupplicant.
[ -f "${WPA_DIR}/wpa_supplicant" ] || { echo "FATAL: owned wpa_supplicant not found at ${WPA_DIR}/wpa_supplicant" >&2; exit 1; }
echo "  wpa: ${WPA_DIR}/wpa_supplicant"

# ---- step 3: mmdebstrap + customize ----------------------------------------
echo ""
echo "=== Step 3/4: mmdebstrap rootfs build ==="

ROOTFS_TAR="${WORK}/rootfs.tar"

# The customize-hook script runs OUTSIDE the chroot — $1 is the rootfs path.
# This is critical: we can copy files from /work/blobs into the rootfs
# by targeting "$1/path/in/rootfs".
CUSTOMIZE_SCRIPT="${WORK}/customize-hook.sh"
cat > "${CUSTOMIZE_SCRIPT}" << 'CUSTOMIZE_EOF'
#!/bin/bash
set -euo pipefail
ROOTFS="$1"

echo "[customize] Starting PocketForge rootfs customization..."

# --- User + groups -----------------------------------------------------------
echo "[customize] Creating groups and gamer user..."
# audio=29 is vendor-pinned (stock ALSA nodes are root:audio 0660)
# video=44, plugdev=27 are Debian-conventional
# input=105, render=106 are our choice (no stock precedent)
# Note: some groups may already exist from Debian base packages (e.g. audio,
# video may come from base-passwd). We use --force for existing groups and
# --non-unique to allow re-specifying a GID if the group exists with a different one.
chroot "$ROOTFS" groupadd -g 29 audio   2>/dev/null || chroot "$ROOTFS" groupmod -g 29 audio   2>/dev/null || true
chroot "$ROOTFS" groupadd -g 44 video   2>/dev/null || chroot "$ROOTFS" groupmod -g 44 video   2>/dev/null || true
chroot "$ROOTFS" groupadd -g 27 plugdev 2>/dev/null || chroot "$ROOTFS" groupmod -g 27 plugdev 2>/dev/null || true
chroot "$ROOTFS" groupadd -g 105 input  2>/dev/null || true
chroot "$ROOTFS" groupadd -g 106 render 2>/dev/null || true
chroot "$ROOTFS" groupadd -g 1000 gamer 2>/dev/null || true
chroot "$ROOTFS" useradd -u 1000 -g 1000 -m -d /home/gamer -s /bin/bash gamer
chroot "$ROOTFS" usermod -aG audio,input,video,render,plugdev gamer
chroot "$ROOTFS" passwd -l gamer
echo "[customize] gamer user created: $(chroot "$ROOTFS" id gamer)"

# --- GPU userspace install ---------------------------------------------------
# Closed PowerVR DDK (blob group) or open Mesa (tsp-mc9m.41.924.6 / C4), gated on
# PF_GPU_MODEL. a133-open's blob groups carry NO closed GPU blob group at all
# (devices/a133-open/profile.toml), so the ddk branch below would FATAL for it.
if [ "${PF_GPU_MODEL:-ddk}" = "ddk" ]; then
    echo "[customize] Installing PowerVR DDK userspace..."
    install -d "${ROOTFS}/usr/lib/pvr-rogue"
    for so in libEGL.so libGLESv2.so libGLES_CM.so libIMGegl.so \
              libsrv_um.so libusc.so libglslcompiler.so libpvrNULL_WSEGL.so; do
        install -m 0644 "/work/blobs/sunxi/a133/22.102.54.38/lib/${so}" "${ROOTFS}/usr/lib/pvr-rogue/${so}"
    done
    printf '/usr/lib/pvr-rogue\n' > "${ROOTFS}/etc/ld.so.conf.d/00-pvr.conf"
    chroot "$ROOTFS" ldconfig
    echo "[customize] PowerVR DDK: ldconfig done"

    # libIMGegl.so discovers its client-API drivers by dlopen()ing the UNVERSIONED
    # dev names (libGLESv2.so / libGLES_CM.so). ldconfig keys ld.so.cache by SONAME
    # (libGLESv2.so.2 …), so those dev-name dlopens miss the cache, IMGegl's baked
    # vendor RPATH doesn't exist on device, and /usr/lib/pvr-rogue is not in
    # glibc's built-in fallback path — leaving EGL_CLIENT_APIS empty (no GLES)
    # unless LD_LIBRARY_PATH=/usr/lib/pvr-rogue happens to be exported (tsp-ve5).
    # Symlink the dev names into the multiarch dir (always searched by dlopen) so
    # EGL client discovery works regardless of launch environment.
    for so in libEGL.so libGLESv2.so libGLES_CM.so; do
        ln -sf "/usr/lib/pvr-rogue/${so}" "${ROOTFS}/usr/lib/aarch64-linux-gnu/${so}"
    done
    echo "[customize] PowerVR DDK: dev-name dlopen symlinks installed in /usr/lib/aarch64-linux-gnu"

    # Verify SONAME symlinks were created by checking the filesystem directly
    # (ldconfig -p may not work reliably under qemu in all chroot configurations)
    if [ ! -L "${ROOTFS}/usr/lib/pvr-rogue/libEGL.so.1" ]; then
        echo "FATAL: ldconfig did not create libEGL.so.1 symlink in /usr/lib/pvr-rogue/" >&2
        echo "  Contents of /usr/lib/pvr-rogue/:" >&2
        ls -la "${ROOTFS}/usr/lib/pvr-rogue/" >&2
        exit 1
    fi
    echo "[customize] PowerVR DDK: SONAME symlinks verified (libEGL.so.1 exists)"
else
    # Open Mesa GLES/EGL/GBM userspace (tsp-mc9m.41.924.6 / C4): install the C1
    # gpu-um-mesa stage's FULL meson DESTDIR tree verbatim at the SAME prefix it was
    # built for (/usr/local) — the Zink DRI driver, gbm backend loader, and Vulkan ICD
    # all resolve each other via paths baked in at build time relative to that prefix
    # (e.g. GBM's dlopen of lib/gbm/dri_gbm.so), so preserving the prefix identity is
    # what keeps those baked-in paths valid post-install; translating the tree onto a
    # different prefix would need re-deriving every one of those compiled-in paths.
    echo "[customize] Installing open Mesa GLES/EGL/GBM userspace (Zink, GE8300)..."
    install -d "${ROOTFS}/usr/local"
    cp -a /work/gpu-um-mesa/usr/local/. "${ROOTFS}/usr/local/"
    printf '/usr/local/lib\n' > "${ROOTFS}/etc/ld.so.conf.d/00-mesa-powervr.conf"
    chroot "$ROOTFS" ldconfig
    echo "[customize] open Mesa: ldconfig done"
    if [ ! -L "${ROOTFS}/usr/local/lib/libEGL.so.1" ] && [ ! -f "${ROOTFS}/usr/local/lib/libEGL.so.1" ]; then
        echo "FATAL: libEGL.so.1 missing from ${ROOTFS}/usr/local/lib after install" >&2
        exit 1
    fi
    if [ -f /work/gpu-um-mesa/.pf-gpu-um-provenance ]; then
        install -D -m 0644 /work/gpu-um-mesa/.pf-gpu-um-provenance "${ROOTFS}/usr/share/pocketforge/gpu-um-mesa-provenance"
    fi
    echo "[customize] open Mesa: userspace install verified (libEGL.so.1 present)"

    # Zink is a Vulkan-on-GL translation layer: at runtime it needs the Khronos
    # Vulkan LOADER (libvulkan.so.1, from the open-only mmdebstrap package set) to find
    # and dlopen the imagination ICD via the manifest JSON above. The ICD JSON's
    # own "library_path" is an ABSOLUTE path baked in at Mesa build time
    # (meson.build: vulkan_icd_lib_path = prefix / libdir, i.e. /usr/local/lib —
    # NOT relative to the JSON file), so copying the JSON to a second location is
    # safe and does not need re-deriving any path. The loader's default manifest
    # search covers both /usr/local/share/vulkan/icd.d (where the Mesa DESTDIR
    # tree ships it, installed above) and /usr/share/vulkan/icd.d via
    # XDG_DATA_DIRS — but XDG_DATA_DIRS is not guaranteed to be set in every
    # runtime environment, so also install the JSON at the canonical
    # /usr/share/vulkan/icd.d path the loader falls back to unconditionally.
    ICD_JSON="$(find "${ROOTFS}/usr/local/share/vulkan/icd.d" -name '*.json' -type f | head -1)"
    [ -n "${ICD_JSON}" ] || { echo "FATAL: no Vulkan ICD JSON found under ${ROOTFS}/usr/local/share/vulkan/icd.d (open Mesa install incomplete)" >&2; exit 1; }
    install -d "${ROOTFS}/usr/share/vulkan/icd.d"
    install -m 0644 "${ICD_JSON}" "${ROOTFS}/usr/share/vulkan/icd.d/$(basename "${ICD_JSON}")"
    echo "[customize] open Mesa: ICD JSON also installed at /usr/share/vulkan/icd.d/$(basename "${ICD_JSON}") (loader default search path)"

    VULKAN_LOADER="$(find "${ROOTFS}/usr/lib" -name 'libvulkan.so.1*' -type f | head -1)"
    if [ -z "${VULKAN_LOADER}" ]; then
        echo "FATAL: libvulkan.so.1 (Khronos Vulkan loader) not found in open-model rootfs — Zink cannot dispatch to the imagination ICD. Check the open-only libvulkan1 package append." >&2
        exit 1
    fi
    echo "[customize] open Mesa: Vulkan loader present at ${VULKAN_LOADER#"${ROOTFS}"}"
fi

# --- Kernel modules install --------------------------------------------------
echo "[customize] Installing kernel modules..."

# KREL = the module-tree release dir EVERY module below lands in. Closed a133 keeps
# the pre-existing hardcoded "4.9.191" (unchanged — that is the closed kernel's own
# release string, and D's handoff item 2 owns generalizing this hardcode broadly).
# Open GPU model (tsp-mc9m.41.924.6 / C4 review round 2): derive the REAL
# kernel-sunxi-6.x release so the WHOLE module tree below — powervr.ko AND its
# in-tree dependencies — lands COHERENTLY in ONE correctly-versioned dir, instead
# of splitting across a bogus "4.9.191" dir (nothing on a 6.x kernel ever looks
# there) and a separate correctly-versioned dir holding only powervr.ko. This fixes
# The model-specific spot-check above verifies the open tree's actual module names.
if [ "${PF_GPU_MODEL:-ddk}" = "ddk" ]; then
    KREL="4.9.191"
else
    KREL="$(find /work/kernel-tsp -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -1)"
    [ -n "${KREL}" ] || { echo "FATAL: no kernel release dir under kernel-tsp (open model)" >&2; exit 1; }
fi
install -d "${ROOTFS}/lib/modules/${KREL}"

# Owned substrate: GPU modules from gpu-km-tsp, kernel modules from kernel-tsp
echo "[customize] Installing kernel + GPU modules (kernel-tsp + gpu-km-tsp) at lib/modules/${KREL}"

# Closed a133 keeps its hand-picked out-of-tree DDK modules plus the existing in-tree
# VB2/XR829 set. Open a133 copies the complete kernel modules_install release tree so
# powervr.ko's in-tree modular dependencies remain available.
if [ "${PF_GPU_MODEL:-ddk}" = "ddk" ]; then
    install -m 0644 "/work/gpu-km-tsp/pvrsrvkm.ko" "${ROOTFS}/lib/modules/${KREL}/"
    install -m 0644 "/work/gpu-km-tsp/dc_sunxi.ko" "${ROOTFS}/lib/modules/${KREL}/"

    # DMA buffer plumbing from kernel-tsp build tree
    VB2_KO="$(find /work/kernel-tsp -name 'videobuf2-dma-contig.ko' -type f | head -1)"
    install -m 0644 "${VB2_KO}" "${ROOTFS}/lib/modules/${KREL}/"

    # WiFi driver triplet: kernel-tsp builds xr829_* (vendor used xradio_*)
    # Module aliases (xradio_core -> xr829_core etc) make modprobe transparent.
    for mod in xr829_mac xr829_core xr829_wlan; do
        MOD_KO="$(find /work/kernel-tsp -name "${mod}.ko" -type f | head -1)"
        [ -n "${MOD_KO}" ] || { echo "FATAL: ${mod}.ko not found in kernel-tsp" >&2; exit 1; }
        install -m 0644 "${MOD_KO}" "${ROOTFS}/lib/modules/${KREL}/"
    done

    chroot "$ROOTFS" depmod "${KREL}"
    echo "[customize] Modules installed: $(ls "${ROOTFS}/lib/modules/${KREL}/"*.ko | wc -l) .ko files"
else
    cp -a "/work/kernel-tsp/${KREL}/." "${ROOTFS}/lib/modules/${KREL}/"

    DEPMOD_STDERR="$(mktemp)"
    if ! chroot "$ROOTFS" depmod "${KREL}" 2>"${DEPMOD_STDERR}"; then
        cat "${DEPMOD_STDERR}" >&2
        echo "FATAL: depmod ${KREL} failed for open kernel modules tree" >&2
        rm -f "${DEPMOD_STDERR}"
        exit 1
    fi
    cat "${DEPMOD_STDERR}" >&2
    if grep -Eiq 'warning|needs unknown symbol|not found' "${DEPMOD_STDERR}"; then
        echo "FATAL: depmod ${KREL} reported an unresolved dependency warning" >&2
        rm -f "${DEPMOD_STDERR}"
        exit 1
    fi
    rm -f "${DEPMOD_STDERR}"
    echo "[customize] Modules installed: $(find "${ROOTFS}/lib/modules/${KREL}" -name '*.ko' -type f | wc -l) .ko files"
fi

# Verify depmod produced output
if [ ! -s "${ROOTFS}/lib/modules/${KREL}/modules.dep" ]; then
    echo "FATAL: depmod ${KREL} produced empty modules.dep" >&2
    exit 1
fi

# --- Firmware install --------------------------------------------------------
echo "[customize] Installing firmware..."
install -d "${ROOTFS}/lib/firmware"

# GPU firmware (both files required — missing rgx.sh.* causes firmware-load failures).
# Closed-DDK model only (tsp-mc9m.41.924.2 / B4 review fix) — a133-open's blobs carry no
# GPU blob group, so this firmware doesn't exist yet for PF_GPU_MODEL=open.
if [ "${PF_GPU_MODEL:-ddk}" = "ddk" ]; then
    install -m 0644 "/work/blobs/sunxi/a133/22.102.54.38/firmware/rgx.fw.22.102.54.38" "${ROOTFS}/lib/firmware/"
    install -m 0644 "/work/blobs/sunxi/a133/22.102.54.38/firmware/rgx.sh.22.102.54.38" "${ROOTFS}/lib/firmware/"
else
    echo "[customize] PF_GPU_MODEL=${PF_GPU_MODEL:-} — closed GPU firmware install skipped (open Mesa install lands in step C/D)"
fi

# WiFi firmware
install -m 0644 "/work/blobs/sunxi/a133/wifi-firmware/fw_xr829.bin" "${ROOTFS}/lib/firmware/"
install -m 0644 "/work/blobs/sunxi/a133/wifi-firmware/boot_xr829.bin" "${ROOTFS}/lib/firmware/"
install -m 0644 "/work/blobs/sunxi/a133/wifi-firmware/sdd_xr829.bin" "${ROOTFS}/lib/firmware/"

echo "[customize] Firmware: $(ls "${ROOTFS}/lib/firmware/" | wc -l) files"

# --- libSDL3 install ---------------------------------------------------------
# The sdl stage builds a real sunxifb .so for BOTH GPU models now (tsp-mc9m.41.924.6 /
# C3/C4 review fix — closed-DDK-only was a review finding: this install stayed gated
# after C3 wired the open-Mesa link, so the a133-open FINAL rootfs never got the .so
# C3 had already built), so this install no longer branches on PF_GPU_MODEL.
echo "[customize] Installing libSDL3-pocketforge..."
install -d "${ROOTFS}/opt/pocketforge/lib"
# Find the libSDL3 artifact (may be named .so.0 or .so.0.5.0)
LIBSDL3_SRC="$(find /work/libsdl3 -name 'libSDL3-pocketforge.so*' -type f | head -1)"
install -m 0755 "${LIBSDL3_SRC}" "${ROOTFS}/opt/pocketforge/lib/libSDL3-pocketforge.so.0"

# SDL test binaries (bd tsp-tyt) — dev variant only; present only when the sdl
# stage built them (a133/sunxifb). Lets the sunxifb functional gate
# (SDL_VIDEODRIVER=sunxifb testgles2) run on-device without scp.
if [ "${POCKETFORGE_VARIANT:-dev}" = "dev" ] && [ -d /work/libsdl3/testbin ] && ls /work/libsdl3/testbin/* >/dev/null 2>&1; then
    install -d "${ROOTFS}/opt/pocketforge/bin"
    install -m 0755 /work/libsdl3/testbin/* "${ROOTFS}/opt/pocketforge/bin/"
    # Let the test bins resolve their SDL DT_NEEDED (either soname spelling) from
    # /opt/pocketforge/lib via the runtime linker.
    ln -sf libSDL3-pocketforge.so.0 "${ROOTFS}/opt/pocketforge/lib/libSDL3.so.0"
    printf '/opt/pocketforge/lib\n' > "${ROOTFS}/etc/ld.so.conf.d/01-pocketforge.conf"
    chroot "$ROOTFS" ldconfig
    echo "[customize] SDL test binaries installed to /opt/pocketforge/bin (dev variant)"
fi

# --- Owned wpa_supplicant install (tsp-myp1.8.2; pattern from tsp-urq.7) -------
# Overwrite the stock Debian /sbin/wpa_supplicant with the owned
# wpa-supplicant-tsp build (2.10 + GREAT_SNR 25->45 roam hysteresis) from the
# hermetic wpa stage. The Debian "wpasupplicant" package still provides the
# runtime deps (libnl/openssl — the fork links a strict subset), wpa_cli, and
# the wpa_supplicant@wlan0 systemd wiring; only the binary is replaced (the
# Debian unit's ExecStart resolves /sbin/wpa_supplicant, so no unit edit).
# Presence was gated fail-fast in step 2; re-verify the arch here at install.
echo "[customize] Installing owned wpa_supplicant (overwriting stock Debian /sbin/wpa_supplicant)..."
# Sanity: must be an aarch64 ELF, or we would brick WiFi with a wrong-arch
# binary. Read the ELF e_machine (bytes 18-19) directly with od so this works
# even if `file` is not in the build container. aarch64 == 0x00B7 (LE).
E_MACHINE="$(od -An -tx1 -j18 -N2 /work/wpa/wpa_supplicant | tr -d ' ')"
if [ "${E_MACHINE}" != "b700" ]; then
    echo "FATAL: /work/wpa/wpa_supplicant is not an aarch64 ELF (e_machine=${E_MACHINE}, want b700)" >&2
    exit 1
fi
install -m 0755 /work/wpa/wpa_supplicant "${ROOTFS}/sbin/wpa_supplicant"
# Provenance marker (pinned-ref stamp travels with the wpa stage output).
if [ -f /work/wpa/.pf-wpa-provenance ]; then
    install -D -m 0644 /work/wpa/.pf-wpa-provenance "${ROOTFS}/usr/share/pocketforge/wpa-provenance"
fi
echo "[customize] owned wpa_supplicant installed at /sbin/wpa_supplicant (aarch64 ELF verified)"

# --- Config files ------------------------------------------------------------
echo "[customize] Writing config files..."

# /etc/asound.conf — verbatim from stock (hardware-firmware-probes.md §12)
cat > "${ROOTFS}/etc/asound.conf" << 'ASOUND_EOF'
# A133
# audiocodec
# ac107

ctl.!default {
    type hw
    card audiocodec
}

pcm.!default {
    type asym
    playback.pcm "Playback"
    capture.pcm "CaptureAc107"
}

pcm.Playback {
    type plug
    slave.pcm {
        type softvol
        slave.pcm PlaybackDmix
        control {
            name "Soft Volume Master"
            card audiocodec
        }
        min_dB -51.0
        max_dB 0.0
        resolution 256
    }
}

pcm.PlaybackDmix {
    type plug
    slave.pcm {
        type dmix
        ipc_key 1111
        ipc_perm 0666
        slave {
            pcm "hw:audiocodec,0"
            format S16_LE
            rate 48000
            period_size 1024
            periods 4
        }
    }
}

pcm.Capture {
    type hw
    card audiocodec
}

pcm.CaptureAc107 {
    type hw
    card sndac10710036
}

pcm.CaptureDsnoop {
    type plug
    slave.pcm {
        type dsnoop
        ipc_key 1111
        ipc_perm 0666
        slave {
            pcm "hw:sndac10710036"
            format S16_LE
            rate 16000
            period_size 1024
            periods 4
        }
    }
}

pcm.PlaybackHpoutSpeaker {
    type hooks
    slave.pcm "PlaybackDmix"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "HpSpeaker Switch"
                optional true
                value 1
            }
        ]
    }
}

pcm.PlaybackLineoutSpeaker {
    type hooks
    slave.pcm "PlaybackDmix"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "LINEOUT Output Select"
                optional true
                value 1
            }
            {
                name "LINEOUT Switch"
                optional true
                value 1
            }
            {
                name "LINEOUT volume"
                optional true
                value 20
            }
        ]
    }
}

pcm.CaptureMic {
    type hooks
    slave.pcm "CaptureAc107"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "Channel 1 PGA Gain"
                optional true
                value 20
            }
            {
                name "Channel 2 PGA Gain"
                optional true
                value 20
            }
        ]
    }
}

pcm.CaptureReference {
    type hooks
    slave.pcm "Capture"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "ADCL Input MIC1 Boost Switch"
                optional true
                value 1
            }
            {
                name "ADCR Input MIC2 Boost Switch"
                optional true
                value 1
            }
            {
                name "MIC1 gain volume"
                optional true
                value 0
            }
            {
                name "MIC2 gain volume"
                optional true
                value 0
            }
        ]
    }
}

pcm.CaptureAec {
    type plug
    slave.pcm {
        type multi
        slaves {
            a { pcm "CaptureMic" channels 2 }
            b { pcm "CaptureReference" channels 2 }
        }
        bindings {
            0 { slave a channel 0 }
            1 { slave a channel 1 }
            2 { slave b channel 0 }
            3 { slave b channel 1 }
        }
    }
    ttable.0.0 1
    ttable.1.1 1
    ttable.2.2 1
    ttable.3.3 1
}
ASOUND_EOF

# /etc/pocketforge/display-env.sh — central display/env (build-int §12.4)
install -d "${ROOTFS}/etc/pocketforge"
cat > "${ROOTFS}/etc/pocketforge/display-env.sh" << 'DISPLAY_ENV_EOF'
# /etc/pocketforge/display-env.sh — central display/env for PocketForge apps
# Sourced by every app's launch script; owned by device-config.
export SDL3_DYNAMIC_API=/opt/pocketforge/lib/libSDL3-pocketforge.so.0
export LD_LIBRARY_PATH=/usr/lib/pvr-rogue${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
DISPLAY_ENV_EOF
chmod 0644 "${ROOTFS}/etc/pocketforge/display-env.sh"

# udev rules (build-int §12.3)
install -d "${ROOTFS}/etc/udev/rules.d"

cat > "${ROOTFS}/etc/udev/rules.d/60-pocketforge-dri.rules" << 'UDEV_DRI_EOF'
# GPU nodes for the kiosk user.
KERNEL=="card0",      SUBSYSTEM=="drm", MODE="0660", GROUP="video"
KERNEL=="renderD128", SUBSYSTEM=="drm", MODE="0660", GROUP="render"
UDEV_DRI_EOF

cat > "${ROOTFS}/etc/udev/rules.d/61-pocketforge-input.rules" << 'UDEV_INPUT_EOF'
# Input nodes (stock has these root-only).
SUBSYSTEM=="input", KERNEL=="event[0-9]*", MODE="0660", GROUP="input"
KERNEL=="js[0-9]*",                        MODE="0660", GROUP="input"
UDEV_INPUT_EOF

# --- WiFi + networking (bd: tsp-iuz.2.2) -------------------------------------
echo "[customize] Installing WiFi + networking configuration..."

# WiFi templater script (reads /boot/wifi.txt -> wpa_supplicant conf)
install -d "${ROOTFS}/usr/lib/pocketforge"
install -m 0755 "/work/src/rootfs-overlay/usr/lib/pocketforge/wifi-setup.sh" \
    "${ROOTFS}/usr/lib/pocketforge/wifi-setup.sh"

# WiFi power-save policy script (reads optional POWER_SAVE from /boot/wifi.txt;
# default off — xradio flap mitigation). bd: tsp-cv7.4.12.
install -m 0755 "/work/src/rootfs-overlay/usr/lib/pocketforge/wifi-powersave.sh" \
    "${ROOTFS}/usr/lib/pocketforge/wifi-powersave.sh"

# WiFi self-heal watchdog script (restarts wpa_supplicant@wlan0 when the
# xr819/xr829 drops its DHCP lease). bd: tsp-h1o.
install -m 0755 "/work/src/rootfs-overlay/usr/lib/pocketforge/wifi-watchdog.sh" \
    "${ROOTFS}/usr/lib/pocketforge/wifi-watchdog.sh"

# WiFi templater systemd service (runs before wpa_supplicant@wlan0)
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-wifi-setup.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-wifi-setup.service"

# WiFi power-save disable service (xradio deauth/reassoc flap mitigation).
# bd: tsp-cv7.4.12 — needs `iw` (added to rootfs-packages.txt).
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-wifi-powersave.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-wifi-powersave.service"

# WiFi self-heal watchdog service (restart wpa_supplicant on lost lease).
# bd: tsp-h1o — uses ip/ping (iproute2/busybox) + systemctl, already present.
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-wifi-watchdog.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-wifi-watchdog.service"

# Network latency-under-load sysctls (fq_codel default qdisc + TCP buffer caps
# sized for the lossy ~30 Mbit/s XR829 link). Applied by systemd-sysctl.service
# (static, sysinit.target — ships with the systemd package; no procps needed).
# bd: tsp-myp1.8.2 (epic tsp-myp1.8 — Steam Link latency).
install -d "${ROOTFS}/etc/sysctl.d"
install -m 0644 "/work/src/rootfs-overlay/etc/sysctl.d/10-pocketforge-net-latency.conf" \
    "${ROOTFS}/etc/sysctl.d/10-pocketforge-net-latency.conf"

# Module autoload for the WiFi driver triplet.
# Owned substrate: xr829_mac -> xr829_core -> xr829_wlan
# (xr829_core/xr829_wlan have alias=xradio_* so modprobe can resolve either,
#  but xr829_mac has NO alias, so we must use the correct file-based name.)
install -d "${ROOTFS}/etc/modules-load.d"
cat > "${ROOTFS}/etc/modules-load.d/pocketforge-wifi.conf" << 'WIFI_MODULES_EOF'
# WiFi driver triplet for the XR829 (TrimUI Smart Pro, owned substrate).
# Load order: mac -> core -> wlan (dependency chain).
# cfg80211 + mac80211 are built into the 4.9.191 kernel (not modular).
# bd: tsp-cv7.4.2
xr829_mac
xr829_core
xr829_wlan
WIFI_MODULES_EOF

# XR829 WiFi MAC address persistence directory.
# The xr829 driver reads/writes /etc/wifi/xr_wifi.conf to persist the MAC
# address across reboots. Without this directory, the driver logs
# "Access_file failed" and generates a random MAC on every boot.
install -d -m 0755 "${ROOTFS}/etc/wifi"

# systemd-networkd DHCP configuration for wlan0
install -d "${ROOTFS}/etc/systemd/network"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/network/20-wlan0.network" \
    "${ROOTFS}/etc/systemd/network/20-wlan0.network"

# /etc/fstab: mount the boot-resource FAT partition read-only at /boot.
# The kernel + initrd live inside boot.img (raw partition), not on /boot —
# /boot is free to serve as the user-editable config mount point (Raspberry
# Pi precedent). Read-only prevents accidental writes to the FAT partition.
# nofail: don't block boot if the partition is slow to appear or missing.
# x-systemd.device-timeout=10s: give udev 10s to enumerate the device node
# (default 90s would hit the 16s watchdog timeout).
cat >> "${ROOTFS}/etc/fstab" << 'FSTAB_EOF'
# Boot-resource FAT partition (user-editable WiFi config, boot logs)
LABEL=POCKETFORGE  /boot  vfat  ro,noatime,nofail,x-systemd.device-timeout=10s,fmask=0133,dmask=0022  0  0
FSTAB_EOF

# Hostname
echo "pocketforge" > "${ROOTFS}/etc/hostname"

# /etc/hosts — required for sudo and local name resolution
cat > "${ROOTFS}/etc/hosts" << 'HOSTS_EOF'
127.0.0.1	localhost
127.0.1.1	pocketforge
::1		localhost ip6-localhost ip6-loopback
HOSTS_EOF

# Enable services via symlinks (systemctl enable doesn't work under qemu
# in all chroot configurations — create the symlinks directly).
install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"

# wpa_supplicant@wlan0.service (template instance).
#
# bd tsp-mc9m.14.8: pull the supplicant in via the wlan0 DEVICE unit's .wants/
# directory (the canonical systemd device-Wants-service "hotplug" pattern),
# NOT multi-user.target.wants/. Why: the stock template
# /lib/systemd/system/wpa_supplicant@.service has
#   Requires=sys-subsystem-net-devices-%i.device
#   After=sys-subsystem-net-devices-%i.device
# When enabled under multi-user.target.wants/, an ABSENT wlan0 (a driver-less
# mainline A133 kernel with no xradio/xr819 module) pulls that .device unit
# into the boot transaction as a start job, which times out at
# DefaultDeviceTimeoutSec (~90s, = DefaultTimeoutStartSec) and — because it is
# a hard Requires — stalls multi-user.target the full ~90s (login at ~93s).
# That idle window is also what triggers the mainline PMIC cldo3 SD-resume
# wedge (tsp-mc9m.13.3). Gating on the device's .wants/ instead makes this
# INERT when wlan0 is present (4.9 product kernel + mainline builds that DO
# carry the driver, e.g. tsp-mc9m.14.4: the .device activates from udev the
# instant wlan0 appears, pulls the supplicant, ordered correctly After the
# now-active device — no race, associates exactly as before) and NON-BLOCKING
# when wlan0 is absent (the .device never activates, so nothing pulls the
# supplicant into the boot transaction — zero 90s stall). Nothing else
# hard-Requires wpa_supplicant@wlan0 (powersave/watchdog only order After= it),
# so no other unit re-introduces the stall. The tsp-8ba conf-condition drop-in
# below is orthogonal and unchanged (skips the supplicant cleanly when WiFi is
# unconfigured).
install -d "${ROOTFS}/etc/systemd/system/sys-subsystem-net-devices-wlan0.device.wants"
ln -sf /lib/systemd/system/wpa_supplicant@.service \
    "${ROOTFS}/etc/systemd/system/sys-subsystem-net-devices-wlan0.device.wants/wpa_supplicant@wlan0.service"

# bd tsp-8ba: drop-in so an unconfigured-WiFi image SKIPS wpa_supplicant@wlan0
# (ConditionPathExists on the generated conf) instead of failing it every boot.
install -d "${ROOTFS}/etc/systemd/system/wpa_supplicant@wlan0.service.d"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/wpa_supplicant@wlan0.service.d/pocketforge-unconfigured-skip.conf" \
    "${ROOTFS}/etc/systemd/system/wpa_supplicant@wlan0.service.d/pocketforge-unconfigured-skip.conf"

# Mask the global wpa_supplicant.service — we use the template instance
# wpa_supplicant@wlan0.service instead. The global one fails without a
# config file and causes systemd to report "degraded" status.
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/wpa_supplicant.service"
echo "[customize] Masked global wpa_supplicant.service (template instance used instead)"

# --- pf-input-decode: the A133 gamepad-MCU decoder daemon (tsp-e1b.11) --------
# The runtime Dockerfile.pf stage cross-built a static aarch64 pf-input-decode and
# staged it + its systemd unit under ${RUNTIME_DIR} (for a133; other devices get
# only a NOT-SHIPPED marker there). Install into BOTH VARIANTS (dev + release): the
# decoder is a FUNCTIONAL component — the pad exposes NO evdev gamepad without it —
# not a diagnostic like i2c-tools or the SDL testbin. Install to /usr/bin (matches
# the unit's ExecStart) + enable via a multi-user.target.wants symlink (the same
# "systemctl enable doesn't work under qemu" pattern used for wpa above), so it
# comes up on a COLD boot with no manual setup and survives every reflash — the
# exact regression tsp-bwrg.6 hit when a reflash wiped the hand-deployed /opt binary.
# The runtime stage's a133 gate keys on the SAME PF_GPU_REPO=gpu-km-tsp that selects
# this rootfs path, so when this script runs the binary is structurally present; a
# NOT-SHIPPED marker here would mean a non-a133 caller reusing this SoC-agnostic
# script, which is skipped cleanly (a523 gets its own decoder + install wiring in
# build-rootfs-a523.sh — a separate future bead, not this one).
RUNTIME_BIN="${RUNTIME_DIR}/bin/pf-input-decode"
RUNTIME_UNIT="${RUNTIME_DIR}/systemd/pf-input-decode.service"
if [ -f "${RUNTIME_BIN}" ]; then
    [ -f "${RUNTIME_UNIT}" ] || { echo "FATAL: pf-input-decode binary present but its unit is missing at ${RUNTIME_UNIT}" >&2; exit 1; }
    # Belt-and-suspenders aarch64 re-check (mirrors the wpa install gate).
    RD_EM="$(od -An -tx1 -j18 -N2 "${RUNTIME_BIN}" | tr -d ' ')"
    [ "${RD_EM}" = "b700" ] || { echo "FATAL: ${RUNTIME_BIN} is not an aarch64 ELF (e_machine=${RD_EM}, want b700)" >&2; exit 1; }
    install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
    install -D -m 0755 "${RUNTIME_BIN}"  "${ROOTFS}/usr/bin/pf-input-decode"
    install -D -m 0644 "${RUNTIME_UNIT}" "${ROOTFS}/etc/systemd/system/pf-input-decode.service"
    ln -sf /etc/systemd/system/pf-input-decode.service \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-input-decode.service"
    [ -f "${RUNTIME_DIR}/.pf-runtime-provenance" ] && \
        install -D -m 0644 "${RUNTIME_DIR}/.pf-runtime-provenance" "${ROOTFS}/usr/share/pocketforge/runtime-provenance"
    echo "[customize] pf-input-decode installed at /usr/bin/pf-input-decode + enabled (multi-user.target.wants/)"
else
    echo "[customize] runtime NOT-SHIPPED for this device (no ${RUNTIME_BIN}) — skipping pf-input-decode install"
fi

# --- F13 shell owner + independent F07 session authority (tsp-op5a.78) -------
SHELL_BIN="${LAUNCHER_DIR}/bin/pf-shell"
AUTHORITY_BIN="${RUNTIME_DIR}/bin/pf-session-authorityd"
if [ -f "${SHELL_BIN}" ] || [ -f "${AUTHORITY_BIN}" ]; then
    [ -f "${SHELL_BIN}" ] || { echo "FATAL: pf-session-authorityd staged without pf-shell" >&2; exit 1; }
    [ -f "${AUTHORITY_BIN}" ] || { echo "FATAL: pf-shell staged without pf-session-authorityd" >&2; exit 1; }
    for binary in "${SHELL_BIN}" "${AUTHORITY_BIN}"; do
        binary_em="$(od -An -tx1 -j18 -N2 "${binary}" | tr -d ' ')"
        [ "${binary_em}" = "b700" ] || { echo "FATAL: ${binary} is not an aarch64 ELF (e_machine=${binary_em}, want b700)" >&2; exit 1; }
    done
    install -D -m 0755 "${SHELL_BIN}" "${ROOTFS}/usr/bin/pf-shell"
    install -D -m 0755 "${AUTHORITY_BIN}" "${ROOTFS}/usr/bin/pf-session-authorityd"
    for unit in pf-session-authorityd.service pf-foreground@.service pf-shell-selected.service; do
        install -D -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/${unit}" \
            "${ROOTFS}/etc/systemd/system/${unit}"
    done
    install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/pf-session-authorityd.service \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-session-authorityd.service"
    ln -sf /etc/systemd/system/pf-shell-selected.service \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-shell-selected.service"
    [ -f "${LAUNCHER_DIR}/.pf-launcher-provenance" ] && \
        install -D -m 0644 "${LAUNCHER_DIR}/.pf-launcher-provenance" "${ROOTFS}/usr/share/pocketforge/launcher-provenance"
    echo "[customize] F13 pf-shell selected owner + independent pf-session-authorityd installed and enabled"
fi

# --- W2c preference state authority (tsp-op5a.134) --------------------------
PREFSD_BIN="${RUNTIME_DIR}/bin/pf-prefsd"
if [ -f "${PREFSD_BIN}" ]; then
    prefsd_em="$(od -An -tx1 -j18 -N2 "${PREFSD_BIN}" | tr -d ' ')"
    [ "${prefsd_em}" = "b700" ] || { echo "FATAL: ${PREFSD_BIN} is not an aarch64 ELF (e_machine=${prefsd_em}, want b700)" >&2; exit 1; }
    install -D -m 0755 "${PREFSD_BIN}" "${ROOTFS}/usr/bin/pf-prefsd"
    install -D -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pf-prefsd.service" \
        "${ROOTFS}/etc/systemd/system/pf-prefsd.service"
    install -D -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pf-broker.service.d/10-prefsd.conf" \
        "${ROOTFS}/etc/systemd/system/pf-broker.service.d/10-prefsd.conf"
    touch "${ROOTFS}/etc/environment"
    grep -qxF 'PF_PREFSD_SOCK=/run/pocketforge/prefsd.sock' "${ROOTFS}/etc/environment" || \
        cat "/work/src/rootfs-overlay/etc/environment" >> "${ROOTFS}/etc/environment"
    install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/pf-prefsd.service \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-prefsd.service"
    echo "[customize] pf-prefsd installed and enabled as the preference state authority"
fi

# pocketforge-wifi-setup.service
ln -sf /etc/systemd/system/pocketforge-wifi-setup.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pocketforge-wifi-setup.service"

# pocketforge-boot-animator (bd tsp-3rd3.4: kernel-handoff fb0 boot animator).
# Supersedes pocketforge-fb-clear — the animator owns fb0 from kernel-fb0
# registration and unbinds fbcon itself, so a separate "zero fb0 to hide
# console noise" service is no longer needed. Kept: the udev rule that tags
# fb0 as dev-fb0.device (unit ordering depends on it).
install -m 0644 "/work/src/rootfs-overlay/etc/udev/rules.d/71-pocketforge-fb.rules" \
    "${ROOTFS}/etc/udev/rules.d/71-pocketforge-fb.rules"

# pocketforge-boot-animator (bd tsp-3rd3.4). The binary is cross-compiled
# BEFORE mmdebstrap in the outer script and exported via PF_ANIMATOR_BIN;
# see "Cross-compile the boot animator" below. stb_image.h is vendored
# (public domain, single header) so only libc/libm are linked.
ANIMATOR_SRC="/work/src/apps/pocketforge-boot-animator"
install -d "${ROOTFS}/opt/pocketforge/bin"
install -m 0755 "${PF_ANIMATOR_BIN}" "${ROOTFS}/opt/pocketforge/bin/pocketforge-boot-animator"
echo "[customize] Animator installed: $(du -h "${PF_ANIMATOR_BIN}" | awk '{print $1}') stripped"

# Frame assets (48× 1280×720 RGBA PNG, ~5.5 MiB). Frame 000 is byte-identical
# to the u-boot static logo (sha ed689555…) so the u-boot → animator handoff
# is seamless by construction.
echo "[customize] Installing boot animation frame set..."
install -d "${ROOTFS}/opt/pocketforge/boot-anim/frames"
install -m 0644 "${ANIMATOR_SRC}/frames/"frame-*.png \
    "${ROOTFS}/opt/pocketforge/boot-anim/frames/"
# Provenance stamp: pin frame-000's sha so a rootfs drift on the u-boot handoff
# frame is caught by grep-in-image tests.
sha256sum "${ROOTFS}/opt/pocketforge/boot-anim/frames/frame-000.png" \
    | awk '{print "frame-000.png sha256=" $1}' \
    > "${ROOTFS}/opt/pocketforge/boot-anim/PROVENANCE"

# Systemd unit + handoff target. NO default-handoff oneshot: it was in the
# first cut of this bead and shipped SIGTERM'ing the animator ~1.7s in
# (multi-user.target reached fast; the +500ms oneshot then activated
# splash-handoff.target -> Conflicts= killed the animator before it even
# finished the intro). Real evidence on the v5 combined image (rootfs
# 3200a999) confirmed: animator started clean, drew, was killed at
# Duration=1.687s. Fix (2026-07-14): DELETE the default-handoff; with no
# MainUI in this image, the animator LOOPS FOREVER until a real UI ships
# and activates pocketforge-splash-handoff.target itself. That is the
# correct "no MainUI yet" behavior — the splash IS the state until a
# successor exists.
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-boot-animator.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-boot-animator.service"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-splash-handoff.target" \
    "${ROOTFS}/etc/systemd/system/pocketforge-splash-handoff.target"

# pocketforge-foreground.target — the app-agnostic foreground-app slot
# (tsp-ikk0.11): display apps join it (Requires=/After=), the animator's
# Conflicts=/Before= stops it BEFORE the app starts (single fb0 writer —
# kills the splash/app pan-fight the owner reported as "z-fighting",
# tsp-7kpp), and the target's StopWhenUnneeded+OnSuccess restore the
# animator when the last app exits.
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target" \
    "${ROOTFS}/etc/systemd/system/pocketforge-foreground.target"

# pf-take-panel — the sanctioned manual/test launch path for display apps:
# runs the command as a transient unit joined to pocketforge-foreground.target
# (see above). Unit-file apps join the target directly and don't need it.
install -m 0755 "/work/src/rootfs-overlay/usr/bin/pf-take-panel" \
    "${ROOTFS}/usr/bin/pf-take-panel"
install -d "${ROOTFS}/etc/systemd/system/basic.target.wants"
ln -sf /etc/systemd/system/pocketforge-boot-animator.service \
    "${ROOTFS}/etc/systemd/system/basic.target.wants/pocketforge-boot-animator.service"

# Diagnostic-only ODYSSEY region capture. The build arg also compiles the
# capture instrumentation into pvrsrvkm; keep the trigger absent from normal
# images and start it from the animator's early, display-ready boot seam.
if [ "${PF_ODYSSEY_CAPTURE:-}" = "1" ]; then
    install -m 0755 "/work/src/rootfs-overlay/usr/lib/pocketforge/odyssey-capture.sh" \
        "${ROOTFS}/usr/lib/pocketforge/odyssey-capture.sh"
    install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pf-odyssey-capture.service" \
        "${ROOTFS}/etc/systemd/system/pf-odyssey-capture.service"
    ln -sf /etc/systemd/system/pf-odyssey-capture.service \
        "${ROOTFS}/etc/systemd/system/basic.target.wants/pf-odyssey-capture.service"
    echo "[customize] ODYSSEY boot capture trigger installed + enabled"
fi

# pocketforge-placeholder (bd tsp-147u.21) — THROWAWAY static post-boot screen.
# bd tsp-ga7s.1: SUPERSEDED by pocketforge-menu (installed below). The binary
# and unit stay installed for one-symlink-swap recovery, but the enable symlink
# under multi-user.target.wants/ is now on pocketforge-menu.service, NOT this.
install -m 0755 "${PF_PLACEHOLDER_BIN}" "${ROOTFS}/opt/pocketforge/bin/pocketforge-placeholder"
echo "[customize] Placeholder installed (unenabled — menu supersedes): $(du -h "${PF_PLACEHOLDER_BIN}" | awk '{print $1}') stripped"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-placeholder.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-placeholder.service"

# pocketforge-menu (bd tsp-ga7s.1) — MVP 3-entry static launcher, LRADC-nav.
# Supersedes pocketforge-placeholder at boot via the enable-symlink swap: this
# unit declares Conflicts=/After= on both the boot animator AND the placeholder
# on ITSELF (the reliable direction per tsp-ikk0.11), so starting it cleanly
# stops the animator/placeholder and takes over fb0 — one fb0 writer.
# The binary and unit are installed here; ENABLING it is done by the panel-owner
# selection block below, which also picks the matching foreground-slot restore
# drop-in (bd tsp-1cl7.1 — the two must not drift apart again).
install -m 0755 "${PF_MENU_BIN}" "${ROOTFS}/opt/pocketforge/bin/pocketforge-menu"
echo "[customize] Menu installed: $(du -h "${PF_MENU_BIN}" | awk '{print $1}') stripped"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-menu.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-menu.service"

# product-010 F16: recovery is an independently triggered entry, not a panel
# owner and not part of the launcher restore seam.  The path unit consumes the
# durable RecoveryRequired condition even when it appears after boot.
install -m 0755 "${PF_RECOVERY_BIN}" \
    "${ROOTFS}/opt/pocketforge/bin/pocketforge-recovery-entry"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-recovery.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-recovery.service"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-recovery.path" \
    "${ROOTFS}/etc/systemd/system/pocketforge-recovery.path"
ln -sf /etc/systemd/system/pocketforge-recovery.path \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pocketforge-recovery.path"
echo "[customize] Recovery entry installed + condition path enabled (recovery@${PF_RECOVERY_SHA})"
# ---- Panel owner selection (bd tsp-1cl7.1) ---------------------------------
# WHICH UI OWNS THE PANEL IS ONE DECISION WITH TWO CONSEQUENCES, so it is made
# ONCE here and both consequences are derived from it:
#   1. the multi-user.target.wants enable symlink (which UI starts at boot), and
#   2. which pocketforge-foreground.target.d/10-owner-*.conf is installed —
#      the drop-in that adds that UI to the slot's Conflicts=/After= (so an app
#      taking the panel stops it; target-side is REQUIRED for the systemd-run /
#      pf-take-panel dependency-pull path) and supplies the OnSuccess= that
#      restores it when the app exits.
# They were previously two independent edits, which is how the old target came
# to restore the boot animator over whatever UI was actually enabled.
#
# The target itself carries NO OnSuccess=. Each drop-in ADDS to an empty list;
# it is a SELECTION, not an override, because dependency-type settings ignore an
# empty assignment and would silently MERGE (see 10-owner-menu.conf). Installing
# no drop-in at all is therefore NOT a safe fall-through — the slot would have
# no restore and the panel would keep whatever the exited app left, which reads
# as a display fault. Hence the hard failure on an unknown owner below: add a
# new UI variant here and to rootfs-overlay/.../pocketforge-foreground.target.d/
# together, or the build stops.
#
# To swap the UI (the documented one-symlink-swap recovery), change THIS LINE
# ONLY — do not hand-edit the symlink or the drop-in install.
PF_PANEL_OWNER="shell"

case "${PF_PANEL_OWNER}" in
    shell)       PF_PANEL_OWNER_UNIT="pf-shell-selected.service" ;;
    menu)        PF_PANEL_OWNER_UNIT="pocketforge-menu.service" ;;
    placeholder) PF_PANEL_OWNER_UNIT="pocketforge-placeholder.service" ;;
    # The animator is already enabled at basic.target above, so it takes no
    # multi-user.target.wants symlink — only the drop-in.
    animator)    PF_PANEL_OWNER_UNIT="" ;;
    *)
        echo "[customize] ERROR: unknown PF_PANEL_OWNER='${PF_PANEL_OWNER}'." >&2
        echo "[customize]        Every UI variant needs a matching" >&2
        echo "[customize]        pocketforge-foreground.target.d/10-owner-<owner>.conf" >&2
        echo "[customize]        or the foreground slot has no restore (bd tsp-1cl7.1)." >&2
        exit 1
        ;;
esac

PF_PANEL_OWNER_DROPIN="/work/src/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-${PF_PANEL_OWNER}.conf"
if [ ! -f "${PF_PANEL_OWNER_DROPIN}" ]; then
    echo "[customize] ERROR: missing ${PF_PANEL_OWNER_DROPIN} for PF_PANEL_OWNER='${PF_PANEL_OWNER}'" >&2
    exit 1
fi

if [ -n "${PF_PANEL_OWNER_UNIT}" ]; then
    ln -sf "/etc/systemd/system/${PF_PANEL_OWNER_UNIT}" \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/${PF_PANEL_OWNER_UNIT}"
fi
install -d "${ROOTFS}/etc/systemd/system/pocketforge-foreground.target.d"
install -m 0644 "${PF_PANEL_OWNER_DROPIN}" \
    "${ROOTFS}/etc/systemd/system/pocketforge-foreground.target.d/10-owner-${PF_PANEL_OWNER}.conf"
echo "[customize] Panel owner: ${PF_PANEL_OWNER} (enabled unit: ${PF_PANEL_OWNER_UNIT:-<none, animator at basic.target>}; restore drop-in: 10-owner-${PF_PANEL_OWNER}.conf)"

# pocketforge-wifi-powersave.service (disable xradio power-save → stop flap)
# bd tsp-mc9m.14.8: like wpa_supplicant@wlan0 above, pull this in via the wlan0
# .device unit's .wants/ (device-Wants-service hotplug), NOT multi-user.target.
# It has After=sys-subsystem-net-devices-wlan0.device — so even though it uses a
# SOFT Wants= (not Requires=), that Wants= still enqueues a start job for the
# absent wlan0.device and the After= waits for it, timing out at
# DefaultDeviceTimeoutSec (~90s); under multi-user.target.wants/ that delays
# boot-to-login the full ~90s on a driver-less mainline kernel (soft-vs-hard
# only changes failure propagation, not the enqueue/ordering wait; the
# ConditionPathExists is evaluated only AFTER that wait, so it does not save it).
# Pulled by the device instead → never enters the boot transaction when wlan0 is
# absent (no stall); when wlan0 appears the device pulls it, ordered After the
# device + wpa_supplicant exactly as before (inert on the present path).
ln -sf /etc/systemd/system/pocketforge-wifi-powersave.service \
    "${ROOTFS}/etc/systemd/system/sys-subsystem-net-devices-wlan0.device.wants/pocketforge-wifi-powersave.service"

# pocketforge-wifi-watchdog.service (self-heal wlan0 on lost lease — tsp-h1o)
# bd tsp-mc9m.14.8: same as powersave above — device-Wants-service via the wlan0
# .device .wants/ so its After=sys-subsystem-net-devices-wlan0.device does not
# stall boot ~90s on absent wlan0.
ln -sf /etc/systemd/system/pocketforge-wifi-watchdog.service \
    "${ROOTFS}/etc/systemd/system/sys-subsystem-net-devices-wlan0.device.wants/pocketforge-wifi-watchdog.service"

# systemd-networkd (DHCP for wlan0)
ln -sf /lib/systemd/system/systemd-networkd.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
# networkd needs its socket too
install -d "${ROOTFS}/etc/systemd/system/sockets.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.socket \
    "${ROOTFS}/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"

# systemd-timesyncd (NTP — prevents TLS certificate drift)
ln -sf /lib/systemd/system/systemd-timesyncd.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/systemd-timesyncd.service"
# timesyncd also needs sysinit.target.wants for earliest possible start
install -d "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
ln -sf /lib/systemd/system/systemd-timesyncd.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"
# Seed the clock floor for first boot after a full-image flash. The extracted
# rootfs timestamp clamp below sets the empty clock file's mtime to the build epoch.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
    /work/src/scripts/seed-build-clock.sh "${ROOTFS}"

# DNS: systemd-resolved consumes the per-link DNS servers learned by networkd's
# DHCP client. Point libc at resolved's managed stub and enable the daemon
# explicitly (systemctl enable is unreliable under the cross-arch chroot).
install -d "${ROOTFS}/etc/systemd/resolved.conf.d"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/resolved.conf.d/pocketforge.conf" \
    "${ROOTFS}/etc/systemd/resolved.conf.d/pocketforge.conf"
ln -sfn ../run/systemd/resolve/stub-resolv.conf "${ROOTFS}/etc/resolv.conf"
ln -sf /lib/systemd/system/systemd-resolved.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/systemd-resolved.service"

echo "[customize] WiFi + networking: all config installed"

# --- Watchdog (bd: tsp-iuz.2.3) ----------------------------------------------
# The vendor kernel auto-starts sunxi-wdt at driver probe with a 16s timeout.
# Tell systemd PID 1 to take ownership and ping at half the interval (8s).
echo "[customize] Installing watchdog drop-in..."
install -d "${ROOTFS}/etc/systemd/system.conf.d"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system.conf.d/watchdog.conf" \
    "${ROOTFS}/etc/systemd/system.conf.d/watchdog.conf"
echo "[customize] Watchdog: systemd drop-in installed"

# --- Build-id marker (resolved-input provenance; bd tsp-mc9m.41.513.1) --------
# Hash a canonical list of platform.lock-resolved inputs. No clock, host, random
# value, or build counter participates, so identical inputs remain byte-identical.
echo "[customize] Generating build-id marker..."
"${SRC_DIR}/scripts/generate-build-id.sh" > "${ROOTFS}/etc/pocketforge-build-id"
chmod 0644 "${ROOTFS}/etc/pocketforge-build-id"

# --- Directory scaffolding ---------------------------------------------------
echo "[customize] Creating directory scaffolding..."
install -d "${ROOTFS}/etc/pocketforge/keys/release.d"
install -d "${ROOTFS}/opt/pocketforge/apps"
install -d "${ROOTFS}/var/lib/pocketforge/apps"

# --- Boot-time entropy + random-seed -----------------------------------------
# systemd-random-seed.service blocks boot on first boot (no saved seed, and
# getrandom() blocks until the entropy pool is initialized). haveged provides
# entropy from CPU timing jitter, but it starts too late to unblock the seed
# service on a first boot. Mask the service — haveged fills the pool instead.
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/systemd-random-seed.service"
echo "[customize] Masked systemd-random-seed.service (haveged provides entropy)"

# --- Variant-conditional steps -----------------------------------------------
VARIANT="${POCKETFORGE_VARIANT:-dev}"
echo "[customize] Applying variant-specific config (variant=${VARIANT})..."

## -- Journald + coredump config (bd: tsp-iuz.2.8) ---
# Both variants get a journald drop-in; the file differs per variant.
install -d "${ROOTFS}/etc/systemd/journald.conf.d"
if [ "${VARIANT}" = "dev" ]; then
    # Dev: persistent journald (logs survive reboots for bug-report capture)
    install -m 0644 "/work/src/rootfs-overlay/etc/systemd/journald.conf.d/pocketforge-dev.conf" \
        "${ROOTFS}/etc/systemd/journald.conf.d/pocketforge.conf"
    echo "[customize] dev: journald Storage=persistent, SystemMaxUse=50M"

    # Dev: ensure /var/log/journal/ exists (systemd creates it on first boot
    # when Storage=persistent, but pre-creating it avoids a race with early
    # journal writes and lets us set group ownership at build time).
    install -d -m 2755 "${ROOTFS}/var/log/journal"
    echo "[customize] dev: /var/log/journal/ pre-created"

    # Dev: loosen /var/log/ permissions so gamer can read logs without sudo.
    # The default Debian mode is 0755/root:root which already allows read;
    # add group=adm explicitly and make gamer a member, matching the Debian
    # convention for log readers.
    chown root:adm "${ROOTFS}/var/log"
    chmod 0775 "${ROOTFS}/var/log"
    chroot "${ROOTFS}" usermod -a -G adm gamer
    echo "[customize] dev: /var/log/ group-readable (gamer added to adm group)"
else
    # Release: volatile journald (tmpfs only; defends against log-bomb DoS)
    install -m 0644 "/work/src/rootfs-overlay/etc/systemd/journald.conf.d/pocketforge-release.conf" \
        "${ROOTFS}/etc/systemd/journald.conf.d/pocketforge.conf"
    echo "[customize] release: journald Storage=volatile, RuntimeMaxUse=16M"
fi

if [ "${VARIANT}" = "dev" ]; then
    # Dev: passwordless sudo for gamer (make deploy writes root-owned paths)
    install -d "${ROOTFS}/etc/sudoers.d"
    printf 'gamer ALL=(ALL:ALL) NOPASSWD: ALL\n' > "${ROOTFS}/etc/sudoers.d/pocketforge-dev"
    chmod 0440 "${ROOTFS}/etc/sudoers.d/pocketforge-dev"
    echo "[customize] dev: sudoers drop-in installed"

    # Dev: serial-console debug user for bring-up diagnostics.
    # This user has a known password and can sudo to gamer or root.
    # MUST BE REMOVED BEFORE RELEASE — tracked by bead tsp-iuz.2.9.
    # The password is public and dev-only.  Keep its SHA-512 crypt salt fixed so
    # identical source trees produce identical /etc/shadow files.
    DEBUG_PASSWORD_HASH='$6$pocketforge-dev$PzW7bErMVz/y88oe/83Za8xc2dmxPJR8fNryu7.pZeqeoQ7BpQqbxbL2wsZwc8fbf29aAeQJUtTx7XoOzwv36.'
    chroot "$ROOTFS" useradd -m -d /home/debug -s /bin/bash \
        -p "${DEBUG_PASSWORD_HASH}" debug
    # video/render/input so diagnostics (testgles2, cube-fps.sh, pf-hwprobe) can
    # open /dev/fb0 + DRM/input nodes without sudo — same hw-access groups the
    # udev rules above gate on, mirroring gamer (bd tsp-ikk0.3).
    chroot "$ROOTFS" usermod -aG video,render,input debug
    printf 'debug ALL=(ALL:ALL) NOPASSWD: ALL\n' >> "${ROOTFS}/etc/sudoers.d/pocketforge-dev"
    echo "[customize] dev: debug user created (password: pocketforge) — serial console access"

    # Dev: sshd hardening (PermitRootLogin no, PasswordAuthentication no)
    install -d "${ROOTFS}/etc/ssh/sshd_config.d"
    install -m 0644 "/work/src/rootfs-overlay/etc/ssh/sshd_config.d/pocketforge.conf" \
        "${ROOTFS}/etc/ssh/sshd_config.d/pocketforge.conf"
    echo "[customize] dev: sshd hardening drop-in installed"

    # Dev: multi-developer authorized_keys from device-config/dev/ssh/authorized_keys.d/*.pub
    # OpenSSH does not natively read from a directory — concatenate all .pub files
    # into a single authorized_keys at build time. One file per developer for clean
    # git blame and easy add/remove.
    KEYS_DIR="/work/src/device-config/dev/ssh/authorized_keys.d"
    install -d -o 1000 -g 1000 -m 0700 "${ROOTFS}/home/gamer/.ssh"
    KEY_COUNT=0
    : > "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    for pub in "${KEYS_DIR}"/*.pub; do
        [ -f "${pub}" ] || continue
        cat "${pub}" >> "${ROOTFS}/home/gamer/.ssh/authorized_keys"
        KEY_COUNT=$((KEY_COUNT + 1))
        echo "[customize] dev: added SSH key $(basename "${pub}")"
    done
    chown 1000:1000 "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    chmod 0600 "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    echo "[customize] dev: authorized_keys installed (${KEY_COUNT} keys)"

    # Dev: give the serial 'debug' user the same authorized_keys so it is
    # key-SSH-able over WiFi for iteration. sshd keeps PermitRootLogin no, but
    # debug is non-root and no AllowUsers/AllowGroups excludes it, so key auth
    # works. Mirrors the gamer keys above; removed with the debug user before
    # release (tsp-iuz.2.9). Release ships no sshd/keys at all. bd: tsp-cv7.4.11.
    install -d -m 0700 "${ROOTFS}/home/debug/.ssh"
    install -m 0600 "${ROOTFS}/home/gamer/.ssh/authorized_keys" \
        "${ROOTFS}/home/debug/.ssh/authorized_keys"
    chroot "${ROOTFS}" chown -R debug:debug /home/debug/.ssh
    echo "[customize] dev: debug authorized_keys installed (${KEY_COUNT} keys, SSH-over-WiFi)"

    # openssh-server's postinst generates random host keys in the build chroot.
    # Strip them from the image and generate unique keys on each device's first
    # boot before sshd starts.
    rm -f "${ROOTFS}"/etc/ssh/ssh_host_*
    install -d "${ROOTFS}/etc/systemd/system/ssh.service.d"
    install -m 0644 \
        "/work/src/rootfs-overlay/etc/systemd/system/ssh-keygen-firstboot.service" \
        "${ROOTFS}/etc/systemd/system/ssh-keygen-firstboot.service"
    install -m 0644 \
        "/work/src/rootfs-overlay/etc/systemd/system/ssh.service.d/pocketforge-hostkeys.conf" \
        "${ROOTFS}/etc/systemd/system/ssh.service.d/pocketforge-hostkeys.conf"
    chroot "${ROOTFS}" systemctl enable ssh-keygen-firstboot.service
    chroot "${ROOTFS}" systemctl enable ssh.service
    echo "[customize] dev: build-time SSH host keys removed; first-boot keygen and ssh.service enabled"
elif [ "${VARIANT}" = "release" ]; then
    # Release: strip libSDL3 + future supervisor binary
    if command -v aarch64-none-linux-gnu-strip >/dev/null 2>&1; then
        aarch64-none-linux-gnu-strip --strip-unneeded \
            "${ROOTFS}/opt/pocketforge/lib/libSDL3-pocketforge.so.0" || true
        echo "[customize] release: libSDL3 stripped"
    elif command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
        aarch64-linux-gnu-strip --strip-unneeded \
            "${ROOTFS}/opt/pocketforge/lib/libSDL3-pocketforge.so.0" || true
        echo "[customize] release: libSDL3 stripped (gnu strip)"
    else
        echo "[customize] WARN: no aarch64 strip available; skipping"
    fi
fi

echo "[customize] Customization complete."
CUSTOMIZE_EOF
chmod +x "${CUSTOMIZE_SCRIPT}"

# Run mmdebstrap with the customize hook.
# --mode=root because this script runs as root inside the container
# (mmdebstrap needs chroot/mount for cross-arch; container provides isolation).
# --aptopt disables valid-until checking (snapshot mirrors have stale headers) and
# sets Acquire::Retries so a transient snapshot.debian.org 503 (it is chronically
# flaky/rate-limited — a Fastly outage blocked the first pipeline run 2026-07-02)
# retries with apt's exponential backoff instead of aborting the whole build.
# mmdebstrap runs its OWN apt in the target, so it does NOT inherit the base
# container's /etc/apt Retries — it must be passed here. (Retries survive transient
# 503s; a sustained total outage still needs a mirror fallback / local apt cache.)
# SOURCE_DATE_EPOCH is inherited for reproducibility.
#
# Optional transparent apt caching proxy. When PF_APT_PROXY is set (e.g. the NAS
# apt-cacher-ng at http://10.0.32.86:3142, which fronts snapshot.debian.org and
# routes the flaky .deb pool to a fast reproducible mirror), mmdebstrap's apt uses
# it. This is a FETCH TRANSPORT ONLY and fully TRANSPARENT: apt verifies every .deb
# against the signed InRelease->Packages chain from the pinned snapshot date, so the
# proxy cannot change the bytes — G-reproducible / the R1 gate are preserved (a cache
# HIT and a direct fetch yield identical rootfs contents). Empty by default = direct
# snapshot. Not recorded in provenance; it never affects output bytes.
APT_PROXY_OPT=()
if [ -n "${PF_APT_PROXY:-}" ]; then
    echo "  apt proxy: ${PF_APT_PROXY} (transparent cache; bytes verified vs signed index)"
    APT_PROXY_OPT=( --aptopt="Acquire::http::Proxy \"${PF_APT_PROXY}\"" )
fi
# ---- Cross-compile the boot animator (bd: tsp-3rd3.4) ----------------------
# Built before mmdebstrap so the customize hook (which cannot see the outer
# ${WORK}) just installs a ready-to-copy binary. Deterministic: same source +
# same toolchain -> byte-identical binary (SOURCE_DATE_EPOCH already exported).
ANIMATOR_SRC_DIR="${SRC_DIR}/apps/pocketforge-boot-animator"
PF_ANIMATOR_BIN="${WORK}/pocketforge-boot-animator"
CROSS_CC="/opt/arm-10.3-2021.07/bin/aarch64-none-linux-gnu-gcc"
CROSS_STRIP="/opt/arm-10.3-2021.07/bin/aarch64-none-linux-gnu-strip"
echo "  Cross-compiling pocketforge-boot-animator (aarch64)..."
"${CROSS_CC}" \
    -O2 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
    -static-libgcc \
    -I"${ANIMATOR_SRC_DIR}/src" \
    -o "${PF_ANIMATOR_BIN}" \
    "${ANIMATOR_SRC_DIR}/src/main.c" \
    -lm
"${CROSS_STRIP}" "${PF_ANIMATOR_BIN}"
echo "    -> $(du -h "${PF_ANIMATOR_BIN}" | awk '{print $1}') stripped"
export PF_ANIMATOR_BIN

# ---- Cross-compile the throwaway placeholder screen (bd: tsp-147u.21) -------
# THROWAWAY / proof-of-life: a static post-boot screen that supersedes the boot
# animator (see apps/pocketforge-placeholder). Same deterministic cross-compile
# as the animator; libc only (no image decode, no assets).
# bd tsp-ga7s.1: the MENU below supersedes THIS placeholder at boot — the
# placeholder binary + unit stay installed but not enabled (one-symlink-swap
# recovery). Still cross-compiled so the recovery ExecStart works.
PLACEHOLDER_SRC_DIR="${SRC_DIR}/apps/pocketforge-placeholder"
PF_PLACEHOLDER_BIN="${WORK}/pocketforge-placeholder"
echo "  Cross-compiling pocketforge-placeholder (aarch64)..."
"${CROSS_CC}" \
    -O2 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
    -static-libgcc \
    -I"${PLACEHOLDER_SRC_DIR}/src" \
    -o "${PF_PLACEHOLDER_BIN}" \
    "${PLACEHOLDER_SRC_DIR}/src/main.c"
"${CROSS_STRIP}" "${PF_PLACEHOLDER_BIN}"
echo "    -> $(du -h "${PF_PLACEHOLDER_BIN}" | awk '{print $1}') stripped"
export PF_PLACEHOLDER_BIN

# ---- Cross-compile the MVP static menu (bd: tsp-ga7s.1) --------------------
# MVP 3-entry launcher — Button Tester / Steam Link / poolside.fm, LRADC volume
# keys nav (KEY_VOLUMEUP / KEY_VOLUMEDOWN, wrapping), no select action. Same
# deterministic cross-compile pattern as the placeholder; libc only (no assets,
# no image decode, no freetype — an 8x16 bitmap font is embedded in main.c).
# The menu SUPERSEDES the placeholder at boot (see the enable-symlink swap
# further down); the placeholder stays installed unenabled as one-swap recovery.
MENU_SRC_DIR="${SRC_DIR}/apps/pocketforge-menu"
PF_MENU_BIN="${WORK}/pocketforge-menu"
echo "  Cross-compiling pocketforge-menu (aarch64)..."
"${CROSS_CC}" \
    -O2 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
    -static-libgcc \
    -I"${MENU_SRC_DIR}/src" \
    -o "${PF_MENU_BIN}" \
    "${MENU_SRC_DIR}/src/main.c"
"${CROSS_STRIP}" "${PF_MENU_BIN}"
echo "    -> $(du -h "${PF_MENU_BIN}" | awk '{print $1}') stripped"
export PF_MENU_BIN

# The recovery executable is built in its own hermetic Docker stage from the
# platform.lock-selected recovery archive. Do not fall back to a host artifact.
RECOVERY_DIR="${RECOVERY_DIR:-/work/recovery}"
PF_RECOVERY_BIN="${RECOVERY_DIR}/bin/pocketforge-recovery-entry"
[ -x "${PF_RECOVERY_BIN}" ] || { echo "FATAL: pinned recovery executable missing: ${PF_RECOVERY_BIN}" >&2; exit 1; }
[ "${PF_RECOVERY_SHA:-}" = "7044d4980524c1d1f64e179760cbbd55c30899da" ] || {
    echo "FATAL: recovery provenance is not pinned to F15 commit 7044d49" >&2
    exit 1
}
export PF_RECOVERY_BIN

echo "  Running mmdebstrap (this may take several minutes under qemu...)..."
POCKETFORGE_VARIANT="${VARIANT}" \
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
mmdebstrap \
    --arch=arm64 \
    --variant=minbase \
    --mode=root \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --aptopt='APT::Sandbox::User "root"' \
    --aptopt='Acquire::Retries "5"' \
    "${APT_PROXY_OPT[@]}" \
    --include="${PKG_LIST}" \
    --customize-hook="env POCKETFORGE_VARIANT=${VARIANT} PF_GPU_MODEL=${PF_GPU_MODEL} PF_ANIMATOR_BIN=${PF_ANIMATOR_BIN} PF_PLACEHOLDER_BIN=${PF_PLACEHOLDER_BIN} PF_MENU_BIN=${PF_MENU_BIN} PF_RECOVERY_BIN=${PF_RECOVERY_BIN} ${CUSTOMIZE_SCRIPT} \"\$1\"" \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    bookworm \
    "${ROOTFS_TAR}" \
    "${SNAPSHOT_URL}"

ROOTFS_SIZE="$(stat -c%s "${ROOTFS_TAR}")"
echo "  rootfs.tar: ${ROOTFS_SIZE} bytes ($(( ROOTFS_SIZE / 1024 / 1024 )) MiB)"

# ---- step 4: deterministic ext4 assembly -----------------------------------
echo ""
echo "=== Step 4/4: Deterministic ext4 assembly ==="

ROOTFS_EXTRACTED="${WORK}/rootfs-extracted"
mkdir -p "${ROOTFS_EXTRACTED}"

# Extract the rootfs tar
tar -xf "${ROOTFS_TAR}" -C "${ROOTFS_EXTRACTED}"

# Fail the build before ext4 assembly if DHCP DNS cannot reach libc. This is a
# structural image check; lease population itself is verified on tsp-f956's boot.
"${SRC_DIR}/scripts/verify-rootfs-dns.sh" "${ROOTFS_EXTRACTED}"

# Report rootfs size
ROOTFS_DU="$(du -sm "${ROOTFS_EXTRACTED}" | cut -f1)"
echo "  rootfs extracted: ${ROOTFS_DU} MiB"

# Size the ext4 image: rootfs size + 25% headroom, minimum 1024 MiB
EXT4_SIZE_MB=1024
if [ "${ROOTFS_DU}" -gt 768 ]; then
    EXT4_SIZE_MB=$(( ROOTFS_DU * 125 / 100 ))
    echo "  rootfs exceeds 768 MiB — auto-sizing ext4 to ${EXT4_SIZE_MB} MiB"
fi
EXT4_SIZE_BLOCKS=$(( EXT4_SIZE_MB * 1024 ))   # 1K blocks for mke2fs
echo "  ext4 target: ${EXT4_SIZE_MB} MiB (${EXT4_SIZE_BLOCKS} x 1K blocks)"

# Pre-stage: clamp mtimes for reproducibility (Reproducible-Builds recipe).
# We operate on the extracted directory tree directly — mke2fs -d <directory>
# is more reliable than -d <tar> (avoids locale-dependent tar parsing issues).
echo "  Clamping mtimes to SOURCE_DATE_EPOCH for reproducibility..."
find "${ROOTFS_EXTRACTED}" -depth -print0 | \
    xargs -0 touch --no-dereference --date="@${SOURCE_DATE_EPOCH}" 2>/dev/null || true

# Build the ext4 from the directory with committed, stable UUIDs.
# The -d <directory> form gives deterministic inode order when the directory
# entries are already sorted (the mmdebstrap tar is sorted by default).
USERDATA_EXT4="${OUT_DIR}/userdata.ext4"
mke2fs -t ext4 \
    -d "${ROOTFS_EXTRACTED}" \
    -E "hash_seed=${USERDATA_HASH_SEED}" \
    -U "${USERDATA_FS_UUID}" \
    -L "POCKETFORGE_DATA" \
    -O "^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit" \
    -m 0 \
    "${USERDATA_EXT4}" ${EXT4_SIZE_BLOCKS}

EXT4_SIZE="$(stat -c%s "${USERDATA_EXT4}")"
EXT4_SHA="$(sha256sum "${USERDATA_EXT4}" | cut -d' ' -f1)"

echo ""
echo "========================================================================"
echo "ROOTFS BUILD COMPLETE"
echo "========================================================================"
echo "  ${USERDATA_EXT4}"
echo "  size:      ${EXT4_SIZE} bytes ($(( EXT4_SIZE / 1024 / 1024 )) MiB)"
echo "  sha256:    ${EXT4_SHA}"
echo "  variant:   ${VARIANT}"
echo "  label:     POCKETFORGE_DATA"
echo "  fs-uuid:   ${USERDATA_FS_UUID}"
echo "  hash-seed: ${USERDATA_HASH_SEED}"
echo ""

# Chown output to the caller's uid:gid if specified
if [ -n "${OWNER_UID}" ] && [ -n "${OWNER_GID}" ]; then
    chown "${OWNER_UID}:${OWNER_GID}" "${USERDATA_EXT4}"
    echo "  chown: ${OWNER_UID}:${OWNER_GID}"
fi

# Write SHA manifest
echo "${EXT4_SHA}  userdata.ext4" > "${OUT_DIR}/userdata.ext4.sha256"
if [ -n "${OWNER_UID}" ] && [ -n "${OWNER_GID}" ]; then
    chown "${OWNER_UID}:${OWNER_GID}" "${OUT_DIR}/userdata.ext4.sha256"
fi
