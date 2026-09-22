#!/bin/sh
set -eu

root=${1:?usage: verify-no-gpu-artifacts.sh ROOT [LABEL]}
label=${2:-tree}

[ -d "$root" ] || { echo "FATAL: gpu_model=none verification root missing: $root" >&2; exit 2; }

found=$(
    find "$root" \
        \( -type d \( -path '*/lib/firmware/powervr' -o -path '*/usr/lib/pvr-rogue' -o -path '*/vulkan/icd.d' \) \) -o \
        \( -type f \( \
            -name 'pvrsrvkm.ko' -o -name 'dc_sunxi.ko' -o -name 'powervr.ko' -o \
            -name 'rgx.fw*' -o -name 'rgx.sh*' -o -name 'rogue*.fw' -o \
            -name 'libvulkan.so*' -o -name 'libvulkan_powervr*' -o \
            -name 'libsrv_um.so*' -o -name 'libIMGegl.so*' -o \
            -name 'libSDL3-pocketforge.so*' -o -name 'LICENSE.powervr' -o \
            -name 'pf-shell' -o -name 'pocketforge-recovery-entry' \
        \) \) -print -quit
)

if [ -n "$found" ]; then
    echo "FATAL: GPU/display artifact reached gpu_model=none ${label}: ${found#"$root"/}" >&2
    exit 1
fi

echo "PASS: gpu_model=none ${label} contains no GPU module, firmware, loader, PowerVR userspace, SDL, launcher, or recovery artifact"
