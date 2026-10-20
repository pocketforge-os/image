#!/bin/sh
# Fail-closed boot acceptance for the A133 open GPU image.
set -eu

fw=/lib/firmware/powervr/rogue_22.102.54.38_v1.fw
provenance=/usr/lib/pocketforge/gpu-fw-provenance
probe=/usr/lib/pocketforge/open-gpu-probe
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1

# Branch selection (tsp-mc9m.41.984.54.18): the render node's bound DRM driver
# picks the branch. A virtio_gpu render node takes the strict virtual branch
# below; every other layout (including a physical board and every failure the
# ordering tests cover) falls through to the unchanged physical branch.
node_driver=
node_device=/sys/class/drm/renderD128/device
if [ -e /dev/dri/renderD128 ] && [ -e "$node_device/driver" ]; then
    node_driver="$(basename "$(readlink -f "$node_device/driver")")"
    # virtio-mmio is the platform parent of the actual virtio_gpu device on
    # this machine.  Only that named child can promote the node to virtual;
    # an arbitrary child or an absent child remains fail-closed.
    if [ "$node_driver" = virtio-mmio ]; then
        for child_driver in "$node_device"/virtio*/driver; do
            [ -e "$child_driver" ] || continue
            if [ "$(basename "$(readlink -f "$child_driver")")" = virtio_gpu ]; then
                node_driver=virtio_gpu
                break
            fi
        done
    fi
fi

if [ "$node_driver" = virtio_gpu ]; then
    # Strict virtual branch: render-only virtio_gpu + Mesa Venus only. No
    # powervr module, firmware or GE8300 provenance is consulted here, and no
    # result this branch emits counts toward GE8300 conformance.
    [ -x "$probe" ] || { echo "PF-OPEN-GPU FAIL: open-gpu-probe is absent" >&2; exit 1; }
    icd=
    for candidate in /usr/share/vulkan/icd.d/virtio_icd.*.json; do
        [ -r "$candidate" ] || continue
        icd="$candidate"
        break
    done
    [ -n "$icd" ] || {
        echo "PF-OPEN-GPU FAIL: Venus ICD manifest is absent from /usr/share/vulkan/icd.d" >&2
        exit 1
    }

    venus_result="$(timeout 30s "$probe" --venus-readback)" || {
        echo "PF-OPEN-GPU FAIL: Venus readback probe failed" >&2
        exit 1
    }
    echo "$venus_result"
    renderer="$(printf '%s\n' "$venus_result" | sed -n 's/^renderer=\(.*\) driver=venus\/[0-9][0-9]* submit=ok capset=venus readback=0x[0-9a-f][0-9a-f]*$/\1/p')"
    [ -n "$renderer" ] || {
        echo "PF-OPEN-GPU FAIL: virtual branch requires driver=venus with capset=venus and a verified readback" >&2
        exit 1
    }

    gles_result="$(timeout 60s "$probe" --gles32-zink-readback)" || {
        echo "PF-OPEN-GPU FAIL: GLES 3.2 Zink readback probe failed" >&2
        exit 1
    }
    echo "$gles_result"
    gles="$(printf '%s\n' "$gles_result" | sed -n 's/^gles_version=3\.2 renderer=\(zink.*\) draw=readback-ok label=virtual$/\1/p')"
    [ -n "$gles" ] || {
        echo "PF-OPEN-GPU FAIL: virtual GLES result must be 3.2 through zink with a verified readback" >&2
        exit 1
    }

    echo "PF-OPEN-GPU PASS: branch=virtual backend=virtio_gpu+venus mesa_renderer=$renderer gles=$gles label=virtual"
    exit 0
fi

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
