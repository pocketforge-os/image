#!/bin/sh
set -eu

root=${1:?usage: verify-no-gpu-artifacts.sh ROOT [LABEL]}
label=${2:-tree}

[ -d "$root" ] || { echo "FATAL: gpu_model=none verification root missing: $root" >&2; exit 2; }

if [ "${PF_GPU_MODEL:-none}" = "none" ]; then
    # libvulkan.so is the vendor-neutral dispatch loader, not a GPU driver.  It
    # may arrive transitively (for example ffmpeg -> libavfilter -> libplacebo)
    # and cannot expose hardware without an installed ICD.  Reject the actual
    # capability-bearing boundary instead: ICD manifests, DRI drivers, vendor
    # userspace, kernel modules, and firmware.
    found=$(
        find "$root" \
            \( \
                \( -type d \( -path '*/lib/firmware/powervr' -o -path '*/usr/lib/pvr-rogue' \) \) -o \
                \( -type f \( \
                    -name 'pvrsrvkm.ko' -o -name 'dc_sunxi.ko' -o -name 'powervr.ko' -o \
                    -name 'rgx.fw*' -o -name 'rgx.sh*' -o -name 'rogue*.fw' -o \
                    -path '*/vulkan/icd.d/*' -o -path '*/dri/*.so*' -o \
                    -name 'libvulkan_powervr*' -o \
                    -name 'libsrv_um.so*' -o -name 'libIMGegl.so*' -o \
                    -name 'libSDL3-pocketforge.so*' -o -name 'LICENSE.powervr' -o \
                    -name 'pf-shell' -o -name 'pocketforge-recovery-entry' \
                \) \) \
            \) -print -quit
    )

    if [ -n "$found" ]; then
        echo "FATAL: GPU artifact reached gpu_model=none ${label}: ${found#"$root"/}" >&2
        exit 1
    fi
fi

if [ "${PF_DISPLAY_PIPELINE:-}" = "none" ]; then
    display_found=$(
        find "$root" \
            \( \
                \( -type d -path '*/opt/pocketforge/boot-anim/frames' \) -o \
                \( -type f \( \
                    -name 'pocketforge-boot-animator' -o \
                    -name 'pocketforge-menu' -o \
                    -name 'pocketforge-placeholder' \
                \) \) \
            \) -print -quit
    )
    if [ -n "$display_found" ]; then
        echo "FATAL: framebuffer UI artifact reached display_pipeline=none ${label}: ${display_found#"$root"/}" >&2
        exit 1
    fi

    wants_root="$root/etc/systemd/system"
    if [ -d "$wants_root" ]; then
        for enabled in "$wants_root"/*.target.wants/* "$wants_root"/*.wants/*; do
            [ -L "$enabled" ] || continue
            target=$(readlink "$enabled")
            case "$target" in
                /*) unit="$root$target" ;;
                *) unit=$(readlink -f "$enabled") ;;
            esac
            case "$unit" in "$root"/*) ;; *) continue ;; esac
            if [ -f "$unit" ] && grep -Eiq '(^|[^[:alnum:]_])(/dev/)?fb[0-9]+([^[:alnum:]_]|$)|framebuffer' "$unit"; then
                echo "FATAL: enabled framebuffer unit reached display_pipeline=none ${label}: ${enabled#"$root"/}" >&2
                exit 1
            fi
        done
    fi
fi

echo "PASS: ${label} satisfies gpu_model=${PF_GPU_MODEL:-unspecified} and display_pipeline=${PF_DISPLAY_PIPELINE:-unspecified} negative artifact policy"
