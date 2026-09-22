#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
dockerfile="$root/build/Dockerfile.pf"
rootfs="$root/scripts/build-rootfs.sh"
initrd="$root/boards/tsp/initrd/build-initrd.sh"
sd="$root/scripts/build-sd-image.sh"

for stage in gpu-km gpu-fw gpu-um-mesa recovery launcher; do
    grep -F "AS ${stage}-none" "$dockerfile" >/dev/null
done
grep -F "gpu-km DEFERRED for device=%s (gpu_model=%s; in-tree open DRM KM)" "$dockerfile" >/dev/null
grep -F 'FROM gpu-um-mesa-${PF_GPU_MODEL} AS gpu-um-mesa' "$dockerfile" >/dev/null
grep -F 'FROM recovery-${PF_GPU_MODEL} AS recovery' "$dockerfile" >/dev/null
grep -F 'FROM launcher-${PF_GPU_MODEL} AS launcher' "$dockerfile" >/dev/null
echo 'PASS: none model has prunable NOT-SHIPPED GPU/userland/recovery/launcher stages'

grep -F 'ddk|open|none)' "$initrd" >/dev/null
grep -F 'gpu_model=none initramfs contains no GPU module or firmware artifact' "$initrd" >/dev/null
grep -F '[ "${PF_GPU_MODEL}" = "ddk" ]; then' "$initrd" >/dev/null
grep -F 'ddk|open|none)' "$sd" >/dev/null
echo 'PASS: none model is accepted and initramfs GPU artifacts fail closed'

grep -F 'gpu_model=none: full ${KREL} kernel module tree installed' "$rootfs" >/dev/null
grep -F 'depmod "${KREL}"' "$rootfs" >/dev/null
grep -F 'gpu_model=none rootfs contains no GPU module, firmware, loader, PowerVR userspace, launcher, or recovery artifact' "$rootfs" >/dev/null
echo 'PASS: none rootfs installs the discovered kernel release and rejects GPU artifacts'

# Existing models remain explicit branches, rather than falling through the new mode.
grep -F 'if [ "${PF_GPU_MODEL:-ddk}" = "ddk" ]; then' "$rootfs" >/dev/null
grep -F 'elif [ "${PF_GPU_MODEL:-ddk}" = "open" ]; then' "$rootfs" >/dev/null
echo 'PASS: ddk and open model selectors remain explicit and none is additive'
