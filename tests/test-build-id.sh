#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="${repo_dir}/scripts/generate-build-id.sh"

export PF_DEVICE_ID=trimui-smart-pro-a133 PF_VARIANT=dev
export SOURCE_DATE_EPOCH=1700000000 PF_ODYSSEY_CAPTURE=
export PF_IMAGE_SHA=1111111111111111111111111111111111111111
export PF_KERNEL_SHA=2222222222222222222222222222222222222222
export PF_GPU_SHA=3333333333333333333333333333333333333333
export PF_LIBSDL3_SHA=4444444444444444444444444444444444444444
export PF_WPA_SHA=5555555555555555555555555555555555555555
export PF_RUNTIME_SHA=6666666666666666666666666666666666666666
export PF_HWPROBE_SHA=6767676767676767676767676767676767676767
export PF_SIM_SHA=6868686868686868686868686868686868686868
export PF_LAUNCHER_SHA=abababababababababababababababababababab
export PF_BLOBS_SHA=7777777777777777777777777777777777777777
export PF_VENDOR_MANIFEST_SHA=8888888888888888888888888888888888888888
export PF_CAR_SHA256=9999999999999999999999999999999999999999999999999999999999999999
export PF_UBOOT_SHA='' PF_TFA_SHA=''

first="$(${generator})"
second="$(${generator})"
[ "${first}" = "${second}" ] || { echo "FAIL: identical inputs differed" >&2; exit 1; }

PF_KERNEL_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export PF_KERNEL_SHA
different="$(${generator})"
[ "${first}" != "${different}" ] || { echo "FAIL: different inputs matched" >&2; exit 1; }

case "${first}" in
    'device=trimui-smart-pro-a133 build='????????????) ;;
    *) echo "FAIL: build-id is not a single cat-readable line: ${first}" >&2; exit 1 ;;
esac

printf 'PASS identical=%s\nPASS different=%s\n' "${first}" "${different}"
