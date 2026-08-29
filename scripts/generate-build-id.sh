#!/usr/bin/env bash
# Emit the image's deterministic, human-readable resolved-input identity.
set -euo pipefail

required=(
    PF_DEVICE_ID PF_VARIANT PF_IMAGE_SHA PF_KERNEL_SHA PF_GPU_SHA
    PF_LIBSDL3_SHA PF_WPA_SHA PF_RUNTIME_SHA PF_LAUNCHER_SHA PF_BLOBS_SHA
    PF_VENDOR_MANIFEST_SHA PF_CAR_SHA256 SOURCE_DATE_EPOCH
)
for name in "${required[@]}"; do
    [ -n "${!name:-}" ] || { echo "generate-build-id: ${name} is required" >&2; exit 1; }
done

# Names, ordering, and separators are fixed so this serialization is unambiguous.
# Bootchain SHAs are empty for devices whose platform profile has no source bootchain.
identity="$({
    printf 'device=%s\n' "${PF_DEVICE_ID}"
    printf 'variant=%s\n' "${PF_VARIANT}"
    printf 'source_date_epoch=%s\n' "${SOURCE_DATE_EPOCH}"
    printf 'odyssey_capture=%s\n' "${PF_ODYSSEY_CAPTURE:-}"
    printf 'image=%s\n' "${PF_IMAGE_SHA}"
    printf 'kernel=%s\n' "${PF_KERNEL_SHA}"
    printf 'gpu=%s\n' "${PF_GPU_SHA}"
    printf 'sdl=%s\n' "${PF_LIBSDL3_SHA}"
    printf 'wpa=%s\n' "${PF_WPA_SHA}"
    printf 'runtime=%s\n' "${PF_RUNTIME_SHA}"
    printf 'launcher=%s\n' "${PF_LAUNCHER_SHA}"
    printf 'blobs=%s\n' "${PF_BLOBS_SHA}"
    printf 'vendor_manifest=%s\n' "${PF_VENDOR_MANIFEST_SHA}"
    printf 'car=%s\n' "${PF_CAR_SHA256}"
    printf 'uboot=%s\n' "${PF_UBOOT_SHA:-}"
    printf 'tfa=%s\n' "${PF_TFA_SHA:-}"
} | sha256sum | cut -d' ' -f1)"

printf 'device=%s build=%.12s\n' "${PF_DEVICE_ID}" "${identity}"
