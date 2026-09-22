#!/bin/sh
# shellcheck disable=SC2016
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
dockerfile="$root/build/Dockerfile.pf"
rootfs="$root/scripts/build-rootfs.sh"
initrd="$root/boards/tsp/initrd/build-initrd.sh"
sd="$root/scripts/build-sd-image.sh"
verifier="$root/scripts/verify-no-gpu-artifacts.sh"

# The assertions below intentionally match literal Dockerfile/shell variables.
for stage in gpu-km gpu-fw gpu-um-mesa recovery launcher; do
    grep -F "AS ${stage}-none" "$dockerfile" >/dev/null
done
grep -F "gpu-km DEFERRED for device=%s (gpu_model=%s; in-tree open DRM KM)" "$dockerfile" >/dev/null
grep -F 'FROM gpu-um-mesa-${PF_GPU_MODEL} AS gpu-um-mesa' "$dockerfile" >/dev/null
grep -F 'FROM recovery-${PF_GPU_MODEL} AS recovery' "$dockerfile" >/dev/null
grep -F 'FROM launcher-${PF_GPU_MODEL} AS launcher' "$dockerfile" >/dev/null
echo 'PASS: none model has prunable NOT-SHIPPED GPU/userland/recovery/launcher stages'

grep -F 'ddk|open|none)' "$initrd" >/dev/null
grep -F 'verify-no-gpu-artifacts.sh' "$initrd" >/dev/null
grep -F '[ "${PF_GPU_MODEL}" = "ddk" ]; then' "$initrd" >/dev/null
grep -F 'ddk|open|none)' "$sd" >/dev/null
echo 'PASS: none model is accepted and initramfs GPU artifacts fail closed'

grep -F 'gpu_model=none: full ${KREL} kernel module tree installed' "$rootfs" >/dev/null
grep -F 'depmod "${KREL}"' "$rootfs" >/dev/null
grep -F 'verify-no-gpu-artifacts.sh' "$rootfs" >/dev/null
echo 'PASS: none rootfs installs the discovered kernel release and rejects GPU artifacts'

tmpdir=$(mktemp -d)
trap 'find "$tmpdir" -mindepth 1 -delete; rmdir "$tmpdir"' EXIT
mkdir -p "$tmpdir/clean/lib/modules/7.2.0/kernel/drivers/mmc" \
    "$tmpdir/clean/usr/lib/aarch64-linux-gnu" \
    "$tmpdir/clean/usr/share/vulkan/icd.d" \
    "$tmpdir/file-dirty/lib/modules/7.2.0/kernel/drivers/gpu/drm/imagination" \
    "$tmpdir/directory-dirty/usr/share/vulkan/icd.d" \
    "$tmpdir/driver-dirty/usr/lib/aarch64-linux-gnu/dri"
: >"$tmpdir/clean/lib/modules/7.2.0/kernel/drivers/mmc/sunxi-mmc.ko"
: >"$tmpdir/clean/usr/lib/aarch64-linux-gnu/libvulkan.so.1.3.239"
: >"$tmpdir/file-dirty/lib/modules/7.2.0/kernel/drivers/gpu/drm/imagination/powervr.ko"
: >"$tmpdir/directory-dirty/usr/share/vulkan/icd.d/software-renderer.json"
: >"$tmpdir/driver-dirty/usr/lib/aarch64-linux-gnu/dri/unlisted_vendor_dri.so"
PF_GPU_MODEL=none "$verifier" "$tmpdir/clean" test-fixture >/dev/null
if PF_GPU_MODEL=none "$verifier" "$tmpdir/file-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted nested powervr.ko' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/directory-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a forbidden Vulkan ICD directory' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/driver-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted an unlisted Mesa DRI driver' >&2
    exit 1
fi
echo 'PASS: none-model permits the vendor-neutral Vulkan loader without an ICD'
echo 'PASS: none-model negative controls reject nested powervr.ko, ICD manifests, and DRI drivers'

# Execute the generated hook's exact none-model epilogue with SRC_DIR absent.
# The verifier wrapper records that the real call is reached before delegating.
mkdir -p "$tmpdir/hook/work/src/scripts" "$tmpdir/hook/rootfs"
cat >"$tmpdir/hook/work/src/scripts/verify-no-gpu-artifacts.sh" <<EOF
#!/bin/sh
: >"$tmpdir/hook/verifier-reached"
exec "$verifier" "\$@"
EOF
chmod +x "$tmpdir/hook/work/src/scripts/verify-no-gpu-artifacts.sh"
sed -n '/^if \[ "\${PF_GPU_MODEL}" = "none" \] || \[ "\${PF_DISPLAY_PIPELINE}" = "none" \]; then$/,/^echo "\[customize\] Customization complete\."$/p' "$rootfs" |
    sed "s|/work/src/scripts/verify-no-gpu-artifacts.sh|$tmpdir/hook/work/src/scripts/verify-no-gpu-artifacts.sh|" >"$tmpdir/hook/epilogue.sh"
env -u SRC_DIR PF_GPU_MODEL=none PF_DISPLAY_PIPELINE=none ROOTFS="$tmpdir/hook/rootfs" \
    sh -eu "$tmpdir/hook/epilogue.sh" >"$tmpdir/hook/output"
test -f "$tmpdir/hook/verifier-reached"
grep -F '[customize] Customization complete.' "$tmpdir/hook/output" >/dev/null
echo 'PASS: standalone none-model customize hook reaches verification and completes without SRC_DIR'

mkdir -p "$tmpdir/display-clean/etc/systemd/system/multi-user.target.wants" \
    "$tmpdir/display-dirty/opt/pocketforge/boot-anim/frames" \
    "$tmpdir/unit-dirty/etc/systemd/system/multi-user.target.wants"
: >"$tmpdir/display-dirty/opt/pocketforge/boot-anim/frames/frame-000.png"
cat >"$tmpdir/unit-dirty/etc/systemd/system/panel.service" <<'EOF'
[Service]
ExecStart=/usr/bin/example --device /dev/fb0
EOF
ln -s /etc/systemd/system/panel.service "$tmpdir/unit-dirty/etc/systemd/system/multi-user.target.wants/panel.service"
PF_GPU_MODEL=open PF_DISPLAY_PIPELINE=none "$verifier" "$tmpdir/display-clean" test-fixture >/dev/null
if PF_GPU_MODEL=open PF_DISPLAY_PIPELINE=none "$verifier" "$tmpdir/display-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: display-pipeline verifier accepted boot animation frames' >&2
    exit 1
fi
if PF_GPU_MODEL=open PF_DISPLAY_PIPELINE=none "$verifier" "$tmpdir/unit-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: display-pipeline verifier accepted an enabled fbdev unit' >&2
    exit 1
fi
echo 'PASS: none display pipeline rejects framebuffer UI artifacts and enabled fbdev units'

grep -F 'PF_DISPLAY_PIPELINE="${PF_DISPLAY_PIPELINE:?FATAL: PF_DISPLAY_PIPELINE is required (fbdev|drm|none)}"' "$rootfs" >/dev/null
grep -F 'if [ "${PF_DISPLAY_PIPELINE}" != "none" ]; then' "$rootfs" >/dev/null
if unset_error=$(env -u PF_DISPLAY_PIPELINE PF_GPU_MODEL=none bash "$rootfs" 2>&1); then
    echo 'FAIL: rootfs builder accepted an unset display pipeline' >&2
    exit 1
fi
printf '%s\n' "$unset_error" | grep -F 'FATAL: PF_DISPLAY_PIPELINE is required (fbdev|drm|none)' >/dev/null
if invalid_error=$(PF_DISPLAY_PIPELINE=bogus PF_GPU_MODEL=none bash "$rootfs" 2>&1); then
    echo 'FAIL: rootfs builder accepted an invalid display pipeline' >&2
    exit 1
fi
printf '%s\n' "$invalid_error" | grep -F "FATAL: PF_DISPLAY_PIPELINE must be fbdev|drm|none, got 'bogus'" >/dev/null
echo 'PASS: display pipeline is required and independently gates framebuffer UI'

# Existing models remain explicit branches, rather than falling through the new mode.
grep -F 'if [ "${PF_GPU_MODEL:-ddk}" = "ddk" ]; then' "$rootfs" >/dev/null
grep -F 'elif [ "${PF_GPU_MODEL:-ddk}" = "open" ]; then' "$rootfs" >/dev/null
echo 'PASS: ddk and open model selectors remain explicit and none is additive'
