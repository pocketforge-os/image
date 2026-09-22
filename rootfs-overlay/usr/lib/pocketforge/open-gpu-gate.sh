#!/bin/sh
# Fail-closed boot acceptance for the A133 open GPU image.
set -eu

fw=/lib/firmware/powervr/rogue_22.102.54.38_v1.fw
provenance=/usr/lib/pocketforge/gpu-fw-provenance
probe=/usr/lib/pocketforge/open-gpu-probe
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1

[ -d /sys/module/powervr ] || { echo "PF-OPEN-GPU FAIL: powervr is not loaded" >&2; exit 1; }
[ -e /dev/dri/renderD128 ] || { echo "PF-OPEN-GPU FAIL: /dev/dri/renderD128 is absent" >&2; exit 1; }
[ -r "$fw" ] || { echo "PF-OPEN-GPU FAIL: firmware is absent at $fw" >&2; exit 1; }
[ -x "$probe" ] || { echo "PF-OPEN-GPU FAIL: open-gpu-probe is absent" >&2; exit 1; }

expected="$(sed -n 's/.*sha256=\([0-9a-f]\{64\}\).*/\1/p' "$provenance")"
actual="$(sha256sum "$fw" | cut -d' ' -f1)"
if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    echo "PF-OPEN-GPU FAIL: firmware sha256=$actual expected=${expected:-missing}" >&2
    exit 1
fi

km="$(modinfo -F version powervr 2>/dev/null || true)"
[ -n "$km" ] || km="$(modinfo -F description powervr 2>/dev/null || true)"
[ -n "$km" ] || km=unknown

probe_result="$(timeout 15s "$probe")" || {
    if [ -z "${PVR_I_WANT_A_BROKEN_VULKAN_DRIVER:-}" ]; then
        echo "PF-OPEN-GPU HINT: set PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1" >&2
    fi
    echo "PF-OPEN-GPU FAIL: Vulkan submission probe failed" >&2
    exit 1
}
echo "$probe_result"
renderer="$(printf '%s\n' "$probe_result" | sed -n 's/^renderer=\(.*\) driver=.* submit=ok$/\1/p')"
[ -n "$renderer" ] || { echo "PF-OPEN-GPU FAIL: malformed probe result" >&2; exit 1; }

echo "PF-OPEN-GPU PASS: km=$km firmware_sha256=$actual mesa_renderer=$renderer"
