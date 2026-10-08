#!/bin/sh
# Link the package-owned read-only Gamescope FOZ pair into Mesa's per-user path.
set -eu

if [ "$#" -ne 1 ]; then
    echo 'usage: install-gamescope-pvr-cache.sh ROOTFS' >&2
    exit 2
fi

rootfs=$1
uid=${PF_CACHE_UID:-1000}
gid=${PF_CACHE_GID:-1000}
system_dir=/usr/share/pocketforge/mesa-cache
host_system_dir=${rootfs}${system_dir}
cache_name=pocketforge-gamescope-ge8300
metadata=${host_system_dir}/${cache_name}.relative-dir

for file in \
    "${host_system_dir}/${cache_name}.foz" \
    "${host_system_dir}/${cache_name}_idx.foz" \
    "${metadata}"; do
    if [ ! -f "${file}" ] || [ -L "${file}" ]; then
        echo "Gamescope PVR cache package file is missing or not regular: ${file}" >&2
        exit 1
    fi
done

relative_dir=$(cat "${metadata}")
case "${relative_dir}" in
    mesa_shader_cache_sf/[0-9a-f][0-9a-f]*/*) ;;
    *)
        echo "invalid Gamescope PVR cache relative directory: ${relative_dir}" >&2
        exit 1
        ;;
esac
# Enforce the exact Mesa-generated form, not merely the shell pattern above.
driver_id=${relative_dir#mesa_shader_cache_sf/}
device_id=${driver_id#*/}
driver_id=${driver_id%%/*}
if [ "${#driver_id}" -ne 64 ] || [ "${#device_id}" -ne 64 ] || \
    printf '%s%s' "${driver_id}" "${device_id}" | grep -Eq '[^0-9a-f]'; then
    echo "invalid Gamescope PVR cache relative directory: ${relative_dir}" >&2
    exit 1
fi

runtime_root=${rootfs}/home/gamer/.cache
runtime_dir=${runtime_root}/${relative_dir}
install -d -o "${uid}" -g "${gid}" -m 0700 \
    "${runtime_root}" \
    "${runtime_root}/mesa_shader_cache_sf" \
    "${runtime_root}/mesa_shader_cache_sf/${driver_id}" \
    "${runtime_dir}"
ln -sfn "${system_dir}/${cache_name}.foz" "${runtime_dir}/${cache_name}.foz"
ln -sfn "${system_dir}/${cache_name}_idx.foz" "${runtime_dir}/${cache_name}_idx.foz"
chown -h "${uid}:${gid}" \
    "${runtime_dir}/${cache_name}.foz" \
    "${runtime_dir}/${cache_name}_idx.foz"

echo "gamescope-pvr-cache-layout=PASS relative_dir=${relative_dir} owner=${uid}:${gid}"
