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
required="$root/rootfs-overlay/etc/systemd/system/pf-open-gpu-required.conf"
drm_systemd_rule="$root/rootfs-overlay/etc/udev/rules.d/70-pocketforge-drm-systemd.rules"
probe="$root/tools/open-gpu-probe.c"
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
grep -F 'lib/firmware/fw_xr829_bt.bin' "$root/scripts/verify-rootfs-firmware.sh" >/dev/null
grep -F 'wifi-firmware/fw_xr829_bt.bin' "$customize" >/dev/null
grep -F 'llvmpipe' "$probe" >/dev/null
grep -F 'PF-OPEN-GPU PASS:' "$gate" >/dev/null
grep -Fx 'DefaultEnvironment=PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1' "$manager_environment" >/dev/null
grep -Fx 'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1' "$session_environment" >/dev/null
grep -Fx 'Environment=PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1' "$unit" >/dev/null
grep -Fx 'export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1' "$gate" >/dev/null
grep -F 'hint=PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=%s' "$probe" >/dev/null
grep -F 'install -D -m 0644 "/work/src/rootfs-overlay/etc/systemd/system.conf.d/50-pocketforge-open-gpu.conf"' "$customize" >/dev/null
grep -F 'install -D -m 0644 "/work/src/rootfs-overlay/etc/environment.d/50-pocketforge-open-gpu.conf"' "$customize" >/dev/null
grep -F 'install -D -m 0755 "/work/src/rootfs-overlay/etc/profile.d/pocketforge-open-gpu.sh"' "$customize" >/dev/null
# shellcheck disable=SC2016 # Match the literal build-script variable.
open_model_block="$(sed -n '/^if \[ "${PF_GPU_MODEL}" = "open" \]; then$/,/^fi$/p' "$customize")"
grep -Fx 'SUBSYSTEM=="drm", KERNEL=="renderD*", TAG+="systemd"' "$drm_systemd_rule" >/dev/null
printf '%s\n' "$open_model_block" | grep -F '/etc/udev/rules.d/70-pocketforge-drm-systemd.rules' >/dev/null
[ "$(grep -Fc '/etc/udev/rules.d/70-pocketforge-drm-systemd.rules' "$customize")" -eq \
  "$(printf '%s\n' "$open_model_block" | grep -Fc '/etc/udev/rules.d/70-pocketforge-drm-systemd.rules')" ]
for open_gpu_unit in $open_gpu_units; do
    shared_unit="$root/rootfs-overlay/etc/systemd/system/$open_gpu_unit"
    dropin="$root/rootfs-overlay/etc/systemd/system/$open_gpu_unit.d/50-open-gpu.conf"
    grep -Fx 'Environment=PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1' "$dropin" >/dev/null
    printf '%s\n' "$open_model_block" | grep -F "/etc/systemd/system/${open_gpu_unit}.d/50-open-gpu.conf" >/dev/null
    if grep -F 'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER' "$shared_unit" >/dev/null; then
        echo "open GPU opt-in must not be present in shared unit: $open_gpu_unit" >&2
        exit 1
    fi
done
grep -F '/usr/lib/pocketforge/open-gpu-probe' "$gate" >/dev/null
grep -F 'VK_PHYSICAL_DEVICE_TYPE_CPU' "$probe" >/dev/null
grep -F 'vkQueueSubmit' "$probe" >/dev/null
grep -F 'vkWaitForFences' "$probe" >/dev/null
grep -F 'submit=ok' "$probe" >/dev/null
grep -F 'COPY --from=gpu-um-build /probe/usr/lib/pocketforge/open-gpu-probe /out/usr/lib/pocketforge/open-gpu-probe' "$dockerfile" >/dev/null
grep -F 'install -D -m 0755 /work/gpu-um-mesa/usr/lib/pocketforge/open-gpu-probe' "$customize" >/dev/null
grep -F 'libvulkan-dev:arm64' "$dockerfile" >/dev/null
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
# The open-model install block is shared by release and dev construction. Keep
# the production probe outside every POCKETFORGE_VARIANT conditional.
probe_install_block="$(sed -n '/# Open Mesa GLES\/EGL\/GBM userspace/,/open Mesa: userspace install verified/p' "$customize")"
printf '%s\n' "$probe_install_block" | grep -F 'open-gpu-probe' >/dev/null
if printf '%s\n' "$probe_install_block" | grep -F 'POCKETFORGE_VARIANT' >/dev/null; then
    echo 'open GPU probe install must not be variant-gated' >&2
    exit 1
fi
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

# The gate may wait for device discovery, but must not wait for the foreground
# target or any UI unit that is itself gated by this service.
after="$(sed -n 's/^After=//p' "$unit")"
if [ "$after" != 'systemd-udev-settle.service dev-dri-renderD128.device' ]; then
    echo "open GPU gate has unexpected After= ordering: $after" >&2
    exit 1
fi
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

echo 'open-gpu-integration=PASS'
