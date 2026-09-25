#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rootfs_script="${root}/scripts/build-rootfs.sh"
initrd_script="${root}/boards/tsp/initrd/build-initrd.sh"
sd_script="${root}/scripts/build-sd-image.sh"
dockerfile="${root}/build/Dockerfile.pf"
scratch="$(mktemp -d)"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT

mkdir -p "${scratch}/bin" \
    "${scratch}/blobs/sunxi/a133/wifi-firmware" \
    "${scratch}/mesa/usr/local/lib/gbm" \
    "${scratch}/out"
cat > "${scratch}/bin/qemu-aarch64-static" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${scratch}/bin/qemu-aarch64-static"
for firmware in fw_xr829.bin fw_xr829_bt.bin; do
    : > "${scratch}/blobs/sunxi/a133/wifi-firmware/${firmware}"
done
for library in libEGL.so libGLESv2.so libgbm.so; do
    : > "${scratch}/mesa/usr/local/lib/${library}"
done
: > "${scratch}/mesa/usr/local/lib/gbm/dri_gbm.so"

populate_modules() {
    local release_dir="$1"
    shift
    find "${release_dir}" -mindepth 1 -delete 2>/dev/null || true
    mkdir -p "${release_dir}"
    : > "${release_dir}/modules.builtin"
    local module
    for module in "$@"; do
        : > "${release_dir}/${module}.ko"
    done
}

run_rootfs_preflight() {
    local device_id="$1"
    local km_model="$2"
    local required_modules="$3"
    local kernel_dir="$4"
    local label="$5"
    if PATH="${scratch}/bin:${PATH}" \
        SRC_DIR="${root}" BLOBS_DIR="${scratch}/blobs" \
        GPU_UM_MESA_DIR="${scratch}/mesa" WPA_DIR="${scratch}/missing-wpa" \
        KERNEL_TSP_DIR="${kernel_dir}" GPU_KM_TSP_DIR="${scratch}/unused-gpu" \
        OUT_DIR="${scratch}/out" PF_GPU_MODEL=open \
        PF_GPU_KM_MODEL="${km_model}" PF_KERNEL_REQUIRED_MODULES="${required_modules}" \
        PF_DEVICE_ID="${device_id}" PF_DISPLAY_PIPELINE=none \
        bash "${rootfs_script}" >"${scratch}/${label}.out" 2>"${scratch}/${label}.err"; then
        echo "FAIL: rootfs fixture ${label} unexpectedly completed" >&2
        exit 1
    fi
}

kernel6="${scratch}/kernel6"
release6="${kernel6}/6.18.0-pocketforge"
modules6=(powervr videobuf2-dma-contig sun6i-csi xradio)
populate_modules "${release6}" "${modules6[@]}"
run_rootfs_preflight a133-open in-tree-6.x \
    'powervr videobuf2-dma-contig sun6i-csi xradio' "${kernel6}" rootfs-6x
grep -F 'required kernel module xradio (module)' "${scratch}/rootfs-6x.out" >/dev/null
grep -F 'owned wpa_supplicant not found' "${scratch}/rootfs-6x.err" >/dev/null

for missing in "${modules6[@]}"; do
    populate_modules "${release6}" "${modules6[@]}"
    find "${release6}" -name "${missing}.ko" -delete
    run_rootfs_preflight a133-open in-tree-6.x \
        'powervr videobuf2-dma-contig sun6i-csi xradio' "${kernel6}" "rootfs-6x-missing-${missing}"
    grep -F "${missing}.ko not found as a module" \
        "${scratch}/rootfs-6x-missing-${missing}.err" >/dev/null
done

kernel7="${scratch}/kernel7"
release7="${kernel7}/7.0.0-pocketforge"
populate_modules "${release7}" powervr
run_rootfs_preflight a133-open-7x-gpu in-tree-7.x powervr "${kernel7}" rootfs-7x
grep -F 'required kernel module powervr (module)' "${scratch}/rootfs-7x.out" >/dev/null
grep -F 'owned wpa_supplicant not found' "${scratch}/rootfs-7x.err" >/dev/null
if grep -Eq 'videobuf2|sun6i-csi|xradio' "${scratch}/rootfs-7x.out"; then
    echo 'FAIL: 7.x powervr-only rootfs preflight inferred an undeclared module' >&2
    exit 1
fi

populate_modules "${release7}" powervr
find "${release7}" -name powervr.ko -delete
run_rootfs_preflight a133-open-7x-gpu in-tree-7.x powervr "${kernel7}" rootfs-7x-missing
grep -F 'powervr.ko not found as a module' "${scratch}/rootfs-7x-missing.err" >/dev/null

run_rootfs_preflight a133-open-7x-gpu in-tree-7.x '' "${kernel7}" rootfs-empty
grep -F 'PF_KERNEL_REQUIRED_MODULES is required for gpu_model=open' \
    "${scratch}/rootfs-empty.err" >/dev/null
run_rootfs_preflight a133-open-7x-gpu in-tree-7.x 'powervr powervr' "${kernel7}" rootfs-duplicate
grep -F "duplicate required kernel module 'powervr'" "${scratch}/rootfs-duplicate.err" >/dev/null
run_rootfs_preflight a133-open-7x-gpu in-tree-7.x 'powervr bad/module' "${kernel7}" rootfs-invalid
grep -F "invalid required kernel module 'bad/module'" "${scratch}/rootfs-invalid.err" >/dev/null

# Exercise the emitted WiFi autoload block. An undeclared WiFi module uses the
# explicit absent form and must not acquire a module default in the customize hook.
wifi_block="${scratch}/wifi-block.sh"
sed -n '/^install -d "${ROOTFS}\/etc\/modules-load.d"$/,/^# XR829 WiFi MAC address persistence directory\.$/p' \
    "${rootfs_script}" | sed '$d' > "${wifi_block}"
wifi_root="${scratch}/wifi-root"
mkdir -p "${wifi_root}/lib/modules/7.0.0-pocketforge" "${wifi_root}/etc"
printf 'alias of:N*T*Cimg,img-rogue powervr\n' \
    > "${wifi_root}/lib/modules/7.0.0-pocketforge/modules.alias"
ROOTFS="${wifi_root}" KREL=7.0.0-pocketforge PF_GPU_MODEL=open \
    KERNEL_WIFI_FORM=absent KERNEL_POWERVR_FORM=module \
    bash "${wifi_block}"
[ ! -e "${wifi_root}/etc/modules-load.d/pocketforge-wifi.conf" ]
ROOTFS="${wifi_root}" KREL=7.0.0-pocketforge PF_GPU_MODEL=open \
    KERNEL_WIFI_FORM=module KERNEL_POWERVR_FORM=module \
    bash "${wifi_block}"
grep -Fx xradio "${wifi_root}/etc/modules-load.d/pocketforge-wifi.conf" >/dev/null
grep -F 'KERNEL_WIFI_FORM=${KERNEL_WIFI_FORM:-absent}' "${rootfs_script}" >/dev/null

# Execute the exact customize-hook helper that owns the source-visible 7.x
# admission parameter. Only the named profile may receive the file.
option_helper="${scratch}/option-helper.sh"
sed -n '/^install_open_gpu_module_options() {$/,/^}$/p' "${rootfs_script}" > "${option_helper}"
for tuple in \
    'a133-open open in-tree-6.x' \
    'a133-open-7x none none' \
    'a133 ddk out-of-tree-ddk' \
    'a523 ddk out-of-tree-ddk'; do
    read -r device_id gpu_model gpu_km_model <<< "${tuple}"
    option_root="${scratch}/option-${device_id}"
    mkdir -p "${option_root}"
    ROOTFS="${option_root}" PF_DEVICE_ID="${device_id}" PF_GPU_MODEL="${gpu_model}" \
        PF_GPU_KM_MODEL="${gpu_km_model}" \
        bash -c 'source "$1"; install_open_gpu_module_options' _ "${option_helper}"
    [ ! -e "${option_root}/etc/modprobe.d/powervr-a133-open-7x-gpu.conf" ]
done
option_root="${scratch}/option-a133-open-7x-gpu"
mkdir -p "${option_root}"
ROOTFS="${option_root}" PF_DEVICE_ID=a133-open-7x-gpu PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-7.x \
    bash -c 'source "$1"; install_open_gpu_module_options' _ "${option_helper}"
[ "$(cat "${option_root}/etc/modprobe.d/powervr-a133-open-7x-gpu.conf")" = \
    'options powervr exp_hw_support=1' ]
if ROOTFS="${scratch}/wrong-option" PF_DEVICE_ID=a133-open-7x-gpu \
    PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-6.x \
    bash -c 'source "$1"; install_open_gpu_module_options' _ "${option_helper}" \
    2>"${scratch}/wrong-option.err"; then
    echo 'FAIL: experimental PowerVR option accepted a non-7.x contract' >&2
    exit 1
fi
grep -F 'without its exact open/in-tree-7.x contract' "${scratch}/wrong-option.err" >/dev/null

# Run the open half of the real Dockerfile GPUKM heredoc with a fake objcopy
# over a module fixture. This checks exact repo/ref/SHA, one release directory,
# and module vermagic without invoking Docker or compiling a kernel.
gpu_stage="${scratch}/gpu-stage"
mkdir -p "${gpu_stage}/work/kernel/include/config" \
    "${gpu_stage}/work/kernel-modules/7.0.0-pocketforge/kernel/drivers/gpu/drm/imagination" \
    "${gpu_stage}/out" "${gpu_stage}/bin"
printf '7.0.0-pocketforge\n' > "${gpu_stage}/work/kernel/include/config/kernel.release"
cat > "${gpu_stage}/work/kernel-provenance" <<'EOF'
kernel.release=7.0.0-pocketforge
vermagic=7.0.0-pocketforge SMP preempt
EOF
: > "${gpu_stage}/work/kernel-modules/7.0.0-pocketforge/kernel/drivers/gpu/drm/imagination/powervr.ko"
cat > "${gpu_stage}/bin/aarch64-none-linux-gnu-objcopy" <<'EOF'
#!/bin/sh
printf 'vermagic=%s\0' "${FAKE_VERMAGIC}"
EOF
chmod +x "${gpu_stage}/bin/aarch64-none-linux-gnu-objcopy"
sed -n "/^RUN <<'GPUKM'$/,/^GPUKM$/p" "${dockerfile}" | sed '1d;$d' \
    | sed "s#/work#${gpu_stage}/work#g; s#/out#${gpu_stage}/out#g" \
    > "${gpu_stage}/run.sh"

run_gpu_stage() {
    local km_sha="$1"
    local kernel_sha="$2"
    local vermagic="$3"
    local label="$4"
    PATH="${gpu_stage}/bin:${PATH}" FAKE_VERMAGIC="${vermagic}" \
        PF_DEVICE_ID=a133-open-7x-gpu PF_GPU_MODEL=open \
        PF_GPU_KM_MODEL=in-tree-7.x PF_GPU_KM_REPO=kernel-sunxi-7.x \
        PF_GPU_KM_REF=device/a133 PF_GPU_KM_SHA="${km_sha}" PF_GPU_MODULES=powervr.ko \
        PF_KERNEL_REPO=kernel-sunxi-7.x PF_KERNEL_REF=device/a133 PF_KERNEL_SHA="${kernel_sha}" \
        bash "${gpu_stage}/run.sh" >"${scratch}/${label}.out" 2>"${scratch}/${label}.err"
}

contract_sha=3e0a7373bddd5a801f5f07a71d02cf4d6e97e99d
run_gpu_stage "${contract_sha}" "${contract_sha}" '7.0.0-pocketforge SMP preempt' gpu-stage-ok
test -f "${gpu_stage}/out/modules/powervr.ko"
grep -F "gpu-km in-tree-7.x kernel-sunxi-7.x@${contract_sha} ref=device/a133" \
    "${gpu_stage}/out/modules/.pf-gpu-provenance" >/dev/null

if run_gpu_stage "${contract_sha}" deadbeef '7.0.0-pocketforge SMP preempt' gpu-stage-sha; then
    echo 'FAIL: in-tree KM stage accepted a kernel SHA mismatch' >&2
    exit 1
fi
grep -F 'in-tree SHA' "${scratch}/gpu-stage-sha.out" >/dev/null
if run_gpu_stage "${contract_sha}" "${contract_sha}" '7.0.0-wrong SMP preempt' gpu-stage-vermagic; then
    echo 'FAIL: in-tree KM stage accepted a vermagic mismatch' >&2
    exit 1
fi
grep -F "powervr.ko vermagic '7.0.0-wrong SMP preempt'" \
    "${scratch}/gpu-stage-vermagic.out" >/dev/null
find "${gpu_stage}/work/kernel-modules" -name powervr.ko -delete
if run_gpu_stage "${contract_sha}" "${contract_sha}" '7.0.0-pocketforge SMP preempt' gpu-stage-missing; then
    echo 'FAIL: in-tree KM stage accepted a missing declared module' >&2
    exit 1
fi
grep -F 'expected exactly one powervr.ko' "${scratch}/gpu-stage-missing.out" >/dev/null

# The SD path must reject absent facts before looking for build artifacts and
# must forward both facts as single arguments to the initrd interface.
if PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-7.x PF_KERNEL_REQUIRED_MODULES='' \
    KERNEL_TSP_DIR="${scratch}/missing-kernel" GPU_KM_TSP_DIR="${scratch}/missing-gpu" \
    bash "${sd_script}" --boot-only >"${scratch}/sd-empty.out" 2>"${scratch}/sd-empty.err"; then
    echo 'FAIL: SD assembly accepted an empty open required-module fact' >&2
    exit 1
fi
grep -F 'PF_KERNEL_REQUIRED_MODULES is required for gpu_model=open' "${scratch}/sd-empty.err" >/dev/null
grep -F 'INITRD_ARGS+=(--gpu-km-model "${PF_GPU_KM_MODEL}")' "${sd_script}" >/dev/null
grep -F 'INITRD_ARGS+=(--kernel-required-modules "${PF_KERNEL_REQUIRED_MODULES}")' "${sd_script}" >/dev/null
grep -F 'MODULES=""' "${initrd_script}" >/dev/null

echo 'open-module-contract=PASS'
