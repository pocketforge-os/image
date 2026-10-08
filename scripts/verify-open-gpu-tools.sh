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
    libgbm1 \
    libosmesa6 \
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
    usr/local/lib/libEGL_mesa.so.0 \
    usr/local/lib/libGLX_mesa.so.0 \
    usr/local/lib/libgbm.so.1 \
    usr/local/lib/libgallium_dri.so \
    usr/local/lib/libvulkan_powervr_mesa.so; do
    verify_owned_artifact "$artifact"
done

# gpu-um-tsp's pinned Mesa builds Zink into unified Gallium DRI megadrivers.
# Bind that producer identity to the rootfs alongside the megadriver hash.
producer_provenance="${producer}/.pf-gpu-um-provenance"
rootfs_provenance="${rootfs}/usr/share/pocketforge/gpu-um-mesa-provenance"
if [ ! -f "$producer_provenance" ] || [ -L "$producer_provenance" ]; then
    fatal 'gpu-um-tsp producer provenance is missing or not a regular file'
fi
if [ ! -f "$rootfs_provenance" ] || [ -L "$rootfs_provenance" ]; then
    fatal 'rootfs gpu-um-tsp provenance is missing or not a regular file'
fi
producer_provenance_hash=$(sha256sum "$producer_provenance" | awk '{ print $1 }')
rootfs_provenance_hash=$(sha256sum "$rootfs_provenance" | awk '{ print $1 }')
[ "$producer_provenance_hash" = "$rootfs_provenance_hash" ] \
    || fatal "gpu-um-tsp provenance hash mismatch: producer=${producer_provenance_hash} rootfs=${rootfs_provenance_hash}"
grep -Eq '^gpu-um-tsp@[0-9a-f]{40} \(open Mesa GLX/GLES/EGL/GBM/Vulkan userspace, GE8300 Zink\)$' \
    "$producer_provenance" \
    || fatal 'gpu-um-tsp producer provenance does not identify the GE8300 Zink stack'
echo "open-gpu-stack provenance=PASS driver=zink artifact=libgallium_dri.so sha256=${rootfs_provenance_hash}"

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
        usr/share/vulkan/icd.d)
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
    if [ "$boundary" = usr/local/lib/dri ]; then
        producer_directory="${producer}/${boundary}"
        [ -d "$producer_directory" ] && [ ! -L "$producer_directory" ] \
            || fatal "gpu-um-tsp DRI producer boundary is missing or not a real directory: /${boundary}"

        # Mesa installs libdril_dri.so plus hardware-name and zink aliases in
        # its configured prefix. They are owned only when the copied rootfs
        # tree is an exact mirror of the pinned gpu-um-tsp producer: regular
        # files retain their hash and symlinks retain both kind and target.
        # Anything else in this loader boundary can shadow the owned stack.
        dri_entry_count=0
        for rootfs_entry in "$directory"/*_dri.so*; do
            [ -e "$rootfs_entry" ] || [ -L "$rootfs_entry" ] || continue
            name=${rootfs_entry##*/}
            producer_entry="${producer_directory}/${name}"
            [ -e "$producer_entry" ] || [ -L "$producer_entry" ] \
                || fatal "foreign Mesa DRI driver: ${rootfs_entry#"${rootfs}"} reason=absent-from-gpu-um-tsp-producer"
            if [ -L "$rootfs_entry" ]; then
                [ -L "$producer_entry" ] \
                    || fatal "gpu-um-tsp DRI artifact mismatch: /${boundary}/${name} rootfs=symlink producer=non-symlink"
                rootfs_target=$(readlink "$rootfs_entry")
                producer_target=$(readlink "$producer_entry")
                [ "$rootfs_target" = "$producer_target" ] \
                    || fatal "gpu-um-tsp DRI artifact mismatch: /${boundary}/${name} rootfs_target=${rootfs_target} producer_target=${producer_target}"
            else
                [ -f "$rootfs_entry" ] && [ -f "$producer_entry" ] && [ ! -L "$producer_entry" ] \
                    || fatal "gpu-um-tsp DRI artifact mismatch: /${boundary}/${name} rootfs=regular producer=non-regular"
                rootfs_hash=$(sha256sum "$rootfs_entry" | awk '{ print $1 }')
                producer_hash=$(sha256sum "$producer_entry" | awk '{ print $1 }')
                [ "$rootfs_hash" = "$producer_hash" ] \
                    || fatal "gpu-um-tsp DRI artifact mismatch: /${boundary}/${name} rootfs_sha256=${rootfs_hash} producer_sha256=${producer_hash}"
            fi
            dri_entry_count=$((dri_entry_count + 1))
        done

        for producer_entry in "$producer_directory"/*_dri.so*; do
            [ -e "$producer_entry" ] || [ -L "$producer_entry" ] || continue
            name=${producer_entry##*/}
            rootfs_entry="${directory}/${name}"
            [ -e "$rootfs_entry" ] || [ -L "$rootfs_entry" ] \
                || fatal "gpu-um-tsp DRI artifact missing from rootfs: /${boundary}/${name}"
        done
        [ "$dri_entry_count" -gt 0 ] \
            || fatal "gpu-um-tsp DRI producer boundary contains no driver artifacts: /${boundary}"
        echo "open-gpu-stack dri-artifacts=PASS boundary=/${boundary} producer_entries=${dri_entry_count}"
        continue
    fi
    foreign_dri=$(find "$directory" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type l \) -name '*_dri.so*' -print -quit)
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

binary_embeds_soname() {
    LC_ALL=C grep -aF "$2" "$1" >/dev/null
}

glvnd_egl_witness=0
glvnd_gles_witness=0
vulkan_loader_witness=0

for binary in \
    eglinfo \
    es2gears_wayland \
    es2gears_x11 \
    kmscube \
    glmark2-es2-drm \
    glmark2-es2-wayland \
    glmark2-es2 \
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

    routed_bindings=0
    glvnd_egl_binding=0
    glvnd_gles_binding=0
    owned_gbm_binding=0
    binding_mode=direct
    for soname in libEGL.so.1 libGLESv2.so.2 libgbm.so.1; do
        resolved=$(printf '%s\n' "$closure" | awk -v wanted="$soname" \
            '$1 == wanted && $2 == "=>" { print $3; exit }')
        [ -n "$resolved" ] || continue
        case "$soname" in
            libgbm.so.1)
                case "$resolved" in
                    /usr/local/lib/*)
                        routed_bindings=$((routed_bindings + 1))
                        owned_gbm_binding=1
                        ;;
                    *) fatal "${binary_path} resolves libgbm.so.1 outside gpu-um-tsp: ${resolved}" ;;
                esac
                ;;
            libEGL.so.1)
                case "$resolved" in
                    /usr/lib/aarch64-linux-gnu/*|/lib/aarch64-linux-gnu/*)
                        routed_bindings=$((routed_bindings + 1))
                        glvnd_egl_binding=1
                        glvnd_egl_witness=1
                        ;;
                    *) fatal "${binary_path} resolves libEGL.so.1 outside neutral GLVND: ${resolved}" ;;
                esac
                ;;
            libGLESv2.so.2)
                case "$resolved" in
                    /usr/lib/aarch64-linux-gnu/*|/lib/aarch64-linux-gnu/*)
                        routed_bindings=$((routed_bindings + 1))
                        glvnd_gles_binding=1
                        glvnd_gles_witness=1
                        ;;
                    *) fatal "${binary_path} resolves libGLESv2.so.2 outside neutral GLVND: ${resolved}" ;;
                esac
                ;;
        esac
    done
    case "$binary" in
        eglinfo|es2gears_wayland|es2gears_x11|kmscube)
            [ "$glvnd_egl_binding" -eq 1 ] || [ "$glvnd_gles_binding" -eq 1 ] || \
                [ "$owned_gbm_binding" -eq 1 ] \
                || fatal "${binary_path} has no dynamic binding to GLVND EGL/GLES or gpu-um-tsp GBM"
            binding_mode=direct-glvnd-owned-vendor
            ;;
        glmark2-es2-drm)
            [ "$owned_gbm_binding" -eq 1 ] \
                || fatal "${binary_path} has no dynamic binding to gpu-um-tsp GBM"
            binding_mode=direct-owned-gbm
            ;;
        glmark2-es2-wayland|glmark2-es2)
            if [ "$glvnd_egl_witness" -ne 1 ] || [ "$glvnd_gles_witness" -ne 1 ]; then
                fatal "${binary_path} has no same-rootfs neutral GLVND EGL/GLES resolution witness"
            fi
            for soname in libEGL.so.1 libGLESv2.so.2; do
                binary_embeds_soname "${rootfs}${binary_path}" "$soname" \
                    || fatal "${binary_path} does not declare runtime loading of ${soname}"
            done
            binding_mode=runtime-glvnd-egl-gles-owned-vendor
            ;;
        vkcube|vkcube-wayland)
            printf '%s\n' "$closure" | grep -Fq 'libvulkan.so.1' \
                || fatal "${binary_path} does not bind the Vulkan loader"
            vulkan_loader_witness=1
            binding_mode=direct-vulkan-loader
            ;;
        vulkaninfo)
            if printf '%s\n' "$closure" | grep -Fq 'libvulkan.so.1'; then
                vulkan_loader_witness=1
                binding_mode=direct-vulkan-loader
            else
                [ "$vulkan_loader_witness" -eq 1 ] \
                    || fatal "${binary_path} has no same-rootfs Vulkan loader resolution witness"
                binary_embeds_soname "${rootfs}${binary_path}" libvulkan.so.1 \
                    || fatal "${binary_path} does not declare runtime loading of libvulkan.so.1"
                binding_mode=runtime-vulkan-loader
            fi
            ;;
    esac
    echo "open-gpu-tool=PASS binary=${binary_path} binding_mode=${binding_mode} routed_bindings=${routed_bindings}"
    printf '%s\n' "$closure"
done

echo 'open-gpu-tools=PASS stack=gpu-um-tsp egl=glvnd:mesa glx=glvnd:mesa gles=zink vulkan=powervr'
