#!/bin/sh
# Prove that standard GPU tools bind to the image-owned gpu-um-tsp stack.
set -eu

if [ "$#" -ne 2 ]; then
    echo 'usage: verify-open-gpu-tools.sh ROOTFS GPU_UM_MESA_DIR' >&2
    exit 2
fi

rootfs=$1
producer=$2
status_file="${rootfs}/var/lib/dpkg/status"
script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
artifact_policy="${script_dir}/verify-no-gpu-artifacts.sh"

fatal() {
    echo "FATAL: open GPU tools: $*" >&2
    exit 1
}

[ -d "$rootfs" ] || fatal "rootfs is not a directory: ${rootfs}"
[ -d "$producer/usr/local" ] || fatal "gpu-um-tsp producer tree is missing: ${producer}/usr/local"
[ -f "$status_file" ] || fatal "dpkg installed-state database is missing: ${status_file}"
[ -x "$artifact_policy" ] || fatal "GPU artifact policy is missing: ${artifact_policy}"

package_is_installed() {
    awk -v wanted="$1" '
        $1 == "Package:" { package = $2 }
        $1 == "Status:" && package == wanted &&
            $2 == "install" && $3 == "ok" && $4 == "installed" { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$status_file"
}

package_is_installed pocketforge-open-gpu-stack \
    || fatal 'pocketforge-open-gpu-stack dependency provider is not installed'

for package in \
    libegl-mesa0 \
    libgl1-mesa-dri \
    libglx-mesa0 \
    mesa-opencl-icd \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    mesa-vulkan-drivers; do
    if package_is_installed "$package"; then
        fatal "forbidden Debian Mesa driver package is installed: ${package}"
    fi
done
echo 'open-gpu-stack packages=PASS provider=pocketforge-open-gpu-stack debian_mesa_drivers=absent'

verify_owned_artifact() {
    relative=$1
    source_path="${producer}/${relative}"
    rootfs_path="${rootfs}/${relative}"
    [ -e "$source_path" ] || fatal "gpu-um-tsp producer artifact is missing: ${relative}"
    [ -e "$rootfs_path" ] || fatal "rootfs gpu-um-tsp artifact is missing: ${relative}"
    source_hash=$(sha256sum "$source_path" | awk '{ print $1 }')
    rootfs_hash=$(sha256sum "$rootfs_path" | awk '{ print $1 }')
    [ "$source_hash" = "$rootfs_hash" ] \
        || fatal "gpu-um-tsp artifact hash mismatch: ${relative} producer=${source_hash} rootfs=${rootfs_hash}"
    echo "open-gpu-stack artifact=PASS path=/${relative} sha256=${rootfs_hash}"
}

for artifact in \
    usr/local/lib/libEGL.so.1.0.0 \
    usr/local/lib/libGLESv2.so.2.0.0 \
    usr/local/lib/libgbm.so.1.0.0 \
    usr/local/lib/libgallium_dri.so \
    usr/local/lib/dri/zink_dri.so \
    usr/local/lib/libvulkan_powervr_mesa.so \
    usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json; do
    verify_owned_artifact "$artifact"
done

canonical_icd=usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json
producer_icd="${producer}/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
rootfs_icd="${rootfs}/${canonical_icd}"
[ -e "$rootfs_icd" ] || fatal "canonical PowerVR ICD manifest is missing: /${canonical_icd}"
producer_icd_hash=$(sha256sum "$producer_icd" | awk '{ print $1 }')
rootfs_icd_hash=$(sha256sum "$rootfs_icd" | awk '{ print $1 }')
[ "$producer_icd_hash" = "$rootfs_icd_hash" ] \
    || fatal "gpu-um-tsp artifact hash mismatch: ${canonical_icd} producer=${producer_icd_hash} rootfs=${rootfs_icd_hash}"
echo "open-gpu-stack artifact=PASS path=/${canonical_icd} sha256=${rootfs_icd_hash}"

vulkan_icd_boundaries=$($artifact_policy --print-vulkan-icd-boundaries)
mesa_dri_boundaries="$($artifact_policy --print-mesa-dri-boundaries)
usr/local/lib/dri"
[ -n "$vulkan_icd_boundaries" ] || fatal 'Vulkan ICD discovery boundary list is empty'
[ -n "$mesa_dri_boundaries" ] || fatal 'Mesa DRI discovery boundary list is empty'

# A loader boundary reached through a symlink can hide a driver outside the
# staged rootfs from a lexical scan. Reject a link at every path component,
# including the boundary itself, before inspecting entries beneath it.
reject_symlinked_boundary() {
    boundary=$1
    component=$rootfs
    old_ifs=$IFS
    IFS=/
    for name in $boundary; do
        component=$component/$name
        if [ -L "$component" ]; then
            IFS=$old_ifs
            fatal "GPU driver discovery boundary reached through symlink: /${boundary} component=${component#"${rootfs}"}"
        fi
    done
    IFS=$old_ifs
}

for boundary in $vulkan_icd_boundaries; do
    reject_symlinked_boundary "$boundary"
    directory="${rootfs}/${boundary}"
    if [ -e "$directory" ] && [ ! -d "$directory" ]; then
        fatal "Vulkan ICD discovery boundary is not a directory: /${boundary}"
    fi
    [ -d "$directory" ] || continue
    case "$boundary" in
        usr/local/share/vulkan/icd.d|usr/share/vulkan/icd.d)
            allowed=powervr_mesa_icd.aarch64.json
            ;;
        *) allowed=__no_owned_manifest_at_this_boundary__ ;;
    esac
    foreign_icd=$(find "$directory" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type l \) ! -name "$allowed" -print -quit)
    [ -z "$foreign_icd" ] \
        || fatal "foreign Vulkan ICD manifest: ${foreign_icd#"${rootfs}"}"
done

for boundary in $mesa_dri_boundaries; do
    reject_symlinked_boundary "$boundary"
    directory="${rootfs}/${boundary}"
    if [ -e "$directory" ] && [ ! -d "$directory" ]; then
        fatal "Mesa DRI discovery boundary is not a directory: /${boundary}"
    fi
    [ -d "$directory" ] || continue
    case "$boundary" in
        usr/local/lib/dri) allowed=zink_dri.so ;;
        *) allowed=__no_owned_dri_driver_at_this_boundary__ ;;
    esac
    foreign_dri=$(find "$directory" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type l \) -name '*_dri.so*' ! -name "$allowed" -print -quit)
    [ -z "$foreign_dri" ] \
        || fatal "foreign Mesa DRI driver: ${foreign_dri#"${rootfs}"}"
done
echo 'open-gpu-stack drivers=PASS dri=zink vulkan=powervr foreign_drivers=absent'

default_rootfs_ldd() {
    chroot "$1" /lib/ld-linux-aarch64.so.1 --list "$2"
}

list_dependencies() {
    if [ -n "${PF_ROOTFS_LDD:-}" ]; then
        "$PF_ROOTFS_LDD" "$1" "$2"
    else
        default_rootfs_ldd "$1" "$2"
    fi
}

for binary in \
    glmark2-es2-drm \
    glmark2-es2-wayland \
    glmark2-es2 \
    eglinfo \
    es2gears_wayland \
    es2gears_x11 \
    kmscube \
    vkcube \
    vkcube-wayland \
    vulkaninfo; do
    binary_path="/usr/bin/${binary}"
    [ -x "${rootfs}${binary_path}" ] || fatal "required tool binary is missing or not executable: ${binary_path}"
    if ! closure=$(list_dependencies "$rootfs" "$binary_path" 2>&1); then
        printf '%s\n' "$closure" >&2
        fatal "dynamic dependency listing failed: ${binary_path}"
    fi
    printf '%s\n' "$closure" | grep -F 'not found' >/dev/null \
        && fatal "dynamic dependency is not found: ${binary_path}"

    owned_bindings=0
    for soname in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
        resolved=$(printf '%s\n' "$closure" | awk -v wanted="$soname" \
            '$1 == wanted && $2 == "=>" { print $3; exit }')
        [ -n "$resolved" ] || continue
        case "$resolved" in
            /usr/local/lib/*) owned_bindings=$((owned_bindings + 1)) ;;
            *) fatal "${binary_path} resolves ${soname} outside gpu-um-tsp: ${resolved}" ;;
        esac
    done
    case "$binary" in
        eglinfo|es2gears_wayland|es2gears_x11|kmscube)
            [ "$owned_bindings" -gt 0 ] \
                || fatal "${binary_path} has no dynamic binding to gpu-um-tsp EGL/GLES/GBM"
            ;;
        vkcube|vkcube-wayland|vulkaninfo)
            printf '%s\n' "$closure" | grep -Fq 'libvulkan.so.1' \
                || fatal "${binary_path} does not bind the Vulkan loader"
            ;;
    esac
    echo "open-gpu-tool=PASS binary=${binary_path} owned_bindings=${owned_bindings}"
    printf '%s\n' "$closure"
done

echo 'open-gpu-tools=PASS stack=gpu-um-tsp gles=zink vulkan=powervr'
