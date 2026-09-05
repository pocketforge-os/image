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
grep -Fq 'strace -f -yy' "${RUNNER}"
grep -Fq 'ioctl\([0-9]+</dev/cedar_dev[^,]*>,' "${RUNNER}"
grep -Fq 'libvdpau_sunxi_not_shipped' "${RUNNER}"
grep -Fq 'hw_used=yes' "${RUNNER}"
grep -Fq 'frames" -eq 900' "${RUNNER}"

grep -Fq 'testsrc2=size=1280x720:rate=30:duration=30' "${BUILDER}"
grep -Fq "[ \"\${CEDAR_FRAMES}\" = \"900\" ]" "${BUILDER}"
grep -Fq 'sudo /usr/lib/pocketforge/cedar-spike.sh' "${DOC}"

negative_output="$(${RUNNER} 2>&1 || true)"
[ "${negative_output}" = 'FAIL cedar-h264 hw_used=no frames=0 blocker=cedar_device_missing' ]

# Regression fixture for image#88 review: the equal numeric descriptor belongs
# to /dev/tty0 after Cedar was closed, so it must not match the runner's predicate.
trace_fixture='123 openat(AT_FDCWD, "/dev/cedar_dev", O_RDWR) = 7</dev/cedar_dev>
123 close(7</dev/cedar_dev>) = 0
124 ioctl(7</dev/tty0>, TCGETS, 0xffff) = 0'
if printf '%s\n' "${trace_fixture}" | grep -Eq 'ioctl\([0-9]+</dev/cedar_dev[^,]*>,'; then
    echo 'FAIL: accepted same-number unrelated ioctl' >&2
    exit 1
fi
printf '%s\n' '123 ioctl(7</dev/cedar_dev<char 150:0>>, 0x100, 0) = 0' \
    | grep -Eq 'ioctl\([0-9]+</dev/cedar_dev[^,]*>,'

echo 'PASS: Cedar spike is dev-only, 900-frame, VDPAU-forced, and ioctl-evidenced'
