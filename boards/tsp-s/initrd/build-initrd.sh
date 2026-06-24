#!/usr/bin/env bash
# =============================================================================
# boards/tsp-s/initrd/build-initrd.sh — build the A523 switch_root initramfs
# =============================================================================
# Assembles a reproducible gzip'd cpio initramfs: a static arm64 busybox + our
# /init (switch_root by FS label). Runs INSIDE the pocketforge/build container.
# Much simpler than the A133 initrd — no GPU/DMA modules are preloaded (the A523
# kernel builds MMC + ext4 in-tree).
#
# Inputs (env-overridable):
#   INIT_SRC   boards/tsp-s/initrd/init  (the /init script)
#   BUSYBOX    /opt/pocketforge/initrd-payload/busybox-arm64 (baked in container)
#   OUT        output path for initramfs.gz
#   SOURCE_DATE_EPOCH  reproducible mtime clamp
# =============================================================================
set -euo pipefail

SRC_DIR="${SRC_DIR:-/work/src}"
INIT_SRC="${INIT_SRC:-${SRC_DIR}/boards/tsp-s/initrd/init}"
BUSYBOX="${BUSYBOX:-/opt/pocketforge/initrd-payload/busybox-arm64}"
OUT="${OUT:-/work/out/initramfs-a523.gz}"
VERSION="${PF_INITRD_VERSION:-$(cd "${SRC_DIR}" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo dev)}"

: "${SOURCE_DATE_EPOCH:=1700000000}"
export SOURCE_DATE_EPOCH

[ -f "${INIT_SRC}" ] || { echo "FATAL: init not found: ${INIT_SRC}" >&2; exit 1; }
[ -f "${BUSYBOX}" ]  || { echo "FATAL: busybox-arm64 not found: ${BUSYBOX}" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
ROOT="${WORK}/initramfs"
mkdir -p "${ROOT}"/{bin,sbin,etc,proc,sys,dev,newroot,pflog,usr/bin,usr/sbin}

install -m 0755 "${BUSYBOX}" "${ROOT}/bin/busybox"
install -m 0755 "${INIT_SRC}" "${ROOT}/init"
printf '%s\n' "${VERSION}" > "${ROOT}/etc/pocketforge-initrd-version"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "${ROOT}/etc/passwd"

# --- self-flash gate marker (DEV images only; bd tsp-bcx.18) ------------------
# The /init self-flash recovery branch only acts when this marker is present, so
# a prod image never honors a stray flag. All A523 images are dev today; gate on
# VARIANT so a future prod build omits it.
VARIANT="${VARIANT:-dev}"
if [ "${VARIANT}" = "dev" ]; then
    : > "${ROOT}/etc/pocketforge-selfflash"
    echo "build-initrd: staged /etc/pocketforge-selfflash (dev self-flash gate)"
    # The recovery branch needs these busybox applets at boot — fail the BUILD
    # (not a silent no-boot) if the baked busybox lacks any.
    for ap in unxz sha256sum dd findfs head sed grep reboot sync mount umount; do
        "${BUSYBOX}" 2>&1 | tr ', \t' '\n' | grep -qx "$ap" || \
            { echo "FATAL: busybox lacks applet '$ap' (self-flash needs it)" >&2; exit 1; }
    done
fi

# Static device nodes (best-effort; /init mounts devtmpfs which also provides
# these. The kernel's "unable to open initial console" is non-fatal regardless).
mknod -m 600 "${ROOT}/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "${ROOT}/dev/null"    c 1 3 2>/dev/null || true

# Reproducible cpio: clamp mtimes, sort entries, gzip -n (no name/mtime header).
find "${ROOT}" -depth -print0 | xargs -0 touch --no-dereference --date="@${SOURCE_DATE_EPOCH}" 2>/dev/null || true
( cd "${ROOT}" && find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z | \
    cpio --quiet --null -o -H newc --owner=0:0 ) | gzip -n -9 > "${OUT}"

echo "initramfs-a523.gz: $(stat -c%s "${OUT}") bytes  sha256=$(sha256sum "${OUT}" | cut -d' ' -f1)  version=${VERSION}"
