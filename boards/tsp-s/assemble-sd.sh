#!/usr/bin/env bash
# =============================================================================
# boards/tsp-s/assemble-sd.sh — assemble the A523 (tsp-s) SD image
# =============================================================================
# Runs INSIDE the pocketforge/build container (loop-device-free via genimage,
# mirroring the A133 path). Composes:
#   SPL+U-Boot @ 8K  +  FAT boot (Image/DTB/initramfs/extlinux/wifi.txt)  +
#   ext4 rootfs (POCKETFORGE_DATA).
#
# Inputs (env-overridable):
#   KERNEL_IMAGE   owned 5.15.154 Image           (kernel-tsp-a523)
#   KERNEL_DTB     the boot DTB                    (stock-pros-rebuilt → tsp-vuo.7 owns it)
#   UBOOT_SPL      u-boot-sunxi-with-spl.bin       (u-boot-tsp-a523, BL31 embedded)
#   INITRAMFS      initramfs-a523.gz               (build-initrd.sh)
#   ROOTFS_EXT4    userdata-a523.ext4              (build-rootfs-a523.sh)
#   WIFI_TXT       optional wifi.txt for the FAT   (smoke; tsp-vuo.3 driver pending)
#   OUT_DIR        output dir                      (default /work/out)
# =============================================================================
set -euo pipefail

SRC_DIR="${SRC_DIR:-/work/src}"
BOARD_DIR="${SRC_DIR}/boards/tsp-s"
OUT_DIR="${OUT_DIR:-/work/out}"
# shellcheck source=boards/tsp-s/board.env
source "${BOARD_DIR}/board.env"
# shellcheck source=boards/tsp-s/fs-uuids.env
source "${BOARD_DIR}/fs-uuids.env"

KERNEL_IMAGE="${KERNEL_IMAGE:?set KERNEL_IMAGE}"
KERNEL_DTB="${KERNEL_DTB:?set KERNEL_DTB}"
UBOOT_SPL="${UBOOT_SPL:?set UBOOT_SPL}"
INITRAMFS="${INITRAMFS:-${OUT_DIR}/initramfs-a523.gz}"
ROOTFS_EXT4="${ROOTFS_EXT4:-${OUT_DIR}/userdata-a523.ext4}"
WIFI_TXT="${WIFI_TXT:-${BOARD_DIR}/boot-resource/wifi.txt}"

: "${SOURCE_DATE_EPOCH:=1700000000}"; export SOURCE_DATE_EPOCH

for f in "$KERNEL_IMAGE" "$KERNEL_DTB" "$UBOOT_SPL" "$INITRAMFS" "$ROOTFS_EXT4"; do
    [ -f "$f" ] || { echo "FATAL: missing input: $f" >&2; exit 1; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
GENIN="${WORK}/genin"; FATSTAGE="${WORK}/fat"
mkdir -p "${GENIN}" "${FATSTAGE}/extlinux"

echo "=== [1/4] extlinux.conf (console=${CONSOLE},${CONSOLE_BAUD}) ==="
cat > "${FATSTAGE}/extlinux/extlinux.conf" <<EOF
default pf
prompt 0
timeout 10
label pf
    kernel /Image
    fdt /${DTB_NAME}
    initrd /initramfs-a523.gz
    append console=${CONSOLE},${CONSOLE_BAUD} earlycon=${EARLYCON} ${CMDLINE_EXTRA}
EOF
cat "${FATSTAGE}/extlinux/extlinux.conf"

echo "=== [2/4] stage FAT contents ==="
cp "${KERNEL_IMAGE}" "${FATSTAGE}/Image"
cp "${KERNEL_DTB}"   "${FATSTAGE}/${DTB_NAME}"
cp "${INITRAMFS}"    "${FATSTAGE}/initramfs-a523.gz"
if [ -f "${WIFI_TXT}" ]; then
    cp "${WIFI_TXT}" "${FATSTAGE}/wifi.txt"
    echo "  wifi.txt staged onto FAT boot partition"
else
    echo "  (no wifi.txt — AIC8800 driver is tsp-vuo.3; FAT path still present)"
fi
# clamp mtimes for reproducibility before mcopy
find "${FATSTAGE}" -depth -print0 | xargs -0 touch --date="@${SOURCE_DATE_EPOCH}" 2>/dev/null || true

echo "=== [3/4] build FAT32 (label POCKETFORGE, volid ${BOOTRES_VOLID}) ==="
FAT_IMG="${GENIN}/boot-a523.vfat"
# Size the FAT to kernel+initrd+slack (round to MiB).
FAT_MB=$(( ( $(du -sk "${FATSTAGE}" | cut -f1) / 1024 ) + 24 ))
mkfs.vfat -F 32 -n POCKETFORGE -i "${BOOTRES_VOLID}" -C "${FAT_IMG}" "$(( FAT_MB * 1024 ))" >/dev/null
# mcopy -s preserves the extlinux/ subdir; -m preserves (clamped) mtimes.
( cd "${FATSTAGE}" && for e in *; do MTOOLS_SKIP_CHECK=1 mcopy -s -m -i "${FAT_IMG}" "$e" "::/$e"; done )

echo "=== [4/4] genimage assemble ==="
cp "${UBOOT_SPL}"   "${GENIN}/u-boot-sunxi-with-spl.bin"
cp "${ROOTFS_EXT4}" "${GENIN}/userdata-a523.ext4"
mkdir -p "${WORK}/gtmp" "${WORK}/empty"
genimage \
    --config "${BOARD_DIR}/genimage.cfg" \
    --inputpath "${GENIN}" \
    --outputpath "${OUT_DIR}" \
    --tmppath "${WORK}/gtmp" \
    --rootpath "${WORK}/empty"

IMG="${OUT_DIR}/${IMAGE_NAME}.img"
echo "=== compress + checksum ==="
xz -T1 -f -k "${IMG}"
echo "IMG=${IMG}"
sha256sum "${IMG}" "${IMG}.xz"
echo "SPL_OFFSET=${SPL_OFFSET_KIB}KiB DTB=${DTB_NAME} CONSOLE=${CONSOLE}"
echo "ASSEMBLE_A523_OK"
