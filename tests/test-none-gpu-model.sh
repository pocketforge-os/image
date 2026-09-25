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
grep -F 'if [ "${PF_GPU_MODEL}" = "open" ]; then' "$dockerfile" >/dev/null
grep -F 'open gpu-km model must be in-tree-*' "$dockerfile" >/dev/null
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

# Evaluate the package-list section in isolation so the test observes its actual
# output without invoking mmdebstrap.  Display-capable package lists must remain
# byte-identical; display-less dev and release lists must drop every explicit
# root that can install or transitively select Mesa/EGL/GBM/GLES artifacts.
package_section="$tmpdir/package-section.sh"
sed -n '/^PKG_FILE=/,/^echo "  package list: ${PKG_LIST}"$/p' "$rootfs" >"$package_section"

resolve_packages() {
    variant=$1
    gpu_model=$2
    display_pipeline=$3
    if [ "$display_pipeline" = none ]; then
        has_display=0
    else
        has_display=1
    fi
    SRC_DIR="$root" VARIANT="$variant" PF_GPU_MODEL="$gpu_model" \
        PF_DISPLAY_PIPELINE="$display_pipeline" PF_HAS_DISPLAY="$has_display" \
        sh "$package_section" |
        sed -n 's/^  package list: //p'
}

expected_release=$(sed '/^\s*#/d;/^\s*$/d' "$root/rootfs-packages.txt" | paste -sd, -)
expected_dev="${expected_release},$(sed '/^\s*#/d;/^\s*$/d' "$root/rootfs-packages-dev.txt" | paste -sd, -)"
expected_open="${expected_release},$(sed '/^\s*#/d;/^\s*$/d' "$root/rootfs-packages-mainline.txt" | paste -sd, -),libvulkan1"
test "$(resolve_packages release ddk fbdev)" = "$expected_release"
test "$(resolve_packages dev ddk fbdev)" = "$expected_dev"
test "$(resolve_packages release open fbdev)" = "$expected_open"
expected_open_dev="${expected_dev},$(sed '/^\s*#/d;/^\s*$/d' "$root/rootfs-packages-mainline.txt" | paste -sd, -),$(sed '/^\s*#/d;/^\s*$/d' "$root/rootfs-packages-mainline-dev.txt" | paste -sd, -),libvulkan1"
test "$(resolve_packages dev open drm)" = "$expected_open_dev"

for variant in release dev; do
    package_list=$(resolve_packages "$variant" open none)
    for forbidden in libavcodec59 libavutil57 libegl1 libepoxy0 libgbm1 libgles2 \
        libwayland-egl1 ffmpeg libvdpau1; do
        if printf '%s\n' "$package_list" | tr ',' '\n' | grep -Fxq "$forbidden"; then
            echo "FAIL: display_pipeline=none retained graphics package root $forbidden ($variant)" >&2
            exit 1
        fi
    done
done
echo 'PASS: display-less package sets omit every presentation/media graphics root while display-capable sets are byte-identical'

# The Vulkan loader belongs to the GPU stack, not the presentation stack.  An
# open + none image keeps libvulkan1, Mesa, its probe, and its boot gate for
# headless/offscreen rendering while omitting only the SDL presentation client.
for variant in release dev; do
    package_list=$(resolve_packages "$variant" open none)
    printf '%s\n' "$package_list" | tr ',' '\n' | grep -Fxq libvulkan1
done
grep -F 'elif [ "${PF_GPU_MODEL}" = "open" ]; then' "$rootfs" >/dev/null
grep -F 'elif [ "${PF_GPU_MODEL:-ddk}" = "open" ]; then' "$rootfs" >/dev/null
test "$(grep -Fc 'if [ "${PF_GPU_MODEL}" != "none" ] && [ "${PF_HAS_DISPLAY}" = 1 ]; then' "$rootfs")" -eq 2
grep -F 'if [ "${PF_HAS_DISPLAY}" = 1 ] && [ "${POCKETFORGE_VARIANT:-dev}" = "dev" ] &&' "$rootfs" >/dev/null
echo 'PASS: open + none keeps the headless GPU stack while omitting SDL presentation clients'

# Execute the exact framebuffer-shell and recovery hook sections with all their
# artifacts staged, as they are for the open model. The single display predicate
# must keep both framebuffer consumers out while retaining independent session
# authority; the unchanged verifier then proves the resulting root is clean.
mkdir -p "$tmpdir/open-none/rootfs" \
    "$tmpdir/open-none/launcher/bin" \
    "$tmpdir/open-none/runtime/bin" \
    "$tmpdir/open-none/runtime/systemd" \
    "$tmpdir/open-none/runtime/tmpfiles.d" \
    "$tmpdir/open-none/recovery/bin"
cp /bin/true "$tmpdir/open-none/launcher/bin/pf-shell"
cp /bin/true "$tmpdir/open-none/runtime/bin/pf-session-authorityd"
for binary in "$tmpdir/open-none/launcher/bin/pf-shell" \
    "$tmpdir/open-none/runtime/bin/pf-session-authorityd"; do
    printf '\267\000' | dd of="$binary" bs=1 seek=18 conv=notrunc status=none
done
: >"$tmpdir/open-none/runtime/systemd/pf-session-authorityd.service"
: >"$tmpdir/open-none/runtime/tmpfiles.d/pocketforge.conf"
: >"$tmpdir/open-none/recovery/bin/pocketforge-recovery-entry"
chmod +x "$tmpdir/open-none/recovery/bin/pocketforge-recovery-entry"
sed -n '/^# --- F13 shell owner/,/^# --- W2c preference state authority/p' "$rootfs" | sed '$d' \
    >"$tmpdir/open-none/hook-sections.sh"
sed -n '/^# product-010 F16: recovery/,/^# ---- Panel owner selection/p' "$rootfs" | sed '$d' \
    >>"$tmpdir/open-none/hook-sections.sh"
sed -i "s|/work/src|$root|g" "$tmpdir/open-none/hook-sections.sh"
ROOTFS="$tmpdir/open-none/rootfs" \
    LAUNCHER_DIR="$tmpdir/open-none/launcher" \
    RUNTIME_DIR="$tmpdir/open-none/runtime" \
    PF_RECOVERY_BIN="$tmpdir/open-none/recovery/bin/pocketforge-recovery-entry" \
    PF_GPU_MODEL=open PF_DISPLAY_PIPELINE=none PF_HAS_DISPLAY=0 \
    sh -eu "$tmpdir/open-none/hook-sections.sh" >/dev/null
test -x "$tmpdir/open-none/rootfs/usr/bin/pf-session-authorityd"
test -L "$tmpdir/open-none/rootfs/etc/systemd/system/multi-user.target.wants/pf-session-authorityd.service"
test ! -e "$tmpdir/open-none/rootfs/usr/bin/pf-shell"
test ! -e "$tmpdir/open-none/rootfs/etc/systemd/system/pf-shell-selected.service"
test ! -e "$tmpdir/open-none/rootfs/opt/pocketforge/bin/pocketforge-recovery-entry"
test ! -e "$tmpdir/open-none/rootfs/etc/systemd/system/pocketforge-recovery.path"
PF_GPU_MODEL=open PF_DISPLAY_PIPELINE=none "$verifier" "$tmpdir/open-none/rootfs" test-fixture >/dev/null
echo 'PASS: open + none customize hook rejects staged framebuffer shell and recovery while retaining headless authority'

mkdir -p "$tmpdir/clean/lib/modules/7.2.0/kernel/drivers/mmc" \
    "$tmpdir/clean/usr/lib/aarch64-linux-gnu" \
    "$tmpdir/clean/usr/share/vulkan/icd.d" \
    "$tmpdir/file-dirty/lib/modules/7.2.0/kernel/drivers/gpu/drm/imagination" \
    "$tmpdir/directory-dirty/usr/share/vulkan/icd.d" \
    "$tmpdir/driver-dirty/usr/lib/aarch64-linux-gnu/dri" \
    "$tmpdir/icd-symlink-dirty/usr/share/vulkan/icd.d" \
    "$tmpdir/driver-symlink-dirty/usr/lib/aarch64-linux-gnu/dri" \
    "$tmpdir/icd-absolute-symlink-dirty/usr/share/vulkan/icd.d" \
    "$tmpdir/icd-relative-symlink-dirty/usr/share/vulkan/icd.d" \
    "$tmpdir/icd-directory-symlink-dirty/usr/share/vulkan" \
    "$tmpdir/icd-directory-symlink-dirty/opt/icds" \
    "$tmpdir/driver-directory-symlink-dirty/usr/lib/aarch64-linux-gnu" \
    "$tmpdir/driver-directory-symlink-dirty/opt/drivers" \
    "$tmpdir/icd-parent-symlink-dirty/usr/share" \
    "$tmpdir/icd-parent-symlink-dirty/opt/gpu/icd.d" \
    "$tmpdir/icd-grandparent-symlink-dirty/usr" \
    "$tmpdir/icd-grandparent-symlink-dirty/opt/share/vulkan/icd.d" \
    "$tmpdir/driver-parent-symlink-dirty/usr/lib" \
    "$tmpdir/driver-parent-symlink-dirty/opt/arch/dri" \
    "$tmpdir/driver-grandparent-symlink-dirty/usr" \
    "$tmpdir/driver-grandparent-symlink-dirty/opt/lib/aarch64-linux-gnu/dri" \
    "$tmpdir/icd-hardlink-dirty/usr/share/vulkan/icd.d" \
    "$tmpdir/icd-escape-symlink-dirty/usr/share/vulkan/icd.d"
: >"$tmpdir/clean/lib/modules/7.2.0/kernel/drivers/mmc/sunxi-mmc.ko"
: >"$tmpdir/clean/usr/lib/aarch64-linux-gnu/libvulkan.so.1.3.239"
: >"$tmpdir/file-dirty/lib/modules/7.2.0/kernel/drivers/gpu/drm/imagination/powervr.ko"
: >"$tmpdir/directory-dirty/usr/share/vulkan/icd.d/software-renderer.json"
: >"$tmpdir/driver-dirty/usr/lib/aarch64-linux-gnu/dri/unlisted_vendor_dri.so"
ln -s ../../../lib/aarch64-linux-gnu/vendor.json \
    "$tmpdir/icd-symlink-dirty/usr/share/vulkan/icd.d/vendor.json"
ln -s ../missing-vendor-driver.so \
    "$tmpdir/driver-symlink-dirty/usr/lib/aarch64-linux-gnu/dri/vendor_dri.so"
: >"$tmpdir/icd-absolute-symlink-dirty/vendor.json"
ln -s /vendor.json \
    "$tmpdir/icd-absolute-symlink-dirty/usr/share/vulkan/icd.d/vendor.json"
: >"$tmpdir/icd-relative-symlink-dirty/vendor.json"
ln -s ../../../../vendor.json \
    "$tmpdir/icd-relative-symlink-dirty/usr/share/vulkan/icd.d/vendor.json"
: >"$tmpdir/icd-directory-symlink-dirty/opt/icds/vendor.json"
ln -s /opt/icds \
    "$tmpdir/icd-directory-symlink-dirty/usr/share/vulkan/icd.d"
: >"$tmpdir/driver-directory-symlink-dirty/opt/drivers/vendor_dri.so"
ln -s ../../../../opt/drivers \
    "$tmpdir/driver-directory-symlink-dirty/usr/lib/aarch64-linux-gnu/dri"
: >"$tmpdir/icd-parent-symlink-dirty/opt/gpu/icd.d/vendor.json"
ln -s /opt/gpu "$tmpdir/icd-parent-symlink-dirty/usr/share/vulkan"
: >"$tmpdir/icd-grandparent-symlink-dirty/opt/share/vulkan/icd.d/vendor.json"
ln -s ../opt/share "$tmpdir/icd-grandparent-symlink-dirty/usr/share"
: >"$tmpdir/driver-parent-symlink-dirty/opt/arch/dri/vendor_dri.so"
ln -s /opt/arch "$tmpdir/driver-parent-symlink-dirty/usr/lib/aarch64-linux-gnu"
: >"$tmpdir/driver-grandparent-symlink-dirty/opt/lib/aarch64-linux-gnu/dri/vendor_dri.so"
ln -s ../opt/lib "$tmpdir/driver-grandparent-symlink-dirty/usr/lib"
: >"$tmpdir/icd-hardlink-dirty/source.json"
ln "$tmpdir/icd-hardlink-dirty/source.json" \
    "$tmpdir/icd-hardlink-dirty/usr/share/vulkan/icd.d/vendor.json"
ln -s ../../../../../../outside-rootfs/vendor.json \
    "$tmpdir/icd-escape-symlink-dirty/usr/share/vulkan/icd.d/vendor.json"

# Khronos' Linux discovery table appends vulkan/icd.d to these system and
# image-user fallback bases.  Give every derived boundary an independent,
# attacker-shaped manifest control so an unwired list entry cannot pass.
icd_boundaries=$("$verifier" --print-vulkan-icd-boundaries)
boundary_number=0
for boundary in $icd_boundaries; do
    boundary_number=$((boundary_number + 1))
    fixture="$tmpdir/icd-boundary-$boundary_number"
    mkdir -p "$fixture/$(dirname "$boundary")" "$fixture/opt/hidden-$boundary_number"
    : >"$fixture/opt/hidden-$boundary_number/vendor.json"
    ln -s "/opt/hidden-$boundary_number" "$fixture/$boundary"
    if PF_GPU_MODEL=none "$verifier" "$fixture" test-fixture >/dev/null 2>&1; then
        echo "FAIL: none-model verifier accepted Vulkan ICD boundary $boundary" >&2
        exit 1
    fi
done

dri_boundaries=$("$verifier" --print-mesa-dri-boundaries)
boundary_number=0
for boundary in $dri_boundaries; do
    boundary_number=$((boundary_number + 1))
    fixture="$tmpdir/dri-boundary-$boundary_number"
    mkdir -p "$fixture/$(dirname "$boundary")" "$fixture/opt/dri-hidden-$boundary_number"
    : >"$fixture/opt/dri-hidden-$boundary_number/vendor_dri.so"
    ln -s "/opt/dri-hidden-$boundary_number" "$fixture/$boundary"
    if PF_GPU_MODEL=none "$verifier" "$fixture" test-fixture >/dev/null 2>&1; then
        echo "FAIL: none-model verifier accepted Mesa DRI boundary $boundary" >&2
        exit 1
    fi
done

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
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a dangling Vulkan ICD manifest symlink' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/driver-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a dangling Mesa DRI driver symlink' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-absolute-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted an absolute Vulkan ICD manifest symlink' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-relative-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a relative Vulkan ICD manifest symlink' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-directory-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a symlinked Vulkan ICD directory' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/driver-directory-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a symlinked Mesa DRI directory' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-parent-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a Vulkan ICD behind a linked parent' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-grandparent-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a Vulkan ICD behind a linked grandparent' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/driver-parent-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a Mesa DRI driver behind a linked parent' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/driver-grandparent-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a Mesa DRI driver behind a linked grandparent' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-hardlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a hardlinked Vulkan ICD manifest' >&2
    exit 1
fi
if PF_GPU_MODEL=none "$verifier" "$tmpdir/icd-escape-symlink-dirty" test-fixture >/dev/null 2>&1; then
    echo 'FAIL: none-model verifier accepted a rootfs-escaping Vulkan ICD symlink' >&2
    exit 1
fi
echo 'PASS: none-model permits the vendor-neutral Vulkan loader without an ICD'
echo 'PASS: every documented Vulkan ICD fallback and the configured Mesa DRI boundary has a negative control'
echo 'PASS: none-model negative controls reject nested powervr.ko, ICD/DRI files, links at every path depth, hardlinks, and rootfs escapes'

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
grep -F 'fbdev|drm) PF_HAS_DISPLAY=1 ;;' "$rootfs" >/dev/null
grep -F 'none) PF_HAS_DISPLAY=0 ;;' "$rootfs" >/dev/null
grep -F 'if [ "${PF_HAS_DISPLAY}" = 1 ]; then' "$rootfs" >/dev/null
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
