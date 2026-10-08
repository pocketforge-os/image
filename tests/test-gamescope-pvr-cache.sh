#!/usr/bin/env bash
# Hermetic contract for the image-built GE8300 Gamescope compute-pipeline cache.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dockerfile=${root}/build/Dockerfile.pf
producer=${root}/build/produce-gamescope-pvr-cache.sh
packager=${root}/build/package-open-gpu-stack.sh
installer=${root}/scripts/install-gamescope-pvr-cache.sh
rootfs_builder=${root}/scripts/build-rootfs.sh
unit=${root}/rootfs-overlay/etc/systemd/system/pf-shell-selected.service
workflow=${root}/.github/workflows/hermetic-tests.yml
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/gamescope-pvr-cache-test.XXXXXX")

cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

[ -x "${producer}" ] || {
    echo "FAIL: Gamescope PVR cache producer is missing or not executable: ${producer}" >&2
    exit 1
}
[ -x "${installer}" ] || {
    echo "FAIL: Gamescope PVR cache installer is missing or not executable: ${installer}" >&2
    exit 1
}
bash -n "${producer}"
sh -n "${installer}"

# The producer must execute the target AArch64 harness explicitly with the
# final cross-built ICD, target drm-shim, exact GE8300 BVNC, and pinned corpus.
grep -F 'qemu-user-static' "${dockerfile}" >/dev/null
grep -F 'qemu-aarch64-static' "${producer}" >/dev/null
grep -F -- '-Dtools=drm-shim' "${dockerfile}" >/dev/null
grep -F 'produce-gamescope-pvr-cache.sh' "${dockerfile}" >/dev/null
grep -F 'PF_GAMESCOPE_SHA' "${dockerfile}" >/dev/null
grep -F '22.102.54.38' "${producer}" >/dev/null
grep -F '4232739e75c95113871e260967e8b4ff995ea897' "${producer}" >/dev/null
grep -F 'MESA_DISK_CACHE_SINGLE_FILE=${single_file}' "${producer}" >/dev/null
grep -F 'MESA_DISK_CACHE_COMBINE_RW_WITH_RO_FOZ=$(' "${producer}" >/dev/null
grep -F 'MESA_DISK_CACHE_READ_ONLY_FOZ_DBS=${ro_name}' "${producer}" >/dev/null
grep -F 'run_target "${replay_root}" "${scratch}/replay.log" 0 "${cache_name}"' "${producer}" >/dev/null
grep -F 'gamescope-cache-hit' "${producer}" >/dev/null
grep -F 'cmp ' "${producer}" >/dev/null
grep -F '16777216' "${producer}" >/dev/null

# The generated pair and provenance are package-owned, never copied around
# dpkg by the rootfs builder.
for name in \
    pocketforge-gamescope-ge8300.foz \
    pocketforge-gamescope-ge8300_idx.foz \
    pocketforge-gamescope-ge8300.relative-dir; do
    grep -F "${name}" "${packager}" >/dev/null
done
grep -F '.pf-gamescope-pvr-cache-provenance' "${packager}" >/dev/null

# Runtime discovery is scoped to the selected compositor service. It must not
# become a global image environment export and must preserve Mesa's normal RW
# cache by leaving MESA_SHADER_CACHE_DIR unset.
grep -Fx 'Environment=MESA_DISK_CACHE_COMBINE_RW_WITH_RO_FOZ=1' "${unit}" >/dev/null
grep -Fx 'Environment=MESA_DISK_CACHE_READ_ONLY_FOZ_DBS=pocketforge-gamescope-ge8300' "${unit}" >/dev/null
if grep -R -E '^[[:space:]]*(export[[:space:]]+)?MESA_DISK_CACHE_(COMBINE_RW_WITH_RO_FOZ|READ_ONLY_FOZ_DBS)=' \
    "${root}/rootfs-overlay" "${root}/scripts" --exclude='install-gamescope-pvr-cache.sh' >/dev/null; then
    echo 'FOZ cache variables escaped the compositor service scope' >&2
    exit 1
fi
if grep -F 'MESA_SHADER_CACHE_DIR=' "${unit}" >/dev/null; then
    echo 'compositor service must retain Mesa default per-user writable cache path' >&2
    exit 1
fi

grep -F '/work/src/scripts/install-gamescope-pvr-cache.sh "${ROOTFS}"' "${rootfs_builder}" >/dev/null
user_line=$(grep -nF 'useradd -u 1000 -g 1000 -m -d /home/gamer' "${rootfs_builder}" | cut -d: -f1)
install_line=$(grep -nF '/work/src/scripts/install-gamescope-pvr-cache.sh "${ROOTFS}"' "${rootfs_builder}" | cut -d: -f1)
test "${install_line}" -gt "${user_line}"
grep -F 'tests/test-gamescope-pvr-cache.sh' "${workflow}" >/dev/null

# Exercise the rootfs installer with the real Mesa cache directory shape. The
# build ids are intentionally synthetic but exact-length lowercase hex.
rootfs=${scratch}/rootfs
cache=${rootfs}/usr/share/pocketforge/mesa-cache
driver_id=$(printf 'a%.0s' {1..64})
device_id=$(printf 'b%.0s' {1..64})
relative_dir="mesa_shader_cache_sf/${driver_id}/${device_id}"
install -d "${cache}" "${rootfs}/home/gamer"
printf 'foz-data\n' >"${cache}/pocketforge-gamescope-ge8300.foz"
printf 'foz-index\n' >"${cache}/pocketforge-gamescope-ge8300_idx.foz"
printf '%s\n' "${relative_dir}" >"${cache}/pocketforge-gamescope-ge8300.relative-dir"

PF_CACHE_UID=$(id -u) PF_CACHE_GID=$(id -g) "${installer}" "${rootfs}"
runtime_dir=${rootfs}/home/gamer/.cache/${relative_dir}
test "$(stat -c %a "${rootfs}/home/gamer/.cache/mesa_shader_cache_sf")" = 700
test "$(stat -c %a "${runtime_dir}")" = 700
test "$(stat -c %u:%g "${runtime_dir}")" = "$(id -u):$(id -g)"
test "$(stat -c %u:%g "${runtime_dir}/pocketforge-gamescope-ge8300.foz")" = \
    "$(id -u):$(id -g)"
test "$(stat -c %u:%g "${runtime_dir}/pocketforge-gamescope-ge8300_idx.foz")" = \
    "$(id -u):$(id -g)"
test "$(readlink "${runtime_dir}/pocketforge-gamescope-ge8300.foz")" = \
    /usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300.foz
test "$(readlink "${runtime_dir}/pocketforge-gamescope-ge8300_idx.foz")" = \
    /usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300_idx.foz

# Real negative control: untrusted producer metadata cannot escape gamer's
# cache tree. A rejection is required; a partial install is not accepted.
printf '../escape\n' >"${cache}/pocketforge-gamescope-ge8300.relative-dir"
if PF_CACHE_UID=$(id -u) PF_CACHE_GID=$(id -g) "${installer}" "${rootfs}" \
    >"${scratch}/negative.log" 2>&1; then
    echo 'installer accepted path-traversal cache metadata' >&2
    exit 1
fi
grep -F 'invalid Gamescope PVR cache relative directory' "${scratch}/negative.log" >/dev/null
test ! -e "${rootfs}/home/gamer/escape"

echo 'PASS: Gamescope PVR FOZ producer, package, service scope, and rootfs layout contract'
