#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    echo "MEMORY_POLICY_FAILURE: $*" >&2
    exit 1
}

expect_line() {
    local file="$1"
    local line="$2"

    [ -f "${file}" ] || fail "missing ${file}"
    grep -Fxq -- "${line}" "${file}" || fail "${file} lacks: ${line}"
}

expect_no_memory_cap() {
    local file="$1"

    [ -f "${file}" ] || fail "missing ${file}"
    if grep -Eq '^[[:space:]]*Memory(Max|High)[[:space:]]*=' "${file}"; then
        fail "${file} must not set MemoryMax or MemoryHigh"
    fi
}

expect_package() {
    local file="$1"
    local package="$2"

    [ -f "${file}" ] || fail "missing ${file}"
    awk '!/^[[:space:]]*(#|$)/ { print }' "${file}" | grep -Fxq -- "${package}" ||
        fail "${file} does not install ${package}"
}

check_policy() {
    local root="$1"
    local units="${root}/rootfs-overlay/etc/systemd/system"
    local zram="${root}/rootfs-overlay/etc/systemd/zram-generator.conf"
    local sysctl="${root}/rootfs-overlay/etc/sysctl.d/90-pocketforge-memory.conf"
    local tmpfiles="${root}/rootfs-overlay/usr/lib/tmpfiles.d/pocketforge-memory.conf"
    local unit

    expect_package "${root}/rootfs-packages.txt" systemd-zram-generator

    expect_line "${zram}" '[zram0]'
    expect_line "${zram}" 'zram-size = ram'
    expect_line "${zram}" 'compression-algorithm = lz4'
    expect_line "${zram}" 'swap-priority = 100'

    expect_line "${sysctl}" 'vm.swappiness = 100'
    expect_line "${sysctl}" 'vm.page-cluster = 0'
    expect_line "${sysctl}" 'vm.watermark_scale_factor = 125'
    expect_line "${sysctl}" 'vm.watermark_boost_factor = 0'
    expect_line "${tmpfiles}" 'w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000'

    expect_line "${units}/pocketforge-session.slice" 'MemoryLow=192M'
    expect_no_memory_cap "${units}/pocketforge-session.slice"

    for unit in \
        pf-foreground@.service \
        pf-shell-selected.service \
        pocketforge-gamescope.service \
        pocketforge-audio-defaults.service \
        pf-input-broker.service.d/10-app-session.conf; do
        expect_line "${units}/${unit}" 'Slice=pocketforge-session.slice'
        expect_line "${units}/${unit}" 'OOMScoreAdjust=-900'
    done

    expect_line "${units}/pf-app@.service" 'Slice=apps.slice'
    expect_line "${units}/pf-app@.service" 'OOMScoreAdjust=300'
    for unit in pf-app@.service pf-foreground@.service pf-shell-selected.service; do
        expect_no_memory_cap "${units}/${unit}"
    done

    expect_no_memory_cap "${units}/apps.slice"
}

if [ "${1:-}" = "--root" ]; then
    [ "$#" -eq 2 ] || fail 'usage: test-memory-policy.sh --root <fixture>'
    check_policy "$2"
    exit 0
fi
[ "$#" -eq 0 ] || fail 'usage: test-memory-policy.sh [--root <fixture>]'

# Positive control: the checked-in image policy must satisfy the contract.
check_policy "${repo_root}"

# Negative controls: each policy layer must fail closed in this invocation.
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-memory-policy.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT
fixture="${tmp}/fixture"
required_files=(
    rootfs-packages.txt
    rootfs-overlay/etc/systemd/zram-generator.conf
    rootfs-overlay/etc/sysctl.d/90-pocketforge-memory.conf
    rootfs-overlay/usr/lib/tmpfiles.d/pocketforge-memory.conf
    rootfs-overlay/etc/systemd/system/apps.slice
    rootfs-overlay/etc/systemd/system/pocketforge-session.slice
    rootfs-overlay/etc/systemd/system/pf-app@.service
    rootfs-overlay/etc/systemd/system/pf-foreground@.service
    rootfs-overlay/etc/systemd/system/pf-shell-selected.service
    rootfs-overlay/etc/systemd/system/pocketforge-gamescope.service
    rootfs-overlay/etc/systemd/system/pocketforge-audio-defaults.service
    rootfs-overlay/etc/systemd/system/pf-input-broker.service.d/10-app-session.conf
)
for relative in "${required_files[@]}"; do
    mkdir -p "${fixture}/$(dirname "${relative}")"
    cp "${repo_root}/${relative}" "${fixture}/${relative}"
done

expect_rejected() {
    local label="$1"
    local expected="$2"
    local case_root="${tmp}/${label}"
    local output="${tmp}/${label}.out"

    mkdir -p "${case_root}"
    cp -a "${fixture}/." "${case_root}/"
    shift 2
    "$@" "${case_root}"
    if (check_policy "${case_root}") >"${output}" 2>&1; then
        fail "negative control ${label} was accepted"
    fi
    grep -Fq -- "${expected}" "${output}" ||
        fail "negative control ${label} failed for an unexpected reason"
}

replace_line() {
    local relative="$1"
    local old="$2"
    local new="$3"
    local root="$4"

    sed -i "s|^${old}$|${new}|" "${root}/${relative}"
    grep -Fxq -- "${new}" "${root}/${relative}" || fail "mutation did not apply: ${new}"
}

append_line() {
    local relative="$1"
    local line="$2"
    local root="$3"

    printf '%s\n' "${line}" >> "${root}/${relative}"
}

expect_rejected package_missing 'does not install systemd-zram-generator' \
    replace_line rootfs-packages.txt systemd-zram-generator systemd-zram-generator-missing
expect_rejected zram_size 'lacks: zram-size = ram' \
    replace_line rootfs-overlay/etc/systemd/zram-generator.conf 'zram-size = ram' 'zram-size = ram / 2'
expect_rejected zram_algorithm 'lacks: compression-algorithm = lz4' \
    replace_line rootfs-overlay/etc/systemd/zram-generator.conf 'compression-algorithm = lz4' 'compression-algorithm = lzo-rle'
expect_rejected sysctl 'lacks: vm.swappiness = 100' \
    replace_line rootfs-overlay/etc/sysctl.d/90-pocketforge-memory.conf 'vm.swappiness = 100' 'vm.swappiness = 60'
expect_rejected mglru_ttl 'lacks: w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000' \
    replace_line rootfs-overlay/usr/lib/tmpfiles.d/pocketforge-memory.conf \
    'w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000' \
    'w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 0'
expect_rejected session_reserve 'lacks: MemoryLow=192M' \
    replace_line rootfs-overlay/etc/systemd/system/pocketforge-session.slice \
    'MemoryLow=192M' 'MemoryLow=64M'
expect_rejected session_oom 'lacks: OOMScoreAdjust=-900' \
    replace_line rootfs-overlay/etc/systemd/system/pocketforge-gamescope.service \
    'OOMScoreAdjust=-900' 'OOMScoreAdjust=0'
expect_rejected app_oom 'lacks: OOMScoreAdjust=300' \
    replace_line rootfs-overlay/etc/systemd/system/pf-app@.service \
    'OOMScoreAdjust=300' 'OOMScoreAdjust=0'
expect_rejected app_cap 'pf-app@.service must not set MemoryMax or MemoryHigh' \
    append_line rootfs-overlay/etc/systemd/system/pf-app@.service 'MemoryMax=1M'
expect_rejected slice_cap 'apps.slice must not set MemoryMax or MemoryHigh' \
    append_line rootfs-overlay/etc/systemd/system/apps.slice 'MemoryHigh=1M'

echo 'PASS: zram, VM tuning, session reserve, and uncapped app policy are complete'
