#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

IMAGE="${SCRATCH}/disk.img"
USERDATA="${SCRATCH}/userdata.ext4"
truncate -s 16M "${IMAGE}"
truncate -s 2M "${USERDATA}"
printf 'pocketforge-rootfs-canary\n' | dd of="${USERDATA}" bs=1 seek=4096 conv=notrunc status=none

parted -sm "${IMAGE}" mklabel gpt
parted -sm "${IMAGE}" unit s mkpart userdata 2048 6143
dd if="${USERDATA}" of="${IMAGE}" bs=512 seek=2048 conv=notrunc status=none

"${SRC_DIR}/scripts/verify-userdata-partition.sh" "${IMAGE}" "${USERDATA}"

# The guard must reject even a one-byte stale/corrupt embedded rootfs.
printf '\001' | dd of="${IMAGE}" bs=1 seek=$((2048 * 512 + 4096)) conv=notrunc status=none
if "${SRC_DIR}/scripts/verify-userdata-partition.sh" "${IMAGE}" "${USERDATA}" \
    >"${SCRATCH}/expected-failure.log" 2>&1; then
    echo "FAIL: verifier accepted a divergent userdata partition" >&2
    exit 1
fi
grep -F 'assembled GPT userdata bytes diverge' "${SCRATCH}/expected-failure.log"
echo "userdata partition self-check regression: PASS"
