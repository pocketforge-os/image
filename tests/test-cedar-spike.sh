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

grep -Fq 'testsrc2=size=1280x720:rate=30:duration=30' "${BUILDER}"
grep -Fq "[ \"\${CEDAR_FRAMES}\" = \"900\" ]" "${BUILDER}"
grep -Fq 'sudo /usr/lib/pocketforge/cedar-spike.sh' "${DOC}"
grep -Fq 'libcedrus/archive/9b243c430a4d445b3853262552ad563fa9ea325d.tar.gz' "${DOCKERFILE}"
grep -Fq 'libvdpau-sunxi/archive/ebdf7844efbb997a1e858600ae76c90985ea865d.tar.gz' "${DOCKERFILE}"
grep -Fq 'sha256:a2c531db5f4ce04e896eab0e5553422bb3d560fb554b049ae2cc1764e8427975' "${DOCKERFILE}"
grep -Fq 'sha256:9adb541d841d8a18d7075d6619a070aa34893a7569b4ad17b41015e0bbccbebb' "${DOCKERFILE}"
grep -Fq 'patch -d /work/libvdpau-sunxi -p1 < /work/cedar-headless.patch' "${DOCKERFILE}"
grep -Fq 'cedar-headless-test.c -o /out/usr/bin/cedar-headless-test' "${DOCKERFILE}"
grep -Fq 'FROM cedar-vdpau AS cedar-sun50iw10p1-dev' "${DOCKERFILE}"
grep -Fq 'FROM cedar-disabled AS cedar-sun50iw10p1-release' "${DOCKERFILE}"
grep -Fq 'FROM cedar-disabled AS cedar-sun55iw3-dev' "${DOCKERFILE}"
grep -Fq 'FROM cedar-disabled AS cedar-sun55iw3-release' "${DOCKERFILE}"
# shellcheck disable=SC2016 # Assert literal Dockerfile build-arg interpolation.
grep -Fq 'FROM cedar-${PF_SOC}-${PF_VARIANT} AS cedar' "${DOCKERFILE}"
grep -Fq 'COPY --from=cedar /out' "${DOCKERFILE}"
if grep -Fq 'COPY --from=cedar-vdpau /out' "${DOCKERFILE}"; then
    echo 'FAIL: rootfs directly depends on the networked Cedar build stage' >&2
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

echo 'PASS: Cedar spike is dev-only, 900-frame, headless direct-VE, and ioctl-evidenced'
