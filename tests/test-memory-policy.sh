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
    expect_package "${root}/rootfs-packages-a523.txt" systemd-zram-generator

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

# Negative control: one reintroduced app cap must be rejected in this invocation.
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-memory-policy.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT
fixture="${tmp}/fixture"
required_files=(
    rootfs-packages.txt
    rootfs-packages-a523.txt
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
printf '\nMemoryMax=1M\n' >> "${fixture}/rootfs-overlay/etc/systemd/system/pf-app@.service"

negative_output="${tmp}/negative.out"
if (check_policy "${fixture}") >"${negative_output}" 2>&1; then
    fail 'negative control accepted an app MemoryMax'
fi
grep -Fq 'pf-app@.service must not set MemoryMax or MemoryHigh' "${negative_output}" ||
    fail 'negative control failed for an unexpected reason'

echo 'PASS: zram, VM tuning, session reserve, and uncapped app policy are complete'
