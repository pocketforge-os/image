#!/usr/bin/env bash
# =============================================================================
# sd-safety-check.sh — Validate an SD card partition before writing
# =============================================================================
# Runs five safety checks before any destructive write to an SD card partition:
#   1. Partition block device exists
#   2. Derive whole-disk device from partition
#   3. Not a system disk (reject NVMe, reject if mounted as /, /boot, swap)
#   4. Whole-disk size within bounds (default: 128 GiB max)
#   5. Target partition not mounted (auto-unmount with notice)
#
# Usage:
#   sd-safety-check.sh <partition-path> [max-disk-size-bytes]
#
# Exit 0 = safe to write.  Exit 1 = refused.
#
# bd: tsp-iuz.2.7
# =============================================================================
set -euo pipefail

PART_PATH="${1:-}"
MAX_SIZE="${2:-137438953472}"  # 128 GiB default

if [ -z "${PART_PATH}" ]; then
    echo "Usage: sd-safety-check.sh <partition-path> [max-disk-size-bytes]" >&2
    exit 1
fi

# ---- check 1: partition block device exists ---------------------------------
if [ ! -b "${PART_PATH}" ]; then
    echo "ERROR: ${PART_PATH} not found or is not a block device." >&2
    echo "  Is the PocketForge SD card inserted in the reader?" >&2
    echo "  List available partitions: lsblk -o NAME,SIZE,TYPE,PARTLABEL" >&2
    exit 1
fi

# Resolve symlink to the real device (e.g. /dev/sdb1)
REAL_PART="$(readlink -f "${PART_PATH}")"

# ---- check 2: derive whole-disk device -------------------------------------
DISK_NAME="$(lsblk -no PKNAME "${REAL_PART}" 2>/dev/null | head -1)"
if [ -z "${DISK_NAME}" ]; then
    echo "ERROR: could not determine parent disk for ${PART_PATH}" >&2
    exit 1
fi
DISK_DEV="/dev/${DISK_NAME}"

# ---- check 3: not a system disk --------------------------------------------
# Reject NVMe and virtio disks outright
case "${DISK_DEV}" in
    /dev/nvme*|/dev/vd*)
        echo "ERROR: ${DISK_DEV} is an NVMe or virtio disk — refusing to write." >&2
        exit 1
        ;;
esac

# Reject if any partition on this disk is mounted as /, /boot, /boot/efi, or swap
SYSTEM_MOUNTS="$(lsblk -rno MOUNTPOINT "${DISK_DEV}" 2>/dev/null | grep -E '^/(boot(/efi)?)?$|^\[SWAP\]$' || true)"
if [ -n "${SYSTEM_MOUNTS}" ]; then
    echo "ERROR: ${DISK_DEV} has partitions mounted as system paths:" >&2
    echo "  ${SYSTEM_MOUNTS}" >&2
    echo "  This appears to be a system disk. Refusing to write." >&2
    exit 1
fi

# ---- check 4: disk size within bounds ---------------------------------------
DISK_SIZE="$(lsblk -b -dno SIZE "${DISK_DEV}" 2>/dev/null | head -1)"
if [ -z "${DISK_SIZE}" ] || [ "${DISK_SIZE}" -eq 0 ]; then
    echo "ERROR: could not determine size of ${DISK_DEV}" >&2
    exit 1
fi

HUMAN_SIZE="$(awk "BEGIN { printf \"%.1f GiB\", ${DISK_SIZE}/1073741824 }" 2>/dev/null || echo "${DISK_SIZE} bytes")"

if [ "${DISK_SIZE}" -gt "${MAX_SIZE}" ]; then
    MAX_HUMAN="$(awk "BEGIN { printf \"%.0f GiB\", ${MAX_SIZE}/1073741824 }" 2>/dev/null || echo "${MAX_SIZE} bytes")"
    echo "ERROR: ${DISK_DEV} is ${HUMAN_SIZE}, exceeds maximum ${MAX_HUMAN}." >&2
    echo "  If this is intentional, set SD_MAX_SIZE_BYTES=${DISK_SIZE}" >&2
    exit 1
fi

# ---- check 5: target partition not mounted (auto-unmount) -------------------
MOUNT_POINT="$(findmnt -rno TARGET "${REAL_PART}" 2>/dev/null || true)"
if [ -n "${MOUNT_POINT}" ]; then
    echo "  Auto-unmounting ${REAL_PART} from ${MOUNT_POINT}..."
    # Prefer udisksctl (unprivileged, handles user-session mounts cleanly)
    if command -v udisksctl >/dev/null 2>&1; then
        udisksctl unmount -b "${REAL_PART}" --no-user-interaction 2>/dev/null || \
            sudo umount "${REAL_PART}" 2>/dev/null || {
                echo "ERROR: failed to unmount ${REAL_PART} from ${MOUNT_POINT}" >&2
                echo "  Unmount manually: sudo umount ${REAL_PART}" >&2
                exit 1
            }
    else
        sudo umount "${REAL_PART}" 2>/dev/null || {
            echo "ERROR: failed to unmount ${REAL_PART} from ${MOUNT_POINT}" >&2
            echo "  Unmount manually: sudo umount ${REAL_PART}" >&2
            exit 1
        }
    fi
    echo "  Unmounted."
fi

# ---- all checks passed -----------------------------------------------------
PART_LABEL="$(lsblk -no PARTLABEL "${REAL_PART}" 2>/dev/null || echo "unknown")"
echo "sd-safety-check: OK — writing to ${REAL_PART} (${PART_LABEL}) on ${DISK_DEV} (${HUMAN_SIZE})"
