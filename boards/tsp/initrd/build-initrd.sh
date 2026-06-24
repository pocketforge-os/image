#!/usr/bin/env bash
# =============================================================================
# build-initrd.sh — assemble the PocketForge hand-rolled cpio initrd (M1.B)
# -----------------------------------------------------------------------------
# Produces a reproducible gzip'd cpio initrd containing:
#   /init                         (boards/tsp/initrd/init)
#   /bin/busybox                  (busybox-static, arm64, from the pinned snapshot)
#   /lib/modules/*.ko             (PowerVR set from blobs/tsp/kernel-4.9.191)
#   /etc/pocketforge-initrd-version
#   /etc/pocketforge-m1b-mode     (ONLY when --m1b-mode)
#
# Run INSIDE the pocketforge/build container (needs busybox-static:arm64 from
# the snapshot mirror, cpio, gzip, dpkg, aarch64 readelf). Hand-rolled, NOT
# mkinitramfs (which would target the host kernel's modules — wrong ABI).
#
# Reproducibility (G-reproducible floor; M1.E hardens):
#   - sorted cpio entry order (find | LC_ALL=C sort)
#   - cpio -H newc --owner 0:0  (fixed uid/gid)
#   - gzip -n                   (no embedded mtime/filename)
#   - every staged file's mtime clamped to SOURCE_DATE_EPOCH
#   Two runs with the same inputs + mode => identical SHA-256.
#
# Usage:
#   build-initrd.sh [--m1b-mode] [--blobs DIR] [--out FILE] [--src DIR]
#
# Defaults assume the documented container bind-mount layout:
#   --src   /work/src     (this image repo)
#   --blobs /work/blobs   (the blobs repo checkout)
#   --out   /work/out/initrd.gz
#
# bd: tsp-iuz.1.6 (initrd), tsp-iuz.1.11 (M1.B-mode), tsp-iuz.1.3 (kernel blobs)
# =============================================================================
set -euo pipefail

# ---- args -------------------------------------------------------------------
M1B_MODE=0
SRC_DIR="${SRC_DIR:-/work/src}"
BLOBS_DIR="${BLOBS_DIR:-/work/blobs}"
OUT_FILE="${OUT_FILE:-/work/out/initrd.gz}"
KERNEL_TSP_DIR=""
GPU_KM_DIR=""
VARIANT="dev"

while [ $# -gt 0 ]; do
    case "$1" in
        --m1b-mode)        M1B_MODE=1; shift ;;
        --blobs)           BLOBS_DIR="$2"; shift 2 ;;
        --out)             OUT_FILE="$2"; shift 2 ;;
        --src)             SRC_DIR="$2"; shift 2 ;;
        --variant)         VARIANT="$2"; shift 2 ;;
        --kernel-tsp-dir)  KERNEL_TSP_DIR="$2"; shift 2 ;;
        --gpu-km-dir)      GPU_KM_DIR="$2"; shift 2 ;;
        *) echo "build-initrd.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

# Determine substrate mode from args
SUBSTRATE="vendor"
if [ -n "$KERNEL_TSP_DIR" ] && [ -n "$GPU_KM_DIR" ]; then
    SUBSTRATE="owned"
fi

# ---- inputs -----------------------------------------------------------------
INITRD_SRC="${SRC_DIR}/boards/tsp/initrd"

if [ "$SUBSTRATE" = "owned" ]; then
    # Phase 2: modules from kernel-tsp + gpu-km-tsp builds
    echo "  substrate: owned (kernel-tsp + gpu-km-tsp)"

    # videobuf2-dma-contig from kernel-tsp build tree
    KERNEL_VB2="$(find "${KERNEL_TSP_DIR}" -name 'videobuf2-dma-contig.ko' -type f | head -1)"
    [ -n "${KERNEL_VB2}" ] || { echo "FATAL: videobuf2-dma-contig.ko not found in kernel-tsp build tree" >&2; exit 1; }

    # GPU modules from gpu-km-tsp
    GPU_PVRSRVKM="${GPU_KM_DIR}/pvrsrvkm.ko"
    GPU_DC_SUNXI="${GPU_KM_DIR}/dc_sunxi.ko"
    [ -f "${GPU_PVRSRVKM}" ] || { echo "FATAL: pvrsrvkm.ko not found at ${GPU_PVRSRVKM}" >&2; exit 1; }
    [ -f "${GPU_DC_SUNXI}" ] || { echo "FATAL: dc_sunxi.ko not found at ${GPU_DC_SUNXI}" >&2; exit 1; }

    echo "  videobuf2: ${KERNEL_VB2}"
    echo "  pvrsrvkm:  ${GPU_PVRSRVKM}"
    echo "  dc_sunxi:  ${GPU_DC_SUNXI}"
else
    # Phase 1: modules from vendor blobs
    echo "  substrate: vendor (blobs)"
    MODULES_DIR="${BLOBS_DIR}/tsp/kernel-4.9.191/modules"
    KERNEL_SHA="${BLOBS_DIR}/tsp/kernel-4.9.191/KERNEL.SHA256"
    [ -d "${MODULES_DIR}" ] || { echo "FATAL: ${MODULES_DIR} not found (blobs checkout?)" >&2; exit 1; }
fi

# The initrd module set, in load order. NOTE: videobuf2-dma-contig.ko is
# HYPHENATED on disk (runtime/lsmod name is underscored). Verified on blobs.
MODULES="videobuf2-dma-contig.ko pvrsrvkm.ko dc_sunxi.ko"

# Reproducible mtime. Prefer the image repo's head commit; fall back to a fixed
# epoch so an out-of-git invocation is still deterministic.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    if git -C "${SRC_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        SOURCE_DATE_EPOCH="$(git -C "${SRC_DIR}" log -1 --format=%ct)"
    else
        SOURCE_DATE_EPOCH=1700000000   # 2023-11-14T22:13:20Z, arbitrary fixed
    fi
fi
export SOURCE_DATE_EPOCH

echo "=== build-initrd.sh ==="
echo "  src:     ${SRC_DIR}"
echo "  blobs:   ${BLOBS_DIR}"
echo "  out:     ${OUT_FILE}"
echo "  mode:    $([ "$M1B_MODE" = 1 ] && echo 'M1.B (fall-through to shell)' || echo 'normal (switch_root)')"
echo "  epoch:   ${SOURCE_DATE_EPOCH}"

[ -f "${INITRD_SRC}/init" ] || { echo "FATAL: ${INITRD_SRC}/init not found" >&2; exit 1; }

# ---- verify module SHAs against the blobs manifest --------------------------
# Guards against a corrupted/partial blobs checkout silently shipping a bad .ko.
# (vendor substrate only — owned-substrate modules are build outputs, not pinned blobs)
if [ "$SUBSTRATE" = "vendor" ]; then
    [ -d "${MODULES_DIR}" ] || { echo "FATAL: ${MODULES_DIR} not found (blobs checkout?)" >&2; exit 1; }
    if [ -f "${KERNEL_SHA}" ]; then
        echo "=== verifying module SHA-256 against KERNEL.SHA256 ==="
        ( cd "${BLOBS_DIR}/tsp/kernel-4.9.191"
          for m in $MODULES; do
              grep -E "  modules/${m}\$" KERNEL.SHA256 | sha256sum -c -
          done )
    else
        echo "WARN: ${KERNEL_SHA} absent — skipping module SHA verification" >&2
    fi
fi

# ---- staging tree -----------------------------------------------------------
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
mkdir -p "${STAGING}"/{bin,dev,proc,sys,newroot,pflog,etc,lib/modules}

# busybox-static (arm64) is baked into the container at build time as an initrd
# payload (see image/build/Dockerfile). We copy that binary rather than apt-
# downloading at runtime: the initrd build runs as a non-root --user that can't
# apt-get update/download, and a baked-in binary keeps the build network-free
# and pinned by the container digest.
echo "=== staging baked-in busybox-static:arm64 ==="
BB_SRC="${BUSYBOX_ARM64:-/opt/pocketforge/initrd-payload/busybox-arm64}"
[ -f "${BB_SRC}" ] || { echo "FATAL: baked busybox not found at ${BB_SRC} (old container? rebuild + re-pin)" >&2; exit 1; }
# Integrity check against the SHA recorded when the container baked it in.
if [ -f "${BB_SRC}.sha256" ]; then
    echo "$(cat "${BB_SRC}.sha256")  ${BB_SRC}" | sha256sum -c - >/dev/null \
        || { echo "FATAL: baked busybox SHA mismatch" >&2; exit 1; }
fi
cp "${BB_SRC}" "${STAGING}/bin/busybox"
chmod 0755 "${STAGING}/bin/busybox"

# Verify busybox is truly static arm64 (no DT_NEEDED) — a dynamic busybox would
# fail as the initrd's first process (no rootfs /lib yet).
echo "=== verifying busybox is static arm64 ==="
aarch64-linux-gnu-readelf -h "${STAGING}/bin/busybox" | grep -q 'AArch64' \
    || { echo "FATAL: busybox is not AArch64" >&2; exit 1; }
if aarch64-linux-gnu-readelf -d "${STAGING}/bin/busybox" 2>/dev/null | grep -q 'NEEDED'; then
    echo "FATAL: busybox has DT_NEEDED entries (not static)" >&2; exit 1
fi
echo "  busybox: AArch64, statically linked — OK"

# Self-flash recovery (dev) relies on these busybox applets in /init. Assert they
# are compiled into this busybox so a missing applet fails the BUILD, not a boot.
# (bd tsp-bcx.17) — qemu-user runs the arm64 binary; --list works without args.
if [ "$VARIANT" = "dev" ]; then
    echo "=== verifying busybox provides self-flash applets (unxz, sha256sum, dd, findfs) ==="
    BB_APPLETS="$("${STAGING}/bin/busybox" --list 2>/dev/null || true)"
    if [ -n "$BB_APPLETS" ]; then
        for ap in unxz sha256sum dd findfs head sed tr reboot mount umount sync; do
            printf '%s\n' "$BB_APPLETS" | grep -qx "$ap" \
                || { echo "FATAL: busybox lacks applet '$ap' (needed by self-flash /init)" >&2; exit 1; }
        done
        echo "  busybox self-flash applets present — OK"
    else
        echo "  WARN: could not list busybox applets (no qemu-user?); skipping applet assert" >&2
    fi
fi

# /init
install -m 0755 "${INITRD_SRC}/init" "${STAGING}/init"

# Module set (flat under /lib/modules to match the insmod paths in /init).
if [ "$SUBSTRATE" = "owned" ]; then
    # Owned substrate: videobuf2 from kernel-tsp, GPU modules from gpu-km-tsp
    cp "${KERNEL_VB2}" "${STAGING}/lib/modules/videobuf2-dma-contig.ko"
    cp "${GPU_PVRSRVKM}" "${STAGING}/lib/modules/pvrsrvkm.ko"
    cp "${GPU_DC_SUNXI}" "${STAGING}/lib/modules/dc_sunxi.ko"
else
    # Vendor substrate: all modules from blobs
    for m in $MODULES; do
        cp "${MODULES_DIR}/${m}" "${STAGING}/lib/modules/${m}"
    done
fi
# Ensure consistent permissions regardless of source
for m in $MODULES; do
    chmod 0644 "${STAGING}/lib/modules/${m}"
done

# GPU firmware — pvrsrvkm calls request_firmware() at insmod time, which looks
# in /lib/firmware/ (the initrd's, since rootfs isn't mounted yet). Without these
# files pvrsrvkm registers the BVNC but fails init with err=-19 (ENODEV) and
# dc_sunxi cascades into "No such device". Firmware is always from blobs/ (the
# closed DDK firmware is version-locked to the UM blobs, not to the KM source).
GPU_FW_DIR="${BLOBS_DIR}/tsp/22.102.54.38/firmware"
mkdir -p "${STAGING}/lib/firmware"
for fw in rgx.fw.22.102.54.38 rgx.sh.22.102.54.38; do
    [ -f "${GPU_FW_DIR}/${fw}" ] || { echo "FATAL: GPU firmware ${fw} not found at ${GPU_FW_DIR}" >&2; exit 1; }
    cp "${GPU_FW_DIR}/${fw}" "${STAGING}/lib/firmware/${fw}"
    chmod 0644 "${STAGING}/lib/firmware/${fw}"
    echo "  firmware: ${fw} ($(stat -c%s "${GPU_FW_DIR}/${fw}") bytes)"
done

# Strip debug symbols from modules to minimize initrd size.
# pvrsrvkm.ko: ~22 MB unstripped -> ~2 MB stripped (debug info is enormous).
# insmod only needs the .text/.data/.symtab sections; .debug_* is unnecessary.
echo "=== stripping debug symbols from initrd modules ==="
for m in $MODULES; do
    BEFORE="$(stat -c%s "${STAGING}/lib/modules/${m}")"
    aarch64-none-linux-gnu-strip --strip-debug "${STAGING}/lib/modules/${m}"
    AFTER="$(stat -c%s "${STAGING}/lib/modules/${m}")"
    echo "  ${m}: ${BEFORE} -> ${AFTER} bytes"
done

# Version stamp (read by /init's banner).
printf '%s\n' "${SOURCE_DATE_EPOCH}-$([ "$M1B_MODE" = 1 ] && echo m1b || echo norm)" \
    > "${STAGING}/etc/pocketforge-initrd-version"

# M1.B-mode marker (presence-only switch in /init).
if [ "$M1B_MODE" = 1 ]; then
    install -m 0644 "${INITRD_SRC}/m1b-mode" "${STAGING}/etc/pocketforge-m1b-mode"
fi

# Self-flash gate marker (presence-only switch in /init; dev variant only) so a
# release image never honors a stray self-flash flag. (bd tsp-bcx.17)
if [ "$VARIANT" = "dev" ]; then
    printf 'self-flash recovery enabled (dev image) — bd tsp-bcx.17\n' \
        > "${STAGING}/etc/pocketforge-selfflash"
    chmod 0644 "${STAGING}/etc/pocketforge-selfflash"
    echo "  staged /etc/pocketforge-selfflash (dev gate)"
fi

# ---- clamp mtimes for reproducibility ---------------------------------------
# All staged files get mtime = SOURCE_DATE_EPOCH so the cpio header timestamps
# are stable. (cpio -H newc embeds mtime; gzip -n drops the gzip-level mtime.)
find "${STAGING}" -exec touch --no-dereference --date="@${SOURCE_DATE_EPOCH}" {} +

# ---- assemble reproducible cpio ---------------------------------------------
echo "=== assembling cpio -> ${OUT_FILE} ==="
mkdir -p "$(dirname "${OUT_FILE}")"
( cd "${STAGING}" \
  && find . -mindepth 1 | LC_ALL=C sort \
  | cpio --quiet -o -H newc --owner 0:0 ) \
  | gzip -n -9 > "${OUT_FILE}"

SHA="$(sha256sum "${OUT_FILE}" | cut -d' ' -f1)"
SIZE="$(stat -c%s "${OUT_FILE}")"
echo "=== done ==="
echo "  ${OUT_FILE}"
echo "  size:   ${SIZE} bytes"
echo "  sha256: ${SHA}"
