#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
probe="$root/tools/glx-readback-probe.c"
dockerfile="$root/build/Dockerfile.pf"
packages="$root/rootfs-packages-a133-open-7x-gpu.txt"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/desktop-glx-acceptance.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

check_probe_contract() {
    candidate=$1

    grep -F '#include <GL/glx.h>' "$candidate" >/dev/null || return 1
    grep -F 'glXSwapBuffers' "$candidate" >/dev/null || return 1
    grep -F 'glReadPixels' "$candidate" >/dev/null || return 1
    grep -F 'image = XGetImage(' "$candidate" >/dev/null || return 1
    grep -F 'check_pixels("xdrawable"' "$candidate" >/dev/null || return 1
    grep -F 'xdrawable_crc32=' "$candidate" >/dev/null || return 1
    grep -F 'GLX_READBACK_CRC32 0xad849d79u' "$candidate" >/dev/null || return 1
    if grep -F 'glReadBuffer(GL_FRONT)' "$candidate" >/dev/null; then
        echo 'desktop GLX probe must verify presentation through the X drawable' >&2
        return 1
    fi
}

# A standalone invocation reuses the complete synthetic-rootfs gate. The gate
# calls back with PF_DESKTOP_GLX_PROVIDER_NESTED=1 so CI's existing provider
# test covers this policy without recursive execution.
if [ "${PF_DESKTOP_GLX_PROVIDER_NESTED:-0}" = 0 ]; then
    "$root/tests/test-open-gpu-provider.sh" >"$scratch/provider.out"
    grep -F 'red=' "$scratch/provider.out" | grep -F 'missing-glx-vendor' | \
        grep -F 'missing-glx-probe' | grep -F 'nonexec-glx-probe' | \
        grep -F 'missing-glxinfo' | \
        grep -F 'missing-mesa-utils' | \
        grep -F 'missing-libxcb-glx-package' | \
        grep -F 'missing-libxcb-glx-soname' | grep -F 'glx-disabled' >/dev/null
fi

grep -Fx 'mesa-utils' "$packages" >/dev/null
grep -Fx 'libxcb-glx0' "$packages" >/dev/null
check_probe_contract "$probe"
grep -F -- '-lGL -lX11' "$dockerfile" >/dev/null

# Negative controls prove that neither the old post-swap GL_FRONT assumption
# nor a probe missing the presented-X-drawable readback satisfies the contract.
sed 's/image = XGetImage(/image = XGetSubImage(/' "$probe" >"$scratch/no-xdrawable.c"
if check_probe_contract "$scratch/no-xdrawable.c" 2>/dev/null; then
    echo 'desktop GLX probe without XGetImage unexpectedly passed' >&2
    exit 1
fi
cp "$probe" "$scratch/front-buffer.c"
printf '\nglReadBuffer(GL_FRONT);\n' >>"$scratch/front-buffer.c"
if check_probe_contract "$scratch/front-buffer.c" 2>/dev/null; then
    echo 'desktop GLX probe using post-swap GL_FRONT unexpectedly passed' >&2
    exit 1
fi

cat >"$scratch/policy-test.c" <<'EOF'
#include <stdio.h>
#include "glx-renderer-policy.h"

static int expect(const char *renderer, int accepted)
{
    const int got = pf_glx_renderer_is_owned(renderer);
    if (got != accepted) {
        fprintf(stderr, "renderer policy mismatch: renderer=%s expected=%d got=%d\n",
                renderer, accepted, got);
        return 1;
    }
    return 0;
}

int main(void)
{
    int failed = 0;
    failed |= expect("zink Vulkan 1.2 (PowerVR GE8300)", 1);
    failed |= expect("ZINK (powervr)", 1);
    failed |= expect("llvmpipe (LLVM 18.1.8, 128 bits)", 0);
    failed |= expect("zink Vulkan 1.3 (llvmpipe)", 0);
    failed |= expect("zink Vulkan 1.3 (lavapipe)", 0);
    failed |= expect("softpipe", 0);
    failed |= expect("zink Vulkan 1.2 (unknown device)", 0);
    failed |= expect("PowerVR GE8300", 0);
    return failed;
}
EOF

cc -std=c11 -O2 -Wall -Wextra -Werror -I"$root/tools" \
    "$scratch/policy-test.c" -o "$scratch/policy-test"
"$scratch/policy-test"

echo 'desktop-glx-acceptance=PASS rootfs=glvnd:mesa probe=draw+present+readback negative=glx-removed+software-renderer'
