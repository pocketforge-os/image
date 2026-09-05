#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${ROOT}/rootfs-overlay/usr/lib/pocketforge/cedar-spike.sh"
BUILDER="${ROOT}/scripts/build-rootfs.sh"
DOC="${ROOT}/docs/CEDAR-H264-SPIKE.md"

grep -Fxq ffmpeg "${ROOT}/rootfs-packages-dev.txt"
grep -Fxq libvdpau1 "${ROOT}/rootfs-packages-dev.txt"
grep -Fxq strace "${ROOT}/rootfs-packages-dev.txt"

grep -Fq -- '-hwaccel vdpau -hwaccel_output_format vdpau' "${RUNNER}"
grep -Fq '"/dev/cedar_dev"' "${RUNNER}"
grep -Fq "ioctl\\(\${cedar_fd}," "${RUNNER}"
grep -Fq 'libvdpau_sunxi_not_shipped' "${RUNNER}"
grep -Fq 'hw_used=yes' "${RUNNER}"
grep -Fq 'frames" -eq 900' "${RUNNER}"

grep -Fq 'testsrc2=size=1280x720:rate=30:duration=30' "${BUILDER}"
grep -Fq "[ \"\${CEDAR_FRAMES}\" = \"900\" ]" "${BUILDER}"
grep -Fq 'sudo /usr/lib/pocketforge/cedar-spike.sh' "${DOC}"

negative_output="$(${RUNNER} 2>&1 || true)"
[ "${negative_output}" = 'FAIL cedar-h264 hw_used=no frames=0 blocker=cedar_device_missing' ]

echo 'PASS: Cedar spike is dev-only, 900-frame, VDPAU-forced, and ioctl-evidenced'
