#!/usr/bin/env bash
# Produce and verify the read-only GE8300 Gamescope compute-pipeline FOZ cache.
set -euo pipefail

if (( $# != 4 )); then
    echo 'usage: produce-gamescope-pvr-cache.sh GPU_UM_SOURCE BUILD_DIR OUTPUT_ROOT GAMESCOPE_SHA' >&2
    exit 2
fi

source_root=$1
build_dir=$2
output_root=$3
gamescope_sha=$4
expected_gamescope_sha=4232739e75c95113871e260967e8b4ff995ea897
cache_name=pocketforge-gamescope-ge8300
cache_limit_bytes=16777216
timeout_seconds=${PF_GAMESCOPE_CACHE_TIMEOUT_SECONDS:-900}
qemu=${QEMU_AARCH64:-/usr/bin/qemu-aarch64-static}
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/gamescope-pvr-cache.XXXXXX")

cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

case "${timeout_seconds}" in
    ''|*[!0-9]*|0) echo 'PF_GAMESCOPE_CACHE_TIMEOUT_SECONDS must be a positive integer' >&2; exit 2 ;;
esac
[ "${gamescope_sha}" = "${expected_gamescope_sha}" ] || {
    echo "Gamescope source ${gamescope_sha} does not match cache corpus ${expected_gamescope_sha}" >&2
    exit 1
}
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"

fixture_dir=${source_root}/ci/pco-gamescope/spirv
verifier=${source_root}/ci/pco-gamescope/verify-binaries.py
binary_manifest=${source_root}/ci/pco-gamescope/gamescope-binaries.sha256
shim=${build_dir}/src/imagination/drm-shim/libpowervr_noop_drm_shim.so
icd=${build_dir}/src/imagination/vulkan/powervr_mesa_devenv_icd.aarch64.json
icd_so=${build_dir}/src/imagination/vulkan/libvulkan_powervr_mesa.so
harness=${scratch}/pco-gamescope-pipelines
output_dir=${output_root}/usr/share/pocketforge/mesa-cache

for input in "${verifier}" "${binary_manifest}" "${shim}" "${icd}" "${icd_so}"; do
    [ -f "${input}" ] || { echo "Gamescope cache input is missing: ${input}" >&2; exit 1; }
done
[ -x "${qemu}" ] || { echo "qemu-aarch64-static is missing: ${qemu}" >&2; exit 1; }
sha256sum --check --strict "${source_root}/ci/pco-gamescope/spirv.sha256"

aarch64-linux-gnu-gcc -std=c11 -O2 -Wall -Wextra -Werror \
    "${source_root}/ci/pco-gamescope/gamescope-pipelines.c" \
    -o "${harness}" -lvulkan
readelf -h "${harness}" | grep -Eq 'Machine:[[:space:]]+AArch64'

run_target() {
    local cache_root=$1
    local log=$2
    local single_file=$3
    local ro_name=$4
    local max_pipelines=$5
    local -a target_args=("${harness}" "${fixture_dir}")

    if [ -n "${max_pipelines}" ]; then
        target_args+=("${max_pipelines}")
    fi

    timeout --signal=TERM "${timeout_seconds}s" \
        "${qemu}" -L / \
        -E "LD_PRELOAD=${shim}" \
        -E "VK_ICD_FILENAMES=${icd}" \
        -E PVR_SHIM_DEVICE_BVNC=22.102.54.38 \
        -E "MESA_SHADER_CACHE_DIR=${cache_root}" \
        -E MESA_SHADER_CACHE_SHOW_STATS=true \
        -E "MESA_DISK_CACHE_SINGLE_FILE=${single_file}" \
        -E "MESA_DISK_CACHE_COMBINE_RW_WITH_RO_FOZ=$([ -n "${ro_name}" ] && printf 1 || printf 0)" \
        -E "MESA_DISK_CACHE_READ_ONLY_FOZ_DBS=${ro_name}" \
        -E PCO_DEBUG_PRINT=binary \
        "${target_args[@]}" >"${log}" 2>&1
}

seed_pair() {
    local number=$1
    local cache_root=${scratch}/seed-${number}
    local log=${scratch}/seed-${number}.log
    local data_file
    local index_file
    local relative_dir

    mkdir -p "${cache_root}"
    run_target "${cache_root}" "${log}" 1 '' ''
    python3 "${verifier}" gamescope "${log}" "${binary_manifest}"
    grep -F 'disk shader cache:  hits = 0, misses = 108' "${log}" >/dev/null || {
        tail -n 40 "${log}" >&2
        echo "seed ${number} did not compile and cache all 108 pipelines" >&2
        exit 1
    }

    mapfile -t data_files < <(find "${cache_root}" -type f -name foz_cache.foz -print)
    mapfile -t index_files < <(find "${cache_root}" -type f -name foz_cache_idx.foz -print)
    if [ "${#data_files[@]}" -ne 1 ] || [ "${#index_files[@]}" -ne 1 ]; then
        echo "seed ${number} did not create exactly one FOZ pair" >&2
        exit 1
    fi
    data_file=${data_files[0]}
    index_file=${index_files[0]}
    [ "$(dirname "${data_file}")" = "$(dirname "${index_file}")" ] || {
        echo "seed ${number} FOZ data and index directories differ" >&2
        exit 1
    }
    relative_dir=${data_file#"${cache_root}"/}
    relative_dir=${relative_dir%/foz_cache.foz}
    [[ "${relative_dir}" =~ ^mesa_shader_cache_sf/[0-9a-f]{64}/[0-9a-f]{64}$ ]] || {
        echo "seed ${number} produced invalid Mesa cache directory: ${relative_dir}" >&2
        exit 1
    }

    install -m 0644 "${data_file}" "${scratch}/seed-${number}.foz"
    install -m 0644 "${index_file}" "${scratch}/seed-${number}_idx.foz"
    printf '%s\n' "${relative_dir}" >"${scratch}/seed-${number}.relative-dir"
}

umask 077
export LC_ALL=C
seed_pair 1
seed_pair 2
cmp "${scratch}/seed-1.foz" "${scratch}/seed-2.foz"
cmp "${scratch}/seed-1_idx.foz" "${scratch}/seed-2_idx.foz"
cmp "${scratch}/seed-1.relative-dir" "${scratch}/seed-2.relative-dir"

relative_dir=$(cat "${scratch}/seed-1.relative-dir")
replay_root=${scratch}/replay
replay_foz_dir=${replay_root}/${relative_dir}
mkdir -p "${replay_foz_dir}"
ln -s "${scratch}/seed-1.foz" "${replay_foz_dir}/${cache_name}.foz"
ln -s "${scratch}/seed-1_idx.foz" "${replay_foz_dir}/${cache_name}_idx.foz"
run_target "${replay_root}" "${scratch}/replay.log" 0 "${cache_name}" ''
python3 "${verifier}" gamescope-cache-hit "${scratch}/replay.log"
grep -F 'disk shader cache:  hits = 108, misses = 0' "${scratch}/replay.log" >/dev/null || {
    tail -n 40 "${scratch}/replay.log" >&2
    echo 'read-only FOZ replay did not hit all 108 pipelines' >&2
    exit 1
}

# Fail-open negative: an absent RO database must compile a real pipeline into
# the normal writable cache instead of failing pipeline creation.
negative_root=${scratch}/negative
mkdir -p "${negative_root}"
run_target "${negative_root}" "${scratch}/negative.log" 0 invalidated-gamescope-cache 1
grep -F 'disk shader cache:  hits = 0, misses = 1' "${scratch}/negative.log" >/dev/null
grep -F 'SUMMARY,compiled,1,' "${scratch}/negative.log" >/dev/null
[ "$(grep -Fc 'shader binary after encoding:' "${scratch}/negative.log")" -eq 1 ] || {
    echo 'invalidated-cache control did not compile exactly one pipeline' >&2
    exit 1
}

combined_size=$(stat -c %s "${scratch}/seed-1.foz")
combined_size=$((combined_size + $(stat -c %s "${scratch}/seed-1_idx.foz")))
[ "${combined_size}" -le "${cache_limit_bytes}" ] || {
    echo "Gamescope PVR cache exceeds ${cache_limit_bytes} bytes: ${combined_size}" >&2
    exit 1
}

install -d -m 0755 "${output_dir}"
install -m 0644 "${scratch}/seed-1.foz" "${output_dir}/${cache_name}.foz"
install -m 0644 "${scratch}/seed-1_idx.foz" "${output_dir}/${cache_name}_idx.foz"
install -m 0644 "${scratch}/seed-1.relative-dir" "${output_dir}/${cache_name}.relative-dir"
find "${output_dir}" -type f -exec touch -d "@${SOURCE_DATE_EPOCH}" {} +

driver_sha=$(sha256sum "${icd_so}" | cut -d' ' -f1)
driver_build_id=$(readelf -n "${icd_so}" | sed -n 's/.*Build ID: //p' | head -n 1)
[ -n "${driver_build_id}" ] || { echo 'final AArch64 ICD has no ELF build id' >&2; exit 1; }
qemu_version=$("${qemu}" --version | sed -n '1p')
qemu_package=$(dpkg-query -W -f='${Package}=${Version}' qemu-user-static)
corpus_sha=$(sha256sum "${source_root}/ci/pco-gamescope/spirv.sha256" | cut -d' ' -f1)
{
    printf 'cache=%s bvnc=22.102.54.38 gamescope=%s corpus_manifest_sha256=%s\n' \
        "${cache_name}" "${gamescope_sha}" "${corpus_sha}"
    printf 'driver_sha256=%s driver_build_id=%s relative_dir=%s\n' \
        "${driver_sha}" "${driver_build_id}" "${relative_dir}"
    printf 'qemu_package=%s qemu_version=%s\n' "${qemu_package}" "${qemu_version}"
    printf 'meson_tools=drm-shim seeds=byte-identical replay_hits=108 replay_misses=0 invalidated_misses=1 size_bytes=%s\n' \
        "${combined_size}"
} >"${output_root}/.pf-gamescope-pvr-cache-provenance"
touch -d "@${SOURCE_DATE_EPOCH}" "${output_root}/.pf-gamescope-pvr-cache-provenance"

echo "gamescope-pvr-cache=PASS pipelines=108 replay_hits=108 size_bytes=${combined_size} relative_dir=${relative_dir}"
