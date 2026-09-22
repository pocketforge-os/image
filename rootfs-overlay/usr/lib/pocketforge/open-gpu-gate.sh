#!/bin/sh
# Fail-closed boot acceptance for the A133 open GPU image.
set -eu

fw=/lib/firmware/powervr/rogue_22.102.54.38_v1.fw
provenance=/usr/lib/pocketforge/gpu-fw-provenance
testbin=/opt/pocketforge/bin/testgles2

[ -d /sys/module/powervr ] || { echo "PF-OPEN-GPU FAIL: powervr is not loaded" >&2; exit 1; }
[ -e /dev/dri/renderD128 ] || { echo "PF-OPEN-GPU FAIL: /dev/dri/renderD128 is absent" >&2; exit 1; }
[ -r "$fw" ] || { echo "PF-OPEN-GPU FAIL: firmware is absent at $fw" >&2; exit 1; }
[ -x "$testbin" ] || { echo "PF-OPEN-GPU FAIL: testgles2 is absent" >&2; exit 1; }

expected="$(sed -n 's/.*sha256=\([0-9a-f]\{64\}\).*/\1/p' "$provenance")"
actual="$(sha256sum "$fw" | cut -d' ' -f1)"
if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    echo "PF-OPEN-GPU FAIL: firmware sha256=$actual expected=${expected:-missing}" >&2
    exit 1
fi

km="$(modinfo -F version powervr 2>/dev/null || true)"
[ -n "$km" ] || km="$(modinfo -F description powervr 2>/dev/null || true)"
[ -n "$km" ] || km=unknown

log="$(mktemp)"
trap 'find "$(dirname "$log")" -maxdepth 1 -name "$(basename "$log")" -delete' EXIT
if ! timeout 25s pf-take-panel env SDL_VIDEODRIVER=sunxifb \
        "$testbin" --quit-after-ms 15000 >"$log" 2>&1; then
    cat "$log" >&2
    echo "PF-OPEN-GPU FAIL: sunxifb testgles2 gate failed" >&2
    exit 1
fi
cat "$log"
renderer="$(sed -nE 's/.*(GL_RENDERER|renderer)[=: ]+([^;]+).*/\2/ip' "$log" | head -1)"
[ -n "$renderer" ] || { echo "PF-OPEN-GPU FAIL: testgles2 reported no Mesa renderer" >&2; exit 1; }
case "$renderer" in
    *llvmpipe*|*softpipe*|*swrast*)
        echo "PF-OPEN-GPU FAIL: software renderer selected: $renderer" >&2
        exit 1
        ;;
esac

echo "PF-OPEN-GPU PASS: km=$km firmware_sha256=$actual mesa_renderer=$renderer"
