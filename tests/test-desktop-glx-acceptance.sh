#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
probe="$root/tools/glx-readback-probe.c"
dockerfile="$root/build/Dockerfile.pf"
packages="$root/rootfs-packages-a133-open-7x-gpu.txt"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/desktop-glx-acceptance.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

# A standalone invocation reuses the complete synthetic-rootfs gate. The gate
# calls back with PF_DESKTOP_GLX_PROVIDER_NESTED=1 so CI's existing provider
# test covers this policy without recursive execution.
if [ "${PF_DESKTOP_GLX_PROVIDER_NESTED:-0}" = 0 ]; then
    "$root/tests/test-open-gpu-provider.sh" >"$scratch/provider.out"
    grep -F 'red=' "$scratch/provider.out" | grep -F 'missing-glx-vendor' | \
        grep -F 'missing-glx-probe' | grep -F 'nonexec-glx-probe' | \
        grep -F 'missing-glxinfo' | \
        grep -F 'missing-mesa-utils' | grep -F 'glx-disabled' >/dev/null
fi

grep -Fx 'mesa-utils' "$packages" >/dev/null
grep -F '#include <GL/glx.h>' "$probe" >/dev/null
grep -F 'glXSwapBuffers' "$probe" >/dev/null
grep -F 'glReadPixels' "$probe" >/dev/null
grep -F 'GLX_READBACK_CRC32 0xad849d79u' "$probe" >/dev/null
grep -F -- '-lGL -lX11' "$dockerfile" >/dev/null

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
