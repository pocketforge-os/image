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
    # userspace, kernel modules, and firmware.  Every component leading to an
    # ICD/DRI boundary must be a real directory: rejecting links at any depth
    # prevents a runtime-reachable artifact from hiding behind an ancestor and
    # avoids following a rootfs-escaping link into the host.  Boundary entries
    # are likewise matched lexically, so dangling links are rejected.  A real,
    # empty ICD directory remains harmless.
    boundary_link=
    for boundary in \
        usr/share/vulkan/icd.d \
        usr/lib/aarch64-linux-gnu/dri
    do
        component=$root
        old_ifs=$IFS
        IFS=/
        for name in $boundary; do
            component=$component/$name
            if [ -L "$component" ]; then
                boundary_link=$component
                break 2
            fi
        done
        IFS=$old_ifs
    done
    IFS=$old_ifs

    if [ -n "$boundary_link" ]; then
        echo "FATAL: GPU artifact boundary reached through symlink in gpu_model=none ${label}: ${boundary_link#"$root"/}" >&2
        exit 1
    fi

    found=$(
        find "$root" \
            \( \
                -path '*/lib/firmware/powervr' -o -path '*/usr/lib/pvr-rogue' -o \
                \( -type l \( -path '*/vulkan/icd.d' -o -path '*/dri' \) \) -o \
                -path '*/vulkan/icd.d/*' -o -path '*/dri/*.so*' -o \
                -name 'pvrsrvkm.ko' -o -name 'dc_sunxi.ko' -o -name 'powervr.ko' -o \
                -name 'rgx.fw*' -o -name 'rgx.sh*' -o -name 'rogue*.fw' -o \
                -name 'libvulkan_powervr*' -o \
                -name 'libsrv_um.so*' -o -name 'libIMGegl.so*' -o \
                -name 'libSDL3-pocketforge.so*' -o -name 'LICENSE.powervr' -o \
                -name 'pf-shell' -o -name 'pocketforge-recovery-entry' \
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
