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
    [ "$(grep -Fc 'write_drm_fixture "$fixture" "$dir/node-stat.txt"' "$dut")" -eq 2 ] \
        || return 1
    if grep -Eq '/dev/dri/(card0|renderD128)([^0-9]|$)' "$dut"; then
        return 1
    fi
}

check_contract \
    "$root/tools/a-cts-recovery/smoke.sh" \
    "$root/tools/a-cts-recovery/a-cts-dut"

expect_incomplete_fixture_rejected() {
    label=$1
    fixture=$2
    fixture_root=$scratch/$label
    output=$scratch/$label.output
    mkdir -p "$fixture_root"

    set +e
    env \
        PF_ACTS_ROOT="$fixture_root" \
        PF_ACTS_PREFLIGHT_DIRECT=1 \
        PF_ACTS_PREFLIGHT_DRM_FIXTURE="$fixture" \
        PF_ACTS_EGL_PROBE=/bin/true \
        "$root/tools/a-cts-recovery/a-cts-dut" egl-preflight \
        >"$output" 2>&1
    rc=$?
    set -e

    [ "$rc" -ne 0 ] || {
        printf '%s fixture unexpectedly passed\n' "$label" >&2
        return 1
    }
    grep -Fq 'reason=incomplete_drm_fixture' "$output" || {
        printf '%s fixture failed without incomplete-class evidence\n' "$label" >&2
        return 1
    }
}

expect_incomplete_fixture_rejected card-only card1:video
expect_incomplete_fixture_rejected render-only renderD129:render

cp "$root/tools/a-cts-recovery/smoke.sh" "$scratch/smoke-fixed.sh"
cp "$root/tools/a-cts-recovery/a-cts-dut" "$scratch/dut-fixed"
sed -i 's/card\[0-9\]\*/card0/g; s/renderD\[0-9\]\*/renderD128/g' \
    "$scratch/smoke-fixed.sh" "$scratch/dut-fixed"
if check_contract "$scratch/smoke-fixed.sh" "$scratch/dut-fixed"; then
    printf '%s\n' 'fixed-node negative control unexpectedly passed' >&2
    exit 1
fi

printf '%s\n' \
    'a-cts-dynamic-drm-nodes=PASS positive=enumerated negative=fixed-node+card-only+render-only-rejected'
