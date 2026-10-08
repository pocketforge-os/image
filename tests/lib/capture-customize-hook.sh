#!/usr/bin/env bash
# Sourced by tests.  Capture the customize hook exactly as the production
# scripts/build-rootfs.sh generates it and hands it to mmdebstrap.
#
# Tests that assemble hook fragments from build-rootfs.sh source text can
# define functions the generated hook never has: that is how the hook's
# undefined is_a133_open_7x_gpu_device call passed its tests (tsp-mc9m.41.986).
# This helper runs the real builder over a minimal open-GPU fixture until its
# mmdebstrap call.  A fake mmdebstrap copies the generated --customize-hook
# script to the requested path, records the hook command beside it, and stops
# the build before any network or chroot work.

# capture_customize_hook REPO_DIR FIXTURE_DIR OUT_HOOK
#   REPO_DIR    image repository whose scripts/build-rootfs.sh generates the hook
#   FIXTURE_DIR empty scratch directory for the fixture inputs
#   OUT_HOOK    destination for the generated hook; OUT_HOOK.cmd receives the
#               --customize-hook command line mmdebstrap would run
capture_customize_hook() {
    local repo_dir="$1"
    local fixture="$2"
    local out_hook="$3"
    local release="${fixture}/kernel/7.0.0-pocketforge"
    local status

    mkdir -p "${fixture}/bin" "${fixture}/out" "${fixture}/wpa" \
        "${fixture}/blobs/sunxi/a133/wifi-firmware" \
        "${fixture}/mesa/usr/local/lib/gbm" "${release}"
    : > "${fixture}/blobs/sunxi/a133/wifi-firmware/fw_xr829.bin"
    : > "${fixture}/blobs/sunxi/a133/wifi-firmware/fw_xr829_bt.bin"
    for library in libEGL_mesa.so.0 libgbm.so gbm/dri_gbm.so; do
        : > "${fixture}/mesa/usr/local/lib/${library}"
    done
    : > "${fixture}/mesa/pocketforge-open-gpu-stack.deb"
    : > "${release}/modules.builtin"
    : > "${release}/powervr.ko"
    : > "${fixture}/wpa/wpa_supplicant"

    cat > "${fixture}/bin/qemu-aarch64-static" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "${fixture}/bin/mmdebstrap" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
hook_command=""
for arg in "$@"; do
    case "${arg}" in
        --customize-hook=*) hook_command="${arg#--customize-hook=}" ;;
    esac
done
[ -n "${hook_command}" ] || { echo 'fake mmdebstrap: no --customize-hook' >&2; exit 1; }
hook_path=""
for word in ${hook_command}; do
    case "${word}" in
        */customize-hook.sh) hook_path="${word}" ;;
    esac
done
[ -f "${hook_path}" ] || { echo "fake mmdebstrap: hook not found in: ${hook_command}" >&2; exit 1; }
cp "${hook_path}" "${PF_TEST_CUSTOMIZE_HOOK_CAPTURE}"
printf '%s\n' "${hook_command}" > "${PF_TEST_CUSTOMIZE_HOOK_CAPTURE}.cmd"
exit 97
EOF
    chmod 0755 "${fixture}/bin/qemu-aarch64-static" "${fixture}/bin/mmdebstrap"

    status=0
    PATH="${fixture}/bin:${PATH}" \
    PF_TEST_CUSTOMIZE_HOOK_CAPTURE="${out_hook}" \
    SRC_DIR="${repo_dir}" BLOBS_DIR="${fixture}/blobs" \
    GPU_UM_MESA_DIR="${fixture}/mesa" WPA_DIR="${fixture}/wpa" \
    KERNEL_TSP_DIR="${fixture}/kernel" GPU_KM_TSP_DIR="${fixture}/unused-gpu" \
    OUT_DIR="${fixture}/out" SOURCE_DATE_EPOCH=1700000000 \
    PF_DEVICE_ID=a133-open-7x-gpu PF_KERNEL_REPO=kernel-sunxi-7.x PF_GPU_MODEL=open \
    PF_GPU_KM_MODEL=in-tree-7.x PF_KERNEL_REQUIRED_MODULES=powervr \
    PF_DISPLAY_PIPELINE=none \
        bash "${repo_dir}/scripts/build-rootfs.sh" --variant dev \
        > "${fixture}/build-rootfs.out" 2> "${fixture}/build-rootfs.err" \
        || status=$?
    if [ "${status}" -ne 97 ] || [ ! -s "${out_hook}" ]; then
        echo "FAIL: build-rootfs.sh did not reach mmdebstrap with a customize hook (status ${status})" >&2
        tail -n 20 "${fixture}/build-rootfs.err" >&2
        return 1
    fi
}
