#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILDER="${ROOT}/scripts/build-rootfs.sh"
MAINLINE_PACKAGES="${ROOT}/rootfs-packages-mainline.txt"
MAINLINE_DEV_PACKAGES="${ROOT}/rootfs-packages-mainline-dev.txt"
SHARED_PACKAGES="${ROOT}/rootfs-packages.txt"
SHARED_DEV_PACKAGES="${ROOT}/rootfs-packages-dev.txt"

packages() {
    grep -v '^\s*#' "$1" | grep -v '^\s*$'
}

for package in cpufrequtils i2c-tools iperf3 usbutils; do
    packages "${MAINLINE_PACKAGES}" | grep -Fxq "${package}"
    if packages "${SHARED_PACKAGES}" | grep -Fxq "${package}"; then
        echo "FAIL: ${package} leaked into the shipping rootfs package list" >&2
        exit 1
    fi
done

packages "${MAINLINE_DEV_PACKAGES}" | grep -Fxq libdrm-tests
for package in \
    v4l-utils \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-bad; do
    count="$(packages "${MAINLINE_DEV_PACKAGES}" | awk -v expected="${package}" \
        '$0 == expected { count++ } END { print count + 0 }')"
    if [ "${count}" -ne 1 ]; then
        echo "FAIL: expected ${package} exactly once in ${MAINLINE_DEV_PACKAGES}, found ${count}" >&2
        exit 1
    fi
done
for shared_list in "${SHARED_PACKAGES}" "${SHARED_DEV_PACKAGES}" "${MAINLINE_PACKAGES}"; do
    for package in \
        libdrm-tests \
        v4l-utils \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-bad; do
        if packages "${shared_list}" | grep -Fxq "${package}"; then
            echo "FAIL: ${package} leaked into ${shared_list}" >&2
            exit 1
        fi
    done
done

# evtest reads current ABS axis values (EVIOCGABS, via its header) so pf-gamepad
# decoder output can be proven read-only, without python3 (bead tsp-mc9m.41.923.53).
# Added to the general A133 dev-only list the same way i2c-tools was
# (image#59 / tsp-ozbp.3): dev variant only, independent of GPU model — never
# shipped on a release image.
packages "${SHARED_DEV_PACKAGES}" | grep -Fxq evtest
for shared_list in "${SHARED_PACKAGES}" "${MAINLINE_PACKAGES}" "${MAINLINE_DEV_PACKAGES}"; do
    if packages "${shared_list}" | grep -Fxq evtest; then
        echo "FAIL: evtest leaked into ${shared_list}" >&2
        exit 1
    fi
done

# WiFi association remains supplied by the shared Debian runtime package and
# the pinned PocketForge wpa stage; it must be available to every A133 variant.
packages "${SHARED_PACKAGES}" | grep -Fxq wpasupplicant
# These are intentionally literal shell fragments in the builder.
# shellcheck disable=SC2016
grep -Fq '[ -f "${WPA_DIR}/wpa_supplicant" ]' "${BUILDER}"

# Assert the extra list is selected only by the mainline/open model boundary.
# shellcheck disable=SC2016
grep -Fq 'if [ "${PF_GPU_MODEL}" = "open" ]; then' "${BUILDER}"
# shellcheck disable=SC2016
grep -Fq 'PKG_MAINLINE_FILE="${SRC_DIR}/rootfs-packages-mainline.txt"' "${BUILDER}"
# shellcheck disable=SC2016
grep -Fq 'PKG_LIST="${PKG_LIST},${MAINLINE_PKGS}"' "${BUILDER}"
# shellcheck disable=SC2016
grep -Fq 'if [ "${PF_GPU_MODEL}" = "open" ] && [ "${VARIANT}" = "dev" ]; then' "${BUILDER}"
# shellcheck disable=SC2016
grep -Fq 'PKG_LIST="${PKG_LIST},${MAINLINE_DEV_PKGS}"' "${BUILDER}"

echo "PASS: open A133 packages are scoped correctly, including open+dev-only libdrm-tests and Cedrus tooling"
