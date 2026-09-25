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

for package in cpufrequtils iperf3; do
    packages "${MAINLINE_PACKAGES}" | grep -Fxq "${package}"
    if packages "${SHARED_PACKAGES}" | grep -Fxq "${package}"; then
        echo "FAIL: ${package} leaked into the shipping rootfs package list" >&2
        exit 1
    fi
done

packages "${MAINLINE_DEV_PACKAGES}" | grep -Fxq libdrm-tests
for shared_list in "${SHARED_PACKAGES}" "${SHARED_DEV_PACKAGES}" "${MAINLINE_PACKAGES}"; do
    if packages "${shared_list}" | grep -Fxq libdrm-tests; then
        echo "FAIL: libdrm-tests leaked into ${shared_list}" >&2
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

echo "PASS: mainline packages are scoped correctly, including open+dev-only libdrm-tests"
