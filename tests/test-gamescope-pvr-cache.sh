#!/usr/bin/env bash
# Hermetic contract for the image-built GE8300 Gamescope compute-pipeline cache.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dockerfile=${root}/build/Dockerfile.pf
producer=${root}/build/produce-gamescope-pvr-cache.sh
mode_runner=${root}/build/run-gamescope-pvr-cache.sh
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
[ -x "${mode_runner}" ] || {
    echo "FAIL: Gamescope PVR cache mode runner is missing or not executable: ${mode_runner}" >&2
    exit 1
}
[ -x "${installer}" ] || {
    echo "FAIL: Gamescope PVR cache installer is missing or not executable: ${installer}" >&2
    exit 1
}
bash -n "${producer}"
sh -n "${mode_runner}"
sh -n "${installer}"

# The no-radio profile has no [gamescope] table, so its recorded buildargs omit
# PF_GAMESCOPE_SHA. It must produce an explicit absence marker without invoking
# the expensive cache producer or materializing cache artifacts.
unset PF_GAMESCOPE_MODE PF_GAMESCOPE_SHA
set -a
# shellcheck source=tests/fixtures/gamescope-no-profile-buildargs.env
source "${root}/tests/fixtures/gamescope-no-profile-buildargs.env"
set +a
test "${PF_DEVICE_ID}" = a133-open-7x-gpu-noradio
test "${PF_GPU_MODEL}" = open
fake_producer=${scratch}/fake-producer
cat >"${fake_producer}" <<'EOF'
#!/bin/sh
set -eu
printf 'producer-called\n' >>"${PRODUCER_CALLS:?}"
printf 'gamescope=%s cache=fixture\n' "$4" >"$3/.pf-gamescope-pvr-cache-provenance"
EOF
chmod 0755 "${fake_producer}"
calls=${scratch}/producer-calls
absent_root=${scratch}/absent
mkdir -p "${absent_root}"
SOURCE_DATE_EPOCH=1700000000 PRODUCER_CALLS=${calls} "${mode_runner}" \
    "${PF_GAMESCOPE_MODE:-not-shipped}" "${fake_producer}" source build "${absent_root}" \
    "${PF_GAMESCOPE_SHA:-}"
test ! -e "${calls}"
grep -Fx 'gamescope=absent cache=absent' \
    "${absent_root}/.pf-gamescope-pvr-cache-provenance" >/dev/null
test ! -e "${absent_root}/usr/share/pocketforge/mesa-cache"

# g1 is fail-closed on an absent, short, uppercase or non-hex source SHA. The
# positive control reaches the same producer with the same four arguments.
for invalid_sha in '' abcdef ABCDEF1234567890ABCDEF1234567890ABCDEF12 \
    1234567890abcdef1234567890abcdef1234567g; do
    if SOURCE_DATE_EPOCH=1700000000 PRODUCER_CALLS=${calls} "${mode_runner}" g1 "${fake_producer}" \
        source build "${scratch}/invalid" "${invalid_sha}" \
        >"${scratch}/invalid.log" 2>&1; then
        echo "mode runner accepted invalid g1 source SHA: ${invalid_sha:-empty}" >&2
        exit 1
    fi
done
test ! -e "${calls}"
g1_sha=cf4475a73409295b06ec352f18497fef23422a72
g1_root=${scratch}/g1
mkdir -p "${g1_root}"
SOURCE_DATE_EPOCH=1700000000 PRODUCER_CALLS=${calls} "${mode_runner}" g1 "${fake_producer}" \
    source build "${g1_root}" "${g1_sha}"
test "$(wc -l <"${calls}")" -eq 1
grep -Fx "gamescope=${g1_sha} cache=fixture" \
    "${g1_root}/.pf-gamescope-pvr-cache-provenance" >/dev/null
calls_before=$(wc -l <"${calls}")
if SOURCE_DATE_EPOCH=1700000000 PRODUCER_CALLS=${calls} "${mode_runner}" \
    not-shipped "${fake_producer}" source build "${scratch}/unexpected-sha" \
    "${g1_sha}" >"${scratch}/unexpected-sha.log" 2>&1; then
    echo 'mode runner accepted a source SHA for gamescope=not-shipped' >&2
    exit 1
fi
test "$(wc -l <"${calls}")" -eq "${calls_before}"
stale_root=${scratch}/stale
mkdir -p "${stale_root}/usr/share/pocketforge/mesa-cache"
if SOURCE_DATE_EPOCH=1700000000 PRODUCER_CALLS=${calls} "${mode_runner}" \
    not-shipped "${fake_producer}" source build "${stale_root}" '' \
    >"${scratch}/stale.log" 2>&1; then
    echo 'mode runner accepted a pre-existing cache for gamescope=not-shipped' >&2
    exit 1
fi
test ! -e "${stale_root}/.pf-gamescope-pvr-cache-provenance"
test "$(wc -l <"${calls}")" -eq "${calls_before}"
linked_root=${scratch}/linked
mkdir -p "${linked_root}/usr/share/pocketforge"
ln -s "${scratch}/missing-cache" \
    "${linked_root}/usr/share/pocketforge/mesa-cache"
if SOURCE_DATE_EPOCH=1700000000 PRODUCER_CALLS=${calls} "${mode_runner}" \
    not-shipped "${fake_producer}" source build "${linked_root}" '' \
    >"${scratch}/linked.log" 2>&1; then
    echo 'mode runner accepted a dangling cache symlink for gamescope=not-shipped' >&2
    exit 1
fi
test ! -e "${linked_root}/.pf-gamescope-pvr-cache-provenance"
test "$(wc -l <"${calls}")" -eq "${calls_before}"
if SOURCE_DATE_EPOCH=1700000000 PRODUCER_CALLS=${calls} "${mode_runner}" future "${fake_producer}" \
    source build "${scratch}/future" "${g1_sha}" \
    >"${scratch}/future.log" 2>&1; then
    echo 'mode runner accepted an unknown Gamescope mode' >&2
    exit 1
fi
test "$(wc -l <"${calls}")" -eq "${calls_before}"

# The producer must execute the target AArch64 harness explicitly with the
# final cross-built ICD, target drm-shim, exact GE8300 BVNC, and pinned corpus.
grep -F 'qemu-user-static' "${dockerfile}" >/dev/null
grep -F 'qemu-aarch64-static' "${producer}" >/dev/null
grep -F -- '-Dtools=drm-shim' "${dockerfile}" >/dev/null
grep -F 'produce-gamescope-pvr-cache.sh' "${dockerfile}" >/dev/null
grep -F 'run-gamescope-pvr-cache.sh' "${dockerfile}" >/dev/null
grep -F 'ARG PF_GAMESCOPE_MODE=not-shipped' "${dockerfile}" >/dev/null
grep -F 'PF_GAMESCOPE_SHA' "${dockerfile}" >/dev/null
grep -F '22.102.54.38' "${producer}" >/dev/null
grep -F 'cf4475a73409295b06ec352f18497fef23422a72' "${producer}" >/dev/null
grep -F 'MESA_DISK_CACHE_SINGLE_FILE=${single_file}' "${producer}" >/dev/null
grep -F 'MESA_DISK_CACHE_COMBINE_RW_WITH_RO_FOZ=$(' "${producer}" >/dev/null
grep -F 'MESA_DISK_CACHE_READ_ONLY_FOZ_DBS=${ro_name}' "${producer}" >/dev/null
grep -F 'run_target "${replay_root}" "${scratch}/replay.log" 0 "${cache_name}"' "${producer}" >/dev/null
grep -F 'gamescope-cache-hit' "${producer}" >/dev/null
grep -F 'cmp ' "${producer}" >/dev/null
grep -F '16777216' "${producer}" >/dev/null
grep -F 'seed_pair 1 &' "${producer}" >/dev/null
grep -F 'seed_pair 2 &' "${producer}" >/dev/null
grep -F 'wait "${seed_1_pid}" || seed_status=$?' "${producer}" >/dev/null
grep -F 'wait "${seed_2_pid}" || seed_status=$?' "${producer}" >/dev/null
if grep -Fx 'seed_pair 1' "${producer}" >/dev/null ||
   grep -Fx 'seed_pair 2' "${producer}" >/dev/null; then
    echo 'Gamescope PVR seed compiles regressed to serial execution' >&2
    exit 1
fi

# Execute the production wait block with paired stubs. The positive control
# requires overlap (each seed observes the other's start marker), while the
# negative proves a background failure is returned after both waits complete.
seed_block=${scratch}/seed-block.sh
sed -n '/^seed_pair 1 &$/,/^cmp /p' "${producer}" | sed '$d' >"${seed_block}"
run_seed_control() {
    local fail_seed=$1
    local control_dir=$2
    PF_FAIL_SEED=${fail_seed} PF_CONTROL_DIR=${control_dir} bash -euo pipefail -c '
        seed_pair() {
            number=$1
            touch "${PF_CONTROL_DIR}/started-${number}"
            other=$((3 - number))
            for _ in $(seq 1 100); do
                [ ! -e "${PF_CONTROL_DIR}/started-${other}" ] || break
                sleep 0.01
            done
            [ -e "${PF_CONTROL_DIR}/started-${other}" ] || return 90
            touch "${PF_CONTROL_DIR}/finished-${number}"
            [ "${PF_FAIL_SEED}" != "${number}" ] || return 23
        }
        source "$1"
    ' _ "${seed_block}"
}
parallel_control=${scratch}/parallel-control
mkdir -p "${parallel_control}"
run_seed_control 0 "${parallel_control}"
test -e "${parallel_control}/finished-1"
test -e "${parallel_control}/finished-2"
failure_control=${scratch}/failure-control
mkdir -p "${failure_control}"
set +e
run_seed_control 2 "${failure_control}" >"${scratch}/seed-failure.log" 2>&1
seed_failure_rc=$?
set -e
test "${seed_failure_rc}" -eq 23
test -e "${failure_control}/finished-1"
test -e "${failure_control}/finished-2"
grep -F 'one or more Gamescope PVR cache seed compiles failed' \
    "${scratch}/seed-failure.log" >/dev/null

# Exercise the real producer around its fake-qemu seam. The fake cross compiler
# installs a host shell harness while fake qemu applies the target -E settings
# before executing it. PF_GAMESCOPE_LIMIT_TEST_CASES lets RED evidence run each
# contract independently against the pre-fix producer.
limit_source=${scratch}/limit-source
limit_build=${scratch}/limit-build
limit_fake_bin=${scratch}/limit-fake-bin
limit_harness=${scratch}/limit-harness
limit_fixture=${limit_source}/ci/pco-gamescope/spirv/fixture.spv
mkdir -p \
    "$(dirname "${limit_fixture}")" \
    "${limit_build}/src/imagination/drm-shim" \
    "${limit_build}/src/imagination/vulkan" \
    "${limit_fake_bin}"
printf 'fixture\n' >"${limit_fixture}"
printf '%s  %s\n' "$(sha256sum "${limit_fixture}" | cut -d' ' -f1)" \
    "${limit_fixture}" >"${limit_source}/ci/pco-gamescope/spirv.sha256"
printf 'fixture-manifest\n' \
    >"${limit_source}/ci/pco-gamescope/gamescope-binaries.sha256"
cat >"${limit_source}/ci/pco-gamescope/verify-binaries.py" <<'PY'
#!/usr/bin/env python3
import sys

sys.exit(0)
PY
touch "${limit_build}/src/imagination/drm-shim/libpowervr_noop_drm_shim.so"
printf '{}\n' \
    >"${limit_build}/src/imagination/vulkan/powervr_mesa_devenv_icd.aarch64.json"
printf 'fake-icd\n' \
    >"${limit_build}/src/imagination/vulkan/libvulkan_powervr_mesa.so"

cat >"${limit_harness}" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail

if [ "${MESA_DISK_CACHE_SINGLE_FILE:-}" = 1 ]; then
    case "${PF_TEST_HARNESS_MODE:?}" in
        slow)
            echo 'fake_harness_marker=wall_slow_cpu_cheap'
            sleep 2
            ;;
        cpu)
            echo 'fake_harness_marker=cpu_budget_exceeded'
            while :; do :; done
            ;;
        hang)
            echo 'fake_harness_marker=wall_backstop_exceeded'
            sleep 5
            ;;
        *)
            echo "unknown fake harness mode: ${PF_TEST_HARNESS_MODE}" >&2
            exit 2
            ;;
    esac
fi

driver_id=$(printf 'a%.0s' {1..64})
device_id=$(printf 'b%.0s' {1..64})
cache_dir=${MESA_SHADER_CACHE_DIR}/mesa_shader_cache_sf/${driver_id}/${device_id}
mkdir -p "${cache_dir}"
printf 'deterministic-foz\n' >"${cache_dir}/foz_cache.foz"
printf 'deterministic-index\n' >"${cache_dir}/foz_cache_idx.foz"
if [ "${MESA_DISK_CACHE_SINGLE_FILE:-}" = 1 ]; then
    echo 'disk shader cache:  hits = 0, misses = 108'
elif [ "$#" -eq 3 ]; then
    echo 'disk shader cache:  hits = 0, misses = 1'
    echo 'SUMMARY,compiled,1,fake'
    echo 'shader binary after encoding: fake'
else
    echo 'disk shader cache:  hits = 108, misses = 0'
fi
HARNESS
chmod 0755 "${limit_harness}"

cat >"${limit_fake_bin}/aarch64-linux-gnu-gcc" <<'EOF'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        output=$2
        break
    fi
    shift
done
: "${output:?fake gcc did not receive -o}"
install -m 0755 "${PF_TEST_HARNESS_TEMPLATE:?}" "${output}"
EOF
cat >"${limit_fake_bin}/readelf" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    -h) echo '  Machine:                           AArch64' ;;
    -n) echo '    Build ID: 0123456789abcdef' ;;
    *) exit 2 ;;
esac
EOF
cat >"${limit_fake_bin}/dpkg-query" <<'EOF'
#!/bin/sh
set -eu
echo 'qemu-user-static=fixture'
EOF
cat >"${limit_fake_bin}/fake-qemu-aarch64" <<'EOF'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in
        -L)
            shift 2
            ;;
        -E)
            case "$2" in
                LD_PRELOAD=*|VK_ICD_FILENAMES=*) ;;
                *) export "$2" ;;
            esac
            shift 2
            ;;
        *)
            break
            ;;
    esac
done
exec "$@"
EOF
chmod 0755 "${limit_fake_bin}"/*

run_limit_producer() {
    local mode=$1
    local legacy_wall=$2
    local wall=$3
    local cpu=$4
    local output=$5

    PATH="${limit_fake_bin}:${PATH}" \
    PF_TEST_HARNESS_TEMPLATE=${limit_harness} \
    PF_TEST_HARNESS_MODE=${mode} \
    PF_GAMESCOPE_CACHE_TIMEOUT_SECONDS=${legacy_wall} \
    PF_GAMESCOPE_CACHE_WALL_SECONDS=${wall} \
    PF_GAMESCOPE_CACHE_CPU_SECONDS=${cpu} \
    QEMU_AARCH64=${limit_fake_bin}/fake-qemu-aarch64 \
    SOURCE_DATE_EPOCH=1700000000 \
        "${producer}" "${limit_source}" "${limit_build}" "${output}" "${g1_sha}"
}

require_limit_log() {
    local pattern=$1
    local log=$2
    local failure=$3

    if ! grep -E "${pattern}" "${log}" >/dev/null; then
        cat "${log}" >&2
        echo "${failure}" >&2
        exit 1
    fi
}

for limit_case in ${PF_GAMESCOPE_LIMIT_TEST_CASES:-slow cpu hang}; do
    limit_output=${scratch}/limit-output-${limit_case}
    limit_log=${scratch}/limit-${limit_case}.log
    mkdir -p "${limit_output}"
    case "${limit_case}" in
        slow)
            if ! run_limit_producer slow 1 4 1 "${limit_output}" \
                >"${limit_log}" 2>&1; then
                cat "${limit_log}" >&2
                echo 'CPU-cheap wall-slow seed did not survive the wall backstop' >&2
                exit 1
            fi
            grep -F 'gamescope-pvr-cache=PASS' "${limit_log}" >/dev/null
            ;;
        cpu)
            set +e
            run_limit_producer cpu 2 4 1 "${limit_output}" \
                >"${limit_log}" 2>&1
            limit_rc=$?
            set -e
            test "${limit_rc}" -ne 0
            require_limit_log \
                'gamescope_pvr_seed_failed seed=[12] rc=(137|152) kind=cpu_limit' \
                "${limit_log}" 'CPU limit failure lacked typed seed diagnostics'
            grep -F 'fake_harness_marker=cpu_budget_exceeded' "${limit_log}" >/dev/null
            require_limit_log 'elapsed_wall_seconds=[0-9.]+ cpu_seconds=[0-9.]+' \
                "${limit_log}" 'CPU limit failure lacked elapsed wall/CPU diagnostics'
            ;;
        hang)
            set +e
            run_limit_producer hang 1 1 3 "${limit_output}" \
                >"${limit_log}" 2>&1
            limit_rc=$?
            set -e
            test "${limit_rc}" -ne 0
            require_limit_log \
                'gamescope_pvr_seed_failed seed=[12] rc=124 kind=timeout' \
                "${limit_log}" 'wall timeout lacked typed seed diagnostics'
            grep -F 'fake_harness_marker=wall_backstop_exceeded' "${limit_log}" >/dev/null
            require_limit_log 'elapsed_wall_seconds=[0-9.]+ cpu_seconds=[0-9.]+' \
                "${limit_log}" 'wall timeout lacked elapsed wall/CPU diagnostics'
            ;;
        *)
            echo "unknown PF_GAMESCOPE_LIMIT_TEST_CASES entry: ${limit_case}" >&2
            exit 2
            ;;
    esac
done

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
