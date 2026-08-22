#!/usr/bin/env bash
# Verify that a GPT image embeds the exact userdata.ext4 supplied to genimage.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <disk.img> <userdata.ext4>" >&2
    exit 2
fi

IMAGE="$1"
USERDATA="$2"
[ -f "${IMAGE}" ] || { echo "FATAL: disk image not found: ${IMAGE}" >&2; exit 1; }
[ -f "${USERDATA}" ] || { echo "FATAL: userdata image not found: ${USERDATA}" >&2; exit 1; }

# Read the committed GPT rather than duplicating genimage's alignment arithmetic.
# sfdisk emits one line per partition with byte-independent sector start/size fields.
PARTITION="$(sfdisk --dump "${IMAGE}" | awk '
    /name="userdata"/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "start=") start=$(i + 1)
            if ($i == "size=") size=$(i + 1)
        }
        gsub(/,/, "", start); gsub(/,/, "", size)
        print start, size
    }
')"
[ -n "${PARTITION}" ] || {
    echo "FATAL: GPT userdata partition not found in ${IMAGE}" >&2
    exit 1
}
read -r START_SECTOR PARTITION_SECTORS <<< "${PARTITION}"

SECTOR_SIZE=512
USERDATA_BYTES="$(stat -c%s "${USERDATA}")"
PARTITION_BYTES=$((PARTITION_SECTORS * SECTOR_SIZE))
if [ "${USERDATA_BYTES}" -ne "${PARTITION_BYTES}" ]; then
    echo "FATAL: userdata size ${USERDATA_BYTES} does not match GPT partition size ${PARTITION_BYTES}" >&2
    exit 1
fi

OFFSET_BYTES=$((START_SECTOR * SECTOR_SIZE))
USERDATA_SHA="$(sha256sum "${USERDATA}" | cut -d' ' -f1)"
EMBEDDED_SHA="$(dd if="${IMAGE}" bs="${SECTOR_SIZE}" skip="${START_SECTOR}" \
    count="${PARTITION_SECTORS}" status=none | sha256sum | cut -d' ' -f1)"
echo "  userdata self-check: source=${USERDATA_SHA} embedded=${EMBEDDED_SHA} offset=${OFFSET_BYTES} bytes=${USERDATA_BYTES}"
if [ "${USERDATA_SHA}" != "${EMBEDDED_SHA}" ]; then
    echo "FATAL: assembled GPT userdata bytes diverge from ${USERDATA}" >&2
    exit 1
fi

