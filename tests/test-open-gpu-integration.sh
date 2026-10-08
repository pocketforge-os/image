#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
dockerfile="$root/build/Dockerfile.pf"
customize="$root/scripts/build-rootfs.sh"
gate="$root/rootfs-overlay/usr/lib/pocketforge/open-gpu-gate.sh"
unit="$root/rootfs-overlay/etc/systemd/system/pf-open-gpu-gate.service"
selected_unit="$root/rootfs-overlay/etc/systemd/system/pf-shell-selected.service"
foreground_unit="$root/rootfs-overlay/etc/systemd/system/pf-foreground@.service"
manager_environment="$root/rootfs-overlay/etc/systemd/system.conf.d/50-pocketforge-open-gpu.conf"
session_environment="$root/rootfs-overlay/etc/environment.d/50-pocketforge-open-gpu.conf"
profile_environment="$root/rootfs-overlay/etc/profile.d/pocketforge-open-gpu.sh"
zink_manager_environment="$root/rootfs-overlay/etc/systemd/system.conf.d/60-pocketforge-zink.conf"
zink_session_environment="$root/rootfs-overlay/etc/environment.d/60-pocketforge-zink.conf"
zink_profile_environment="$root/rootfs-overlay/etc/profile.d/pocketforge-zink.sh"
required="$root/rootfs-overlay/etc/systemd/system/pf-open-gpu-required.conf"
drm_systemd_rule="$root/rootfs-overlay/etc/udev/rules.d/70-pocketforge-drm-systemd.rules"
probe="$root/tools/open-gpu-probe.c"
mainline_packages="$root/rootfs-packages-mainline.txt"
open_gpu_units='pocketforge-menu.service pf-shell-selected.service pf-foreground@.service'

# Literal Dockerfile variables are intentional in these structural assertions.
# shellcheck disable=SC2016
grep -F 'COPY --from=vendor-manifest-src public /work/vm/public' "$dockerfile" >/dev/null
grep -F -- '--cid-version=1 --raw-leaves' "$dockerfile" >/dev/null
grep -F 'group=pvr-fw-open-22.102.54.38' "$dockerfile" >/dev/null
grep -F 'b571cdd90312c20fe87f14aae43484f7279859921ae3abe58e935412040c7f98' "$dockerfile" >/dev/null
grep -F 'LICENSE.powervr' "$dockerfile" >/dev/null
grep -F 'powervr.ko (in-tree, kernel-tsp)' "$customize" >/dev/null
grep -F "grep -F 'img,img-rogue'" "$customize" >/dev/null
grep -F '/lib/firmware/powervr/rogue_22.102.54.38_v1.fw' "$gate" >/dev/null
# Firmware policy paths are asserted at extracted-rootfs assembly time alongside
# the PowerVR custody checks: signed regdb and owner-approved XR829 BT both ship.
grep -F 'lib/firmware/regulatory.db' "$root/scripts/verify-rootfs-firmware.sh" >/dev/null
# The verifier requires every XR829 artifact, fw_xr829_bt.bin included, through
# one loop; tests/test-rootfs-firmware.sh exercises its refusal without them.
grep -F 'for artifact in fw_xr829.bin boot_xr829.bin sdd_xr829.bin fw_xr829_bt.bin; do' \
    "$root/scripts/verify-rootfs-firmware.sh" >/dev/null
# shellcheck disable=SC2016 # literal verifier source
grep -F 'require_rootfs_file "lib/firmware/${artifact}"' \
    "$root/scripts/verify-rootfs-firmware.sh" >/dev/null
grep -F 'wifi-firmware/fw_xr829_bt.bin' "$customize" >/dev/null
grep -F 'llvmpipe' "$probe" >/dev/null
grep -F 'PF-OPEN-GPU PASS:' "$gate" >/dev/null
grep -Fx 'DefaultEnvironment=MESA_LOADER_DRIVER_OVERRIDE=zink' \
    "$zink_manager_environment" >/dev/null
grep -Fx 'MESA_LOADER_DRIVER_OVERRIDE=zink' \
    "$zink_session_environment" >/dev/null
grep -Fx 'export MESA_LOADER_DRIVER_OVERRIDE=zink' \
    "$zink_profile_environment" >/dev/null
if grep -F 'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER' \
    "$zink_manager_environment" "$zink_session_environment" \
    "$zink_profile_environment" >/dev/null; then
    echo 'Zink defaults must not restore the retired PowerVR opt-in' >&2
    exit 1
fi
grep -F 'install -D -m 0644 "/work/src/rootfs-overlay/etc/systemd/system.conf.d/60-pocketforge-zink.conf"' \
    "$customize" >/dev/null
grep -F 'install -D -m 0644 "/work/src/rootfs-overlay/etc/environment.d/60-pocketforge-zink.conf"' \
    "$customize" >/dev/null
grep -F 'install -D -m 0755 "/work/src/rootfs-overlay/etc/profile.d/pocketforge-zink.sh"' \
    "$customize" >/dev/null
grep -Fx 'Environment=PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1' "$unit" >/dev/null
grep -Fx 'export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1' "$gate" >/dev/null
grep -F 'hint=PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=%s' "$probe" >/dev/null
# shellcheck disable=SC2016 # Match the literal build-script variable.
open_model_block="$(sed -n '/^if \[ "${PF_GPU_MODEL}" = "open" \]; then$/,/^fi$/p' "$customize")"
grep -Fx 'SUBSYSTEM=="drm", KERNEL=="renderD*", TAG+="systemd"' "$drm_systemd_rule" >/dev/null
printf '%s\n' "$open_model_block" | grep -F '/etc/udev/rules.d/70-pocketforge-drm-systemd.rules' >/dev/null
[ "$(grep -Fc '/etc/udev/rules.d/70-pocketforge-drm-systemd.rules' "$customize")" -eq \
  "$(printf '%s\n' "$open_model_block" | grep -Fc '/etc/udev/rules.d/70-pocketforge-drm-systemd.rules')" ]
for removed_export in \
    "$manager_environment" \
    "$session_environment" \
    "$profile_environment" \
    "$root/rootfs-overlay/etc/systemd/system/pocketforge-menu.service.d/50-open-gpu.conf" \
    "$root/rootfs-overlay/etc/systemd/system/pf-shell-selected.service.d/50-open-gpu.conf" \
    "$root/rootfs-overlay/etc/systemd/system/pf-foreground@.service.d/50-open-gpu.conf"; do
    if [ -e "$removed_export" ]; then
        echo "open GPU global opt-in export remains: $removed_export" >&2
        exit 1
    fi
    installed_path="/${removed_export#"$root/rootfs-overlay/"}"
    if printf '%s\n' "$open_model_block" | grep -F "$installed_path" >/dev/null; then
        echo "open GPU global opt-in export is still installed: $installed_path" >&2
        exit 1
    fi
done
for open_gpu_unit in $open_gpu_units; do
    shared_unit="$root/rootfs-overlay/etc/systemd/system/$open_gpu_unit"
    zink_dropin="$root/rootfs-overlay/etc/systemd/system/$open_gpu_unit.d/60-zink.conf"
    grep -Fx 'Environment=MESA_LOADER_DRIVER_OVERRIDE=zink' "$zink_dropin" >/dev/null
    if grep -F 'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER' "$zink_dropin" >/dev/null; then
        echo "Zink drop-in must not restore the PowerVR opt-in: $open_gpu_unit" >&2
        exit 1
    fi
    printf '%s\n' "$open_model_block" | \
        grep -F "/etc/systemd/system/${open_gpu_unit}.d/60-zink.conf" >/dev/null
    if grep -F 'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER' "$shared_unit" >/dev/null; then
        echo "open GPU opt-in must not be present in shared unit: $open_gpu_unit" >&2
        exit 1
    fi
    if grep -F 'MESA_LOADER_DRIVER_OVERRIDE' "$shared_unit" >/dev/null; then
        echo "open GPU Zink selection must not be present in shared unit: $open_gpu_unit" >&2
        exit 1
    fi
done
grep -F '/usr/lib/pocketforge/open-gpu-probe' "$gate" >/dev/null
grep -F 'VK_PHYSICAL_DEVICE_TYPE_CPU' "$probe" >/dev/null
grep -F 'vkQueueSubmit' "$probe" >/dev/null
grep -F 'vkWaitForFences' "$probe" >/dev/null
grep -F 'submit=ok' "$probe" >/dev/null
grep -F 'COPY --from=gpu-um-build /probe/usr/lib/pocketforge/open-gpu-probe /out/usr/lib/pocketforge/open-gpu-probe' "$dockerfile" >/dev/null
grep -F 'COPY --from=gpu-um-build /pocketforge-open-gpu-stack.deb /out/pocketforge-open-gpu-stack.deb' "$dockerfile" >/dev/null
grep -F 'GPU_STACK_PROVIDER_DEB="${GPU_UM_MESA_DIR}/pocketforge-open-gpu-stack.deb"' "$customize" >/dev/null
grep -F 'stage/usr/lib/pocketforge/open-gpu-probe' "$root/build/package-open-gpu-stack.sh" >/dev/null
test "$(grep -Fc 'scripts/verify-open-gpu-provider.sh' "$customize")" -eq 2
if grep -F 'cp -a /work/gpu-um-mesa/usr/local/.' "$customize" >/dev/null; then
    echo 'open Mesa files must enter the rootfs through the file-owning provider package' >&2
    exit 1
fi
grep -F 'libvulkan-dev:arm64' "$dockerfile" >/dev/null
for wsi_runtime_package in libxcb-dri3-0 libxcb-present0 libxshmfence1; do
    grep -Fx "$wsi_runtime_package" "$mainline_packages" >/dev/null || {
        echo "open GPU rootfs lacks WSI runtime package: $wsi_runtime_package" >&2
        exit 1
    }
done
# shellcheck disable=SC2016 # Dockerfile variable is intentionally literal.
grep -F 'FROM ${PF_CONTAINER} AS gpu-um-build' "$dockerfile" >/dev/null
grep -F 'gpu_um_toolchain_probe=ok distro=debian-bookworm' "$dockerfile" >/dev/null
grep -F 'FATAL gpu_um_toolchain_probe=compile-link' "$dockerfile" >/dev/null
grep -F 'gpu_um_native_runtime=ok distro=noble isolation=bundled' "$dockerfile" >/dev/null
probe_line="$(grep -nF 'gpu_um_toolchain_probe=ok distro=debian-bookworm' "$dockerfile" | cut -d: -f1)"
# shellcheck disable=SC2016 # Dockerfile variables are intentionally literal.
target_meson_line="$(grep -nF 'SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" meson setup "${build_dir}"' "$dockerfile" | cut -d: -f1)"
if [ "$probe_line" -ge "$target_meson_line" ]; then
    echo 'Bookworm cross-toolchain probe must run before target Meson setup' >&2
    exit 1
fi
grep -F 'target_abi=debian-bookworm' "$dockerfile" >/dev/null
grep -F 'build/check-rootfs-abi.sh' "$customize" >/dev/null
grep -F 'GPU_UM_MESA_DIR' "$customize" >/dev/null

# G11 (tsp-mc9m.41.924.23): the on-disk shader cache is enabled, with zstd
# compression, in the TARGET aarch64 cross stage (gpu-um-build) ONLY. Mesa
# requires zlib or zstd whenever shader-cache is enabled (gpu-um-tsp
# meson.build:1738-1742: "Shader Cache requires compression"); the native
# x86_64 precompiler stage (mesa_clc/pco_clc/vtn_bindgen2 -- host-only
# generators, never linked into the on-device driver) must stay untouched.
native_precompiler_block="$(awk '
    found && /^FROM / { exit }
    found { print }
    index($0, "AS gpu-um-native-precompilers") { found = 1; print; next }
' "$dockerfile")"
[ -n "$native_precompiler_block" ] || {
    echo 'gpu-um-native-precompilers stage not found' >&2
    exit 1
}
printf '%s\n' "$native_precompiler_block" | grep -F -- '-Dshader-cache=disabled' >/dev/null
printf '%s\n' "$native_precompiler_block" | grep -F -- '-Dzstd=disabled' >/dev/null

# shellcheck disable=SC2016 # Dockerfile stage alias is intentionally literal.
target_stage_block="$(awk '
    found && /^FROM / { exit }
    found { print }
    index($0, "AS gpu-um-build") { found = 1; print; next }
' "$dockerfile")"
[ -n "$target_stage_block" ] || {
    echo 'gpu-um-build stage not found' >&2
    exit 1
}
printf '%s\n' "$target_stage_block" | grep -F -- '-Dshader-cache=enabled' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F -- '-Dzstd=enabled' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F -- '-Dplatforms=x11,wayland' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F -- '-Dglvnd=enabled' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F -- '-Dglvnd-vendor-name=mesa' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F -- '-Dglx=disabled' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F -- '-Degl=enabled' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F -- '-Dgbm=enabled' >/dev/null
printf '%s\n' "$target_stage_block" | grep -F 'libglvnd-dev:arm64' >/dev/null
# The cross sysroot needs the aarch64 zstd headers/.pc file for meson's
# `dependency('libzstd', required: get_option('zstd'))` to resolve; the
# runtime library (libzstd1) is already in rootfs-packages.txt.
printf '%s\n' "$target_stage_block" | grep -F 'libzstd-dev:arm64' >/dev/null
# Mesa's own runtime default is 1 GiB when MESA_SHADER_CACHE_MAX_SIZE is unset
# (src/util/disk_cache.c). This device's rootfs partition is sized to
# content+25% headroom with a 1024 MiB floor (scripts/build-rootfs.sh, "Size
# the ext4 image"), so an unbounded cache could alone consume the entire
# free-space margin. Bake a much smaller ceiling, in the same tier as the
# device's other on-disk caps (rootfs-overlay/etc/systemd/journald.conf.d/
# pocketforge-{release,dev}.conf: 16M/50M, "to avoid filling the rootfs
# partition"), as the build-time default via Mesa's own meson option -- still
# overridable at runtime via MESA_SHADER_CACHE_MAX_SIZE with no rebuild.
printf '%s\n' "$target_stage_block" | grep -F -- '-Dshader-cache-max-size=64M' >/dev/null
# The provider package owns the production probe for both release and dev.
grep -F 'install -D -m 0755 "$probe"' "$root/build/package-open-gpu-stack.sh" >/dev/null
if grep -Eq 'testgles2|SDL_VIDEODRIVER|pf-take-panel|systemctl|fb0|boot-animator|foreground' "$gate"; then
    echo 'open GPU gate must not reference display machinery or dev diagnostics' >&2
    exit 1
fi
grep -F 'Before=pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service' "$unit" >/dev/null
grep -Fx 'RemainAfterExit=yes' "$unit" >/dev/null
if grep -Eq '^[[:space:]]*(Condition|Assert)[A-Za-z]*=' "$unit"; then
    echo 'open GPU gate must not skip on a missing required artifact' >&2
    exit 1
fi
grep -F 'multi-user.target.wants/pf-open-gpu-gate.service' "$customize" >/dev/null
grep -Fx 'Requires=pf-open-gpu-gate.service' "$required" >/dev/null
grep -Fx 'After=pf-open-gpu-gate.service' "$required" >/dev/null
grep -F 'for ui_unit in pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service' "$customize" >/dev/null
grep -F '20-open-gpu-required.conf' "$customize" >/dev/null

# Requires + After makes a failed gate a prerequisite failure, rather than mere
# ordering. Assert both edges as the unit-file-level negative-control contract.
awk '
    /^Requires=pf-open-gpu-gate.service$/ { requires=1 }
    /^After=pf-open-gpu-gate.service$/ { after=1 }
    END { exit !(requires && after) }
' "$required"

# The gate may wait for its own render node, but must not wait for the foreground
# target or any UI unit that is itself gated by this service. It must also not
# wait for udev-settle, which would hold sysinit (and MainUI) on every unrelated
# coldplug event. tests/test-open-gpu-gate-ordering.sh proves that last point
# on the real boot transaction (bd tsp-3rd3.18).
after="$(sed -n 's/^After=//p' "$unit")"
if [ "$after" != 'dev-dri-renderD128.device' ]; then
    echo "open GPU gate has unexpected After= ordering: $after" >&2
    exit 1
fi
if grep -v '^[[:space:]]*#' "$unit" | grep -F 'systemd-udev-settle' >/dev/null; then
    echo 'open GPU gate must not pull in or order after systemd-udev-settle.service' >&2
    exit 1
fi
bound_dropin="$root/rootfs-overlay/etc/systemd/system/dev-dri-renderD128.device.d/50-pocketforge-device-timeout.conf"
grep -Fx 'JobRunningTimeoutSec=30s' "$bound_dropin" >/dev/null
printf '%s\n' "$open_model_block" | grep -F '/etc/systemd/system/dev-dri-renderD128.device.d/50-pocketforge-device-timeout.conf' >/dev/null
for forbidden in pocketforge-foreground.target pf-shell-selected.service pocketforge-menu.service pocketforge-placeholder.service; do
    case " $after " in
        *" $forbidden "*)
            echo "open GPU gate has cyclic After= dependency on $forbidden" >&2
            exit 1
            ;;
    esac
done

# Shell processes consume the prefs socket. Keep their dependency soft so prefsd
# can restart independently, while ordering initial startup behind its start job.
for shell_unit in "$selected_unit" "$foreground_unit"; do
    grep -Fx 'Wants=pf-prefsd.service' "$shell_unit" >/dev/null
    grep -E '^After=.*(^|[[:space:]])pf-prefsd\.service([[:space:]]|$)' "$shell_unit" >/dev/null
    if grep -Fx 'Requires=pf-prefsd.service' "$shell_unit" >/dev/null; then
        echo "shell unit must not couple its lifetime to prefsd: $shell_unit" >&2
        exit 1
    fi
done

# Render the exact quoted production heredoc, syntax-check it, then extract and
# execute its canonical helper chain.  This keeps the generated-hook call and
# the tested definitions tied to the same source instead of an outer-shell copy.
closure_tmp="$(mktemp -d)"
trap 'find "${closure_tmp}" -mindepth 1 -delete; rmdir "${closure_tmp}"' EXIT
rendered_customize="${closure_tmp}/customize-hook.sh"
closure_helpers="${closure_tmp}/open-gpu-closure-helpers.sh"
closure_root="${closure_tmp}/rootfs"
host_library_dir="${closure_tmp}/host-libraries"
customize_heredoc_marker="cat >> \"\${CUSTOMIZE_SCRIPT}\" << 'CUSTOMIZE_EOF'"

if [ "$(grep -Fxc "${customize_heredoc_marker}" "${customize}")" -ne 1 ]; then
    echo 'expected exactly one production CUSTOMIZE_EOF heredoc' >&2
    exit 1
fi
customize_start="$(grep -Fnx "${customize_heredoc_marker}" "${customize}" | cut -d: -f1)"
customize_end="$(awk -v start="${customize_start}" 'NR > start && $0 == "CUSTOMIZE_EOF" { print NR; exit }' "${customize}")"
[ -n "${customize_end}" ] || { echo 'production CUSTOMIZE_EOF terminator not found' >&2; exit 1; }
sed -n "$((customize_start + 1)),$((customize_end - 1))p" "${customize}" >"${rendered_customize}"
bash -n "${rendered_customize}"

helper_start="$(grep -nFx 'open_gpu_library_is_usable() {' "${rendered_customize}" | cut -d: -f1)"
helper_call="$(grep -nFx '    verify_open_gpu_runtime_closure "${ROOTFS}"' "${rendered_customize}" | cut -d: -f1)"
[ -n "${helper_start}" ] && [ -n "${helper_call}" ] && [ "${helper_start}" -lt "${helper_call}" ] || {
    echo 'production open GPU closure helper chain must precede its generated-hook call' >&2
    exit 1
}
for helper in open_gpu_library_is_usable require_open_gpu_library verify_open_gpu_runtime_closure; do
    if [ "$(grep -Fxc "${helper}() {" "${customize}")" -ne 1 ] \
        || [ "$(grep -Fxc "${helper}() {" "${rendered_customize}")" -ne 1 ]; then
        echo "${helper} must have one canonical definition in the production customize hook" >&2
        exit 1
    fi
done
if [ "$(grep -Fxc '    verify_open_gpu_runtime_closure "${ROOTFS}"' "${customize}")" -ne 1 ] \
    || [ "$(grep -Fxc '    verify_open_gpu_runtime_closure "${ROOTFS}"' "${rendered_customize}")" -ne 1 ]; then
    echo 'expected one production closure call in the generated customize hook' >&2
    exit 1
fi

sed -n '/^open_gpu_library_is_usable() {$/,/^install_open_gpu_module_options() {$/p' \
    "${rendered_customize}" | sed '$d' >"${closure_helpers}"
bash -n "${closure_helpers}"
grep -F 'if open_gpu_library_is_usable "${candidate}"; then' "${closure_helpers}" >/dev/null
grep -F 'require_open_gpu_library "${rootfs}" libvulkan.so.1 || return 1' "${closure_helpers}" >/dev/null
grep -F 'require_open_gpu_library "${rootfs}" libdrm.so.2 || return 1' "${closure_helpers}" >/dev/null
grep -F 'env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \' "${closure_helpers}" >/dev/null
grep -F '"${PF_ROOTFS_CHROOT:-chroot}" "${rootfs}" \' "${closure_helpers}" >/dev/null
grep -F '/lib/ld-linux-aarch64.so.1 --list \' "${closure_helpers}" >/dev/null
grep -F '/usr/local/lib/libvulkan_powervr_mesa.so 2>&1' "${closure_helpers}" >/dev/null
grep -F 'open GPU PowerVR ICD dynamic runtime closure is incomplete' "${closure_helpers}" >/dev/null
# shellcheck source=/dev/null
. "${closure_helpers}"

# Stand in for the target loader in this host-side hermetic test. It runs as an
# external process so the production env -i boundary is exercised, and refuses
# any leaked non-conformant-driver opt-in.
chroot_stub="${closure_tmp}/chroot-stub"
cat >"${chroot_stub}" <<'EOF'
#!/bin/sh
set -eu
if env | grep -Fq 'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER'; then
    echo 'clean-environment ICD check inherited the PVR opt-in' >&2
    exit 1
fi
chroot_root=$1
chroot_wsi_library="${chroot_root}/usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0"
if [ -e "${chroot_wsi_library}" ]; then
    printf '%s\n' 'libxcb-dri3.so.0 => /usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0'
else
    printf '%s\n' 'libxcb-dri3.so.0 => not found'
fi
EOF
chmod 0755 "${chroot_stub}"
PF_ROOTFS_CHROOT="${chroot_stub}"
export PF_ROOTFS_CHROOT

# Exercise the production runtime-closure entry point, including its negative
# paths.  The exact Mesa build uses a Gallium/GBM module and does not install
# the stale sun4i_drm DRI filename.
mkdir -p "${closure_root}/usr/local/lib/gbm" \
    "${closure_root}/usr/share/vulkan/icd.d" \
    "${closure_root}/usr/lib/aarch64-linux-gnu" \
    "${host_library_dir}"
for artifact in libEGL_mesa.so.0 libgbm.so.1.0.0 \
    libgallium_dri.so libvulkan_powervr_mesa.so; do
    : >"${closure_root}/usr/local/lib/${artifact}"
done
: >"${closure_root}/usr/local/lib/gbm/dri_gbm.so"
: >"${closure_root}/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
: >"${closure_root}/usr/lib/aarch64-linux-gnu/libvulkan.so.1.3.239"
: >"${closure_root}/usr/lib/aarch64-linux-gnu/libdrm.so.2.4.0"
: >"${closure_root}/usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0.0.0"
ln -s libvulkan.so.1.3.239 "${closure_root}/usr/lib/aarch64-linux-gnu/libvulkan.so.1"
ln -s libdrm.so.2.4.0 "${closure_root}/usr/lib/aarch64-linux-gnu/libdrm.so.2"
ln -s libxcb-dri3.so.0.0.0 "${closure_root}/usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0"
PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER
verify_open_gpu_runtime_closure "${closure_root}" >/dev/null
unset PVR_I_WANT_A_BROKEN_VULKAN_DRIVER
echo 'open-gpu-clean-env-icd=PASS variable=absent loader=dynamic-closure'

rm "${closure_root}/usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0.0.0"
if verify_open_gpu_runtime_closure "${closure_root}" >/dev/null 2>&1; then
    echo 'open runtime closure accepted a missing WSI dependency' >&2
    exit 1
fi
: >"${closure_root}/usr/lib/aarch64-linux-gnu/libxcb-dri3.so.0.0.0"

reset_loader_link() {
    reset_soname=$1
    reset_target=$2
    reset_path="${closure_root}/usr/lib/aarch64-linux-gnu/${reset_soname}"

    if [ -L "${reset_path}" ] || [ -f "${reset_path}" ]; then
        rm "${reset_path}"
    elif [ -d "${reset_path}" ]; then
        rmdir "${reset_path}"
    fi
    ln -s "${reset_target}" "${reset_path}"
}

assert_loader_rejected() {
    assert_soname=$1
    assert_valid_target=$2
    assert_invalid_kind=$3
    assert_path="${closure_root}/usr/lib/aarch64-linux-gnu/${assert_soname}"

    if [ -L "${assert_path}" ] || [ -f "${assert_path}" ]; then
        rm "${assert_path}"
    elif [ -d "${assert_path}" ]; then
        rmdir "${assert_path}"
    fi
    case "${assert_invalid_kind}" in
        missing) ;;
        dangling) ln -s "missing-${assert_soname}" "${assert_path}" ;;
        directory) mkdir "${assert_path}" ;;
        absolute)
            : >"${host_library_dir}/${assert_soname}"
            ln -s "${host_library_dir}/${assert_soname}" "${assert_path}"
            ;;
        *) echo "unknown loader test case: ${assert_invalid_kind}" >&2; exit 1 ;;
    esac

    if verify_open_gpu_runtime_closure "${closure_root}" >/dev/null 2>&1; then
        echo "open runtime closure accepted ${assert_invalid_kind} ${assert_soname}" >&2
        exit 1
    fi
    reset_loader_link "${assert_soname}" "${assert_valid_target}"
}

for loader_case in missing dangling directory absolute; do
    assert_loader_rejected libvulkan.so.1 libvulkan.so.1.3.239 "${loader_case}"
    assert_loader_rejected libdrm.so.2 libdrm.so.2.4.0 "${loader_case}"
done
verify_open_gpu_runtime_closure "${closure_root}" >/dev/null

rm "${closure_root}/usr/local/lib/libgallium_dri.so"
: >"${closure_root}/usr/local/lib/sun4i-drm_dri.so"
if verify_open_gpu_runtime_closure "${closure_root}" >/dev/null 2>&1; then
    echo 'open runtime closure accepted stale sun4i-drm_dri.so without Gallium' >&2
    exit 1
fi
if grep -F 'sun4i-drm_dri.so' "${closure_helpers}" >/dev/null; then
    echo 'open runtime closure incorrectly requires stale sun4i-drm_dri.so' >&2
    exit 1
fi

echo 'open-gpu-integration=PASS'
