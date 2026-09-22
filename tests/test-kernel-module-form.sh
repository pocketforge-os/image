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

echo 'kernel-module-form=PASS'
