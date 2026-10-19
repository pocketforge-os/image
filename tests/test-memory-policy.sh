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

expect_default_app_slice() {
    local file="$1"

    [ -f "${file}" ] || fail "missing ${file}"
    if grep -Eq '^[[:space:]]*Slice[[:space:]]*=' "${file}"; then
        fail "${file} must retain default dedicated slice placement"
    fi
}

expect_package() {
    local file="$1"
    local package="$2"

    [ -f "${file}" ] || fail "missing ${file}"
    awk '!/^[[:space:]]*(#|$)/ { print }' "${file}" | grep -Fxq -- "${package}" ||
        fail "${file} does not install ${package}"
}

seed_shared_units() {
    local rootfs="$1"
    local units="${rootfs}/etc/systemd/system"
    local unit

    install -d "${units}"
    for unit in \
        pf-app@.service \
        pf-foreground@.service \
        pf-shell-selected.service \
        pocketforge-audio-defaults.service; do
        install -m 0644 \
            "${repo_root}/rootfs-overlay/etc/systemd/system/${unit}" \
            "${units}/${unit}"
    done
}

effective_directive() {
    local rootfs="$1"
    local unit="$2"
    local directive="$3"
    local units="${rootfs}/etc/systemd/system"
    local value=''
    local file line

    for file in "${units}/${unit}" "${units}/${unit}.d/"*.conf; do
        [ -f "${file}" ] || continue
        while IFS= read -r line; do
            case "${line}" in
                "${directive}="*) value="${line#*=}" ;;
            esac
        done < "${file}"
    done
    printf '%s' "${value}"
}

expect_effective_directive() {
    local rootfs="$1"
    local unit="$2"
    local directive="$3"
    local expected="$4"
    local actual

    actual="$(effective_directive "${rootfs}" "${unit}" "${directive}")"
    [ "${actual}" = "${expected}" ] ||
        fail "${unit} effective ${directive}: expected '${expected}', got '${actual}'"
}

check_policy() {
    local root="$1"
    local units="${root}/rootfs-overlay/etc/systemd/system"
    local zram="${root}/rootfs-overlay/etc/systemd/zram-generator.conf"
    local zram_limit="${units}/systemd-zram-setup@zram0.service.d/10-pocketforge-mem-limit.conf"
    local sysctl="${root}/rootfs-overlay/etc/sysctl.d/90-pocketforge-memory.conf"
    local tmpfiles="${root}/rootfs-overlay/usr/lib/tmpfiles.d/pocketforge-memory.conf"
    local unit

    expect_package "${root}/rootfs-packages.txt" systemd-zram-generator

    expect_line "${zram}" '[zram0]'
    expect_line "${zram}" 'zram-size = ram'
    expect_line "${zram}" 'compression-algorithm = lz4'
    expect_line "${zram}" 'swap-priority = 100'
    expect_line "${zram_limit}" "ExecStartPost=/bin/sh -c 'echo 448M > /sys/block/zram0/mem_limit'"

    expect_line "${sysctl}" 'vm.swappiness = 100'
    expect_line "${sysctl}" 'vm.page-cluster = 0'
    expect_line "${sysctl}" 'vm.watermark_scale_factor = 125'
    expect_line "${sysctl}" 'vm.watermark_boost_factor = 0'
    expect_line "${tmpfiles}" 'w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000'

    local session_slice='pfsession.slice'
    local session_stem="${session_slice%.slice}"

    expect_line "${units}/${session_slice}" 'MemoryLow=192M'
    expect_no_memory_cap "${units}/pfsession.slice"
    [ ! -e "${units}/pocketforge-session.slice" ] ||
        fail 'nested pocketforge-session.slice must not exist'
    case "${session_stem}" in *-*) fail 'session slice must be top-level' ;; esac

    for unit in \
        pf-foreground@.service \
        pf-shell-selected.service \
        pocketforge-gamescope.service \
        pocketforge-audio-defaults.service \
        pf-input-broker.service.d/10-app-session.conf; do
        expect_line "${units}/${unit}" 'Slice=pfsession.slice'
        expect_line "${units}/${unit}" 'OOMScoreAdjust=-900'
    done

    expect_default_app_slice "${units}/pf-app@.service"
    expect_line "${units}/pf-app@.service" 'OOMScoreAdjust=300'
    [ ! -e "${units}/apps.slice" ] || fail 'obsolete apps.slice must not be shipped'

    for unit in \
        pf-session-authorityd.service \
        pf-prefsd.service \
        pf-powerd.service \
        pf-input-decode.service \
        pf-fcitx5.service \
        pf-osk.service \
        pf-ime-bus.service \
        pf-volumed.service; do
        expect_line "${units}/${unit}.d/10-memory-policy.conf" 'Slice=pfsession.slice'
        expect_line "${units}/${unit}.d/10-memory-policy.conf" 'OOMScoreAdjust=-900'
    done

    for unit in pf-app@.service pf-foreground@.service pf-shell-selected.service; do
        expect_no_memory_cap "${units}/${unit}"
    done
}

check_installed_policy() {
    local rootfs="$1"
    local units="${rootfs}/etc/systemd/system"
    local unit
    local session_slice='pfsession.slice'
    local session_stem="${session_slice%.slice}"

    expect_line "${rootfs}/etc/systemd/zram-generator.conf" 'zram-size = ram'
    expect_line "${rootfs}/etc/systemd/zram-generator.conf" 'compression-algorithm = lz4'
    expect_line "${rootfs}/etc/sysctl.d/90-pocketforge-memory.conf" 'vm.swappiness = 100'
    expect_line "${rootfs}/usr/lib/tmpfiles.d/pocketforge-memory.conf" \
        'w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000'
    expect_line "${units}/pfsession.slice" 'MemoryLow=192M'
    expect_line "${units}/systemd-zram-setup@zram0.service.d/10-pocketforge-mem-limit.conf" \
        "ExecStartPost=/bin/sh -c 'echo 448M > /sys/block/zram0/mem_limit'"
    [ ! -e "${units}/pocketforge-session.slice" ] ||
        fail 'built rootfs contains nested pocketforge-session.slice'
    case "${session_stem}" in *-*) fail 'session slice must be top-level' ;; esac
    [ ! -e "${units}/apps.slice" ] || fail 'built rootfs contains obsolete apps.slice'

    for unit in \
        pf-session-authorityd.service \
        pf-prefsd.service \
        pf-powerd.service \
        pf-input-decode.service \
        pf-fcitx5.service \
        pf-osk.service \
        pf-ime-bus.service \
        pf-volumed.service; do
        expect_line "${units}/${unit}.d/10-memory-policy.conf" 'Slice=pfsession.slice'
        expect_line "${units}/${unit}.d/10-memory-policy.conf" 'OOMScoreAdjust=-900'
    done
}

if [ "${1:-}" = "--root" ]; then
    [ "$#" -eq 2 ] || fail 'usage: test-memory-policy.sh --root <fixture>'
    check_policy "$2"
    exit 0
fi
[ "$#" -eq 0 ] || fail 'usage: test-memory-policy.sh [--root <fixture>]'

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-memory-policy.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

# Positive control: install through the production customization entry point and
# assert the rootfs output, not merely the source overlay.
installer="${repo_root}/scripts/install-memory-policy.sh"
[ -x "${installer}" ] || fail "missing executable ${installer}"
grep -Fq '/work/src/scripts/install-memory-policy.sh' "${repo_root}/scripts/build-rootfs.sh" ||
    fail 'build-rootfs.sh does not invoke the memory-policy installer'
built_rootfs="${tmp}/built-rootfs"
mkdir -p "${built_rootfs}"
seed_shared_units "${built_rootfs}"
"${installer}" "${built_rootfs}" kernel-sunxi-7.x a133-open-7x-gpu "${repo_root}"
check_installed_policy "${built_rootfs}"
for unit in pf-app@.service pf-foreground@.service pf-shell-selected.service; do
    expect_effective_directive "${built_rootfs}" "${unit}" MemoryMax ''
done
expect_effective_directive "${built_rootfs}" pf-app@.service OOMScoreAdjust 300
for unit in \
    pf-foreground@.service \
    pf-shell-selected.service \
    pocketforge-audio-defaults.service; do
    expect_effective_directive "${built_rootfs}" "${unit}" Slice pfsession.slice
done

# Source controls retain exact unit semantics and drive mutation tests.
check_policy "${repo_root}"

# Compatibility control: the shared units also enter the a133-open/6.x image,
# so profiles outside the 7.x policy retain their legacy caps and no session
# slice assignment. They must not receive the 7.x zram or sysctl policy.
compat_rootfs="${tmp}/compat-rootfs"
mkdir -p "${compat_rootfs}"
seed_shared_units "${compat_rootfs}"
"${installer}" "${compat_rootfs}" kernel-sunxi-6.x a133-open "${repo_root}"
[ ! -e "${compat_rootfs}/etc/systemd/zram-generator.conf" ] ||
    fail '7.x zram policy leaked into the 6.x rootfs'
[ ! -e "${compat_rootfs}/etc/sysctl.d/90-pocketforge-memory.conf" ] ||
    fail '7.x sysctl policy leaked into the 6.x rootfs'
[ ! -e "${compat_rootfs}/etc/systemd/system/pfsession.slice" ] ||
    fail '7.x session slice leaked into the 6.x rootfs'
for unit in pf-app@.service pf-foreground@.service pf-shell-selected.service; do
    expect_effective_directive "${compat_rootfs}" "${unit}" MemoryMax 256M
done
for unit in \
    pf-foreground@.service \
    pf-shell-selected.service \
    pocketforge-audio-defaults.service; do
    expect_effective_directive "${compat_rootfs}" "${unit}" Slice ''
    expect_effective_directive "${compat_rootfs}" "${unit}" OOMScoreAdjust 0
done

# Negative control: another kernel/device profile gets only the compatibility
# safeguards, never the 7.x policy.
closed_rootfs="${tmp}/closed-rootfs"
mkdir -p "${closed_rootfs}"
seed_shared_units "${closed_rootfs}"
"${installer}" "${closed_rootfs}" kernel-sunxi-4.9 a133-owned "${repo_root}"
[ ! -e "${closed_rootfs}/etc/systemd/zram-generator.conf" ] ||
    fail 'memory policy leaked into the closed 4.9 rootfs'
expect_effective_directive "${closed_rootfs}" pf-app@.service MemoryMax 256M

# Negative control: a selected A133 7.x profile with a different kernel must
# fail closed rather than silently shipping an unreviewed policy combination.
wrong_kernel_rootfs="${tmp}/wrong-kernel-rootfs"
wrong_kernel_output="${tmp}/wrong-kernel.out"
mkdir -p "${wrong_kernel_rootfs}"
if "${installer}" "${wrong_kernel_rootfs}" kernel-sunxi-4.9 \
    a133-open-7x-gpu "${repo_root}" >"${wrong_kernel_output}" 2>&1; then
    fail 'memory policy accepted a 7.x device with the wrong kernel'
fi
grep -Fq 'expected=kernel-sunxi-7.x' "${wrong_kernel_output}" ||
    fail 'wrong-kernel rejection did not explain the expected kernel'

# Negative controls: each policy layer must fail closed in this invocation.
fixture="${tmp}/fixture"
required_files=(
    rootfs-packages.txt
    rootfs-overlay/etc/systemd/zram-generator.conf
    rootfs-overlay/etc/sysctl.d/90-pocketforge-memory.conf
    rootfs-overlay/usr/lib/tmpfiles.d/pocketforge-memory.conf
    rootfs-overlay/etc/systemd/system/pfsession.slice
    rootfs-overlay/etc/systemd/system/systemd-zram-setup@zram0.service.d/10-pocketforge-mem-limit.conf
    rootfs-overlay/etc/systemd/system/pf-session-authorityd.service.d/10-memory-policy.conf
    rootfs-overlay/etc/systemd/system/pf-prefsd.service.d/10-memory-policy.conf
    rootfs-overlay/etc/systemd/system/pf-powerd.service.d/10-memory-policy.conf
    rootfs-overlay/etc/systemd/system/pf-input-decode.service.d/10-memory-policy.conf
    rootfs-overlay/etc/systemd/system/pf-fcitx5.service.d/10-memory-policy.conf
    rootfs-overlay/etc/systemd/system/pf-osk.service.d/10-memory-policy.conf
    rootfs-overlay/etc/systemd/system/pf-ime-bus.service.d/10-memory-policy.conf
    rootfs-overlay/etc/systemd/system/pf-volumed.service.d/10-memory-policy.conf
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
expect_rejected zram_mem_limit 'lacks: ExecStartPost=' \
    replace_line rootfs-overlay/etc/systemd/system/systemd-zram-setup@zram0.service.d/10-pocketforge-mem-limit.conf \
    "ExecStartPost=/bin/sh -c 'echo 448M > /sys/block/zram0/mem_limit'" \
    "ExecStartPost=/bin/sh -c 'echo 768M > /sys/block/zram0/mem_limit'"
expect_rejected sysctl 'lacks: vm.swappiness = 100' \
    replace_line rootfs-overlay/etc/sysctl.d/90-pocketforge-memory.conf 'vm.swappiness = 100' 'vm.swappiness = 60'
expect_rejected mglru_ttl 'lacks: w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000' \
    replace_line rootfs-overlay/usr/lib/tmpfiles.d/pocketforge-memory.conf \
    'w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000' \
    'w- /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 0'
expect_rejected session_reserve 'lacks: MemoryLow=192M' \
    replace_line rootfs-overlay/etc/systemd/system/pfsession.slice \
    'MemoryLow=192M' 'MemoryLow=64M'
expect_rejected session_oom 'lacks: OOMScoreAdjust=-900' \
    replace_line rootfs-overlay/etc/systemd/system/pocketforge-gamescope.service \
    'OOMScoreAdjust=-900' 'OOMScoreAdjust=0'
expect_rejected session_daemon_oom 'lacks: OOMScoreAdjust=-900' \
    replace_line rootfs-overlay/etc/systemd/system/pf-session-authorityd.service.d/10-memory-policy.conf \
    'OOMScoreAdjust=-900' 'OOMScoreAdjust=0'
expect_rejected app_oom 'lacks: OOMScoreAdjust=300' \
    replace_line rootfs-overlay/etc/systemd/system/pf-app@.service \
    'OOMScoreAdjust=300' 'OOMScoreAdjust=0'
expect_rejected app_cap 'pf-app@.service must not set MemoryMax or MemoryHigh' \
    append_line rootfs-overlay/etc/systemd/system/pf-app@.service 'MemoryMax=1M'
expect_rejected app_slice_override 'must retain default dedicated slice placement' \
    append_line rootfs-overlay/etc/systemd/system/pf-app@.service 'Slice=apps.slice'

echo 'PASS: zram, VM tuning, session reserve, and uncapped app policy are complete'
