#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/kernel-module-form.sh
source "${repo_dir}/scripts/kernel-module-form.sh"

scratch="$(mktemp -d)"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT
release_dir="${scratch}/lib/modules/6.18.0-pocketforge"
mkdir -p "${release_dir}/kernel/drivers/media/common/videobuf2"
builtin_file="${release_dir}/modules.builtin"

module_path="${release_dir}/kernel/drivers/media/common/videobuf2/videobuf2-dma-contig.ko"
: > "${module_path}"
IFS=$'\t' read -r form evidence < <(kernel_module_form "${release_dir}" videobuf2-dma-contig)
[ "${form}" = module ] && [ "${evidence}" = "${module_path}" ]

find "${release_dir}" -name 'videobuf2-dma-contig.ko' -delete
printf 'kernel/drivers/media/common/videobuf2/videobuf2-dma-contig.ko\n' > "${builtin_file}"
IFS=$'\t' read -r form evidence < <(kernel_module_form "${release_dir}" videobuf2-dma-contig)
[ "${form}" = builtin ] && [ "${evidence}" = "${builtin_file}" ]

: > "${builtin_file}"
if kernel_module_form "${release_dir}" videobuf2-dma-contig 2>"${scratch}/missing.err"; then
    echo 'FAIL: missing dependency was accepted' >&2
    exit 1
fi
grep -F "videobuf2-dma-contig.ko not found as a module under ${release_dir}" "${scratch}/missing.err" >/dev/null
grep -F "or as a built-in in ${builtin_file}" "${scratch}/missing.err" >/dev/null

# Exercise the real assemble-stage initrd input check. Open kernels need not
# provide a loadable VB2 object because the initrd omits it and the rootfs uses
# the built-in implementation. The deliberately absent busybox stops the build
# immediately after its input checks, keeping this regression hermetic.
assemble_kernel_dir="${scratch}/assemble-kernel"
assemble_release_dir="${assemble_kernel_dir}/lib/modules/6.18.0-pocketforge"
mkdir -p "${assemble_release_dir}"
printf 'kernel/drivers/media/common/videobuf2/videobuf2-dma-contig.ko\n' \
    > "${assemble_release_dir}/modules.builtin"
if PF_GPU_MODEL=open BUSYBOX_ARM64="${scratch}/absent-busybox" \
    bash "${repo_dir}/boards/tsp/initrd/build-initrd.sh" \
        --src "${repo_dir}" \
        --kernel-tsp-dir "${assemble_kernel_dir}" \
        --gpu-km-dir "${scratch}/unused-gpu-km" \
        --gpu-km-model in-tree-6.x \
        --kernel-required-modules "powervr videobuf2-dma-contig sun6i-csi xradio" \
        --out "${scratch}/unused-initrd.gz" \
        >"${scratch}/assemble.out" 2>"${scratch}/assemble.err"; then
    echo 'FAIL: assemble-stage fixture unexpectedly built an initrd' >&2
    exit 1
fi
grep -F "videobuf2 (builtin): ${assemble_release_dir}/modules.builtin" \
    "${scratch}/assemble.out" >/dev/null
grep -F "FATAL: baked busybox not found at ${scratch}/absent-busybox" \
    "${scratch}/assemble.err" >/dev/null

# The 7.x contract has no early module consumer. Its powervr-only inventory
# must therefore bypass the vestigial videobuf2 check and reach the same empty
# initrd-module path.
assemble_7x_kernel_dir="${scratch}/assemble-7x-kernel"
mkdir -p "${assemble_7x_kernel_dir}/lib/modules/7.0.0-pocketforge"
: > "${assemble_7x_kernel_dir}/lib/modules/7.0.0-pocketforge/modules.builtin"
if PF_GPU_MODEL=open BUSYBOX_ARM64="${scratch}/absent-busybox" \
    bash "${repo_dir}/boards/tsp/initrd/build-initrd.sh" \
        --src "${repo_dir}" \
        --kernel-tsp-dir "${assemble_7x_kernel_dir}" \
        --gpu-km-dir "${scratch}/unused-gpu-km" \
        --gpu-km-model in-tree-7.x \
        --kernel-required-modules powervr \
        --out "${scratch}/unused-7x-initrd.gz" \
        >"${scratch}/assemble-7x.out" 2>"${scratch}/assemble-7x.err"; then
    echo 'FAIL: 7.x assemble-stage fixture unexpectedly built an initrd' >&2
    exit 1
fi
if grep -F 'videobuf2 (' "${scratch}/assemble-7x.out" >/dev/null; then
    echo 'FAIL: 7.x powervr-only contract ran the vestigial videobuf2 preflight' >&2
    exit 1
fi
grep -F "FATAL: baked busybox not found at ${scratch}/absent-busybox" \
    "${scratch}/assemble-7x.err" >/dev/null

# The same 6.x contract must fail closed if its declared videobuf2 capability
# is neither a module nor built in.
: > "${assemble_release_dir}/modules.builtin"
if PF_GPU_MODEL=open BUSYBOX_ARM64="${scratch}/absent-busybox" \
    bash "${repo_dir}/boards/tsp/initrd/build-initrd.sh" \
        --src "${repo_dir}" \
        --kernel-tsp-dir "${assemble_kernel_dir}" \
        --gpu-km-dir "${scratch}/unused-gpu-km" \
        --gpu-km-model in-tree-6.x \
        --kernel-required-modules "powervr videobuf2-dma-contig sun6i-csi xradio" \
        --out "${scratch}/unused-missing-initrd.gz" \
        >"${scratch}/assemble-missing.out" 2>"${scratch}/assemble-missing.err"; then
    echo 'FAIL: missing declared 6.x videobuf2 capability was accepted' >&2
    exit 1
fi
grep -F 'videobuf2-dma-contig.ko not found as a module' \
    "${scratch}/assemble-missing.err" >/dev/null

echo 'kernel-module-form=PASS'
