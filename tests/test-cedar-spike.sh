#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${ROOT}/rootfs-overlay/usr/lib/pocketforge/cedar-spike.sh"
BUILDER="${ROOT}/scripts/build-rootfs.sh"
DOC="${ROOT}/docs/CEDAR-H264-SPIKE.md"
DOCKERFILE="${ROOT}/build/Dockerfile.pf"

grep -Fxq ffmpeg "${ROOT}/rootfs-packages-dev.txt"
grep -Fxq libvdpau1 "${ROOT}/rootfs-packages-dev.txt"
grep -Fxq libpixman-1-0 "${ROOT}/rootfs-packages-dev.txt"
grep -Fxq libx11-6 "${ROOT}/rootfs-packages-dev.txt"
grep -Fxq strace "${ROOT}/rootfs-packages-dev.txt"

# shellcheck disable=SC2016 # Assert literal variables in the installed runner.
grep -Fq 'cedar-headless-test "$DRIVER" "$CLIP"' "${RUNNER}"
grep -Fq 'strace -f -yy' "${RUNNER}"
grep -Fq 'live[result] = 1' "${RUNNER}"
grep -Fq 'libvdpau_sunxi_not_shipped' "${RUNNER}"
grep -Fq 'hw_used=yes' "${RUNNER}"
grep -Fq 'frames" -eq 900' "${RUNNER}"

grep -Fq 'sudo /usr/lib/pocketforge/cedar-spike.sh' "${DOC}"
# Hotfix tsp-h5ed.20 keeps the spike harness available for a clean re-land but
# removes it from every image build graph until its owned dependencies can be
# staged correctly and its profile gate can distinguish the closed DDK path.
if grep -Eq 'AS cedar-(lib|vdpau)|COPY --from=cedar|CEDAR_DIR=' "${DOCKERFILE}"; then
    echo 'FAIL: Cedar spike is still reachable from the image build graph' >&2
    exit 1
fi
if grep -Fq 'Cedar spike:' "${BUILDER}"; then
    echo 'FAIL: Cedar spike is still installed by build-rootfs.sh' >&2
    exit 1
fi
grep -Fq 'vdp_imp_device_create_headless' "${ROOT}/build/cedar-headless.patch"
grep -Fq 'return AV_PIX_FMT_NONE; /* Software fallback is forbidden. */' \
    "${ROOT}/build/cedar-headless-test.c"
grep -Fq 'dlopen(argv[1], RTLD_NOW | RTLD_LOCAL)' \
    "${ROOT}/build/cedar-headless-test.c"
grep -Fq 'printf("module=%s\n", argv[1]);' \
    "${ROOT}/build/cedar-headless-test.c"

negative_output="$(${RUNNER} 2>&1 || true)"
[ "${negative_output}" = 'FAIL cedar-h264 hw_used=no frames=0 blocker=cedar_device_missing' ]

# Regression fixture for image#88 review: the equal numeric descriptor belongs
# to /dev/tty0 after Cedar was closed, so it must not match the runner's predicate.
awk_program=$(sed -n "/^awk '/,/^' \"\$TRACE\"/p" "${RUNNER}" | sed '1s/^awk //' | sed '$s/ "\$TRACE".*$//')
check_trace() { printf '%s\n' "$1" | eval "awk ${awk_program}"; }

cross_thread='123 openat(AT_FDCWD, "/dev/cedar_dev", O_RDWR) = 7</dev/cedar_dev<char 150:0>>
124 ioctl(7</dev/cedar_dev<char 150:0>>, 0x100, 0) = 0'
check_trace "${cross_thread}"

unrelated_target='123 openat(AT_FDCWD, "/dev/cedar_dev", O_RDWR) = 7</dev/cedar_dev<char 150:0>>
124 ioctl(7</dev/tty0<char 4:0>>, 0x100, 0) = 0'
if check_trace "${unrelated_target}"; then echo 'FAIL: accepted unrelated ioctl target' >&2; exit 1; fi

after_close='123 openat(AT_FDCWD, "/dev/cedar_dev", O_RDWR) = 7</dev/cedar_dev<char 150:0>>
123 close(7</dev/cedar_dev<char 150:0>>) = 0
123 ioctl(7</dev/cedar_dev<char 150:0>>, 0x100, 0) = 0'
if check_trace "${after_close}"; then echo 'FAIL: accepted ioctl after close' >&2; exit 1; fi

echo 'PASS: Cedar spike harness is preserved but isolated from image builds'
