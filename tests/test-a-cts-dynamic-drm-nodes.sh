#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/a-cts-dynamic-drm.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

check_contract() {
    smoke=$1
    dut=$2

    grep -F 'KERNEL=="card[0-9]*"' "$smoke" >/dev/null || return 1
    grep -F 'KERNEL=="renderD[0-9]*"' "$smoke" >/dev/null || return 1
    grep -F '"$drm_root"/card[0-9]*' "$dut" >/dev/null || return 1
    grep -F '"$drm_root"/renderD[0-9]*' "$dut" >/dev/null || return 1
    if grep -Eq '/dev/dri/(card0|renderD128)([^0-9]|$)' "$dut"; then
        return 1
    fi
}

check_contract \
    "$root/tools/a-cts-recovery/smoke.sh" \
    "$root/tools/a-cts-recovery/a-cts-dut"

cp "$root/tools/a-cts-recovery/smoke.sh" "$scratch/smoke-fixed.sh"
cp "$root/tools/a-cts-recovery/a-cts-dut" "$scratch/dut-fixed"
sed -i 's/card\[0-9\]\*/card0/g; s/renderD\[0-9\]\*/renderD128/g' \
    "$scratch/smoke-fixed.sh" "$scratch/dut-fixed"
if check_contract "$scratch/smoke-fixed.sh" "$scratch/dut-fixed"; then
    printf '%s\n' 'fixed-node negative control unexpectedly passed' >&2
    exit 1
fi

printf '%s\n' 'a-cts-dynamic-drm-nodes=PASS positive=enumerated negative=fixed-node-rejected'
