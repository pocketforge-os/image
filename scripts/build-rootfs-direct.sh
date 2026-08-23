#!/usr/bin/env bash
# Supply deterministic provenance for the legacy build-sd-image -> build-rootfs path.
set -euo pipefail

SRC_DIR="${SRC_DIR:-/work/src}"
BLOBS_DIR="${BLOBS_DIR:-/work/blobs}"
LIBSDL3_DIR="${LIBSDL3_DIR:-/work/libsdl3}"
WPA_DIR="${WPA_DIR:-/work/wpa}"
RUNTIME_DIR="${RUNTIME_DIR:-/work/runtime}"
KERNEL_TSP_DIR="${KERNEL_TSP_DIR:-/work/kernel-tsp}"
GPU_KM_TSP_DIR="${GPU_KM_TSP_DIR:-/work/gpu-km-tsp}"
ROOTFS_BUILDER="${ROOTFS_BUILDER:-${SRC_DIR}/scripts/build-rootfs.sh}"

variant=dev
next_is_variant=0
for arg in "$@"; do
    if [ "${next_is_variant}" = 1 ]; then
        variant="${arg}"
        next_is_variant=0
    elif [ "${arg}" = --variant ]; then
        next_is_variant=1
    fi
done
[ "${next_is_variant}" = 0 ] || { echo "build-rootfs-direct: --variant requires a value" >&2; exit 2; }

# Hash names, symlink targets, and regular-file contents in a stable order. The direct
# build consumes staged trees rather than platform.lock refs, so their bytes are the
# resolved input identity available at this interface.
tree_identity() {
    local path="$1"
    [ -e "${path}" ] || { echo "build-rootfs-direct: required input is absent: ${path}" >&2; return 1; }
    (
        cd "${path}"
        find . -path './.git' -prune -o \( -type f -o -type l \) -print |
            LC_ALL=C sort | while IFS= read -r item; do
            if [ -L "${item}" ]; then
                printf 'l %s %s\n' "${item}" "$(readlink "${item}")"
            else
                printf 'f %s ' "${item}"
                sha256sum "${item}" | cut -d' ' -f1
            fi
        done
    ) | sha256sum | cut -d' ' -f1
}

PF_DEVICE_ID="trimui-smart-pro-a133"
PF_VARIANT="${variant}"
PF_IMAGE_SHA="$(tree_identity "${SRC_DIR}")"
PF_KERNEL_SHA="$(tree_identity "${KERNEL_TSP_DIR}")"
PF_GPU_SHA="$(tree_identity "${GPU_KM_TSP_DIR}")"
PF_LIBSDL3_SHA="$(tree_identity "${LIBSDL3_DIR}")"
PF_WPA_SHA="$(tree_identity "${WPA_DIR}")"
PF_RUNTIME_SHA="$(tree_identity "${RUNTIME_DIR}")"
PF_BLOBS_SHA="$(tree_identity "${BLOBS_DIR}")"
# The direct path receives one resolved blobs tree, not separate manifest/CAR pins.
# Reusing its byte identity keeps the canonical generator complete and deterministic.
PF_VENDOR_MANIFEST_SHA="${PF_BLOBS_SHA}"
PF_CAR_SHA256="${PF_BLOBS_SHA}"
PF_UBOOT_SHA=""
PF_TFA_SHA=""
export PF_DEVICE_ID PF_VARIANT PF_IMAGE_SHA PF_KERNEL_SHA PF_GPU_SHA
export PF_LIBSDL3_SHA PF_WPA_SHA PF_RUNTIME_SHA PF_BLOBS_SHA
export PF_VENDOR_MANIFEST_SHA PF_CAR_SHA256 PF_UBOOT_SHA PF_TFA_SHA

exec bash "${ROOTFS_BUILDER}" "$@"
