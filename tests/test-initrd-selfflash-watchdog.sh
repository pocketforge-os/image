#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

gate_text() {
    local source=$1 end_marker=$2
    sed -n "/^# --- self-flash gate/,/^${end_marker}/p" "${source}"
}

recover_text() {
    local source=$1
    sed -n '/^selfflash_recover() {/,/^}/p' "${source}"
}

writer_text() {
    local source=$1
    sed -n '/^selfflash_write_flag() {/,/^}/p' "${source}"
}

wait_text() {
    local source=$1
    sed -n '/^sf_wait_for_root() {/,/^}/p' "${source}"
}

check_source_contract() {
    local source=$1 board=$2 end_marker=$3 first_write=$4 gate recover wait_loop writer cleanup
    gate="$(gate_text "${source}" "${end_marker}")"
    recover="$(recover_text "${source}")"
    wait_loop="$(wait_text "${source}")"
    cleanup="$(sed -n '/if \[ "$tries" -ge 3 \]; then/,/^[[:space:]]*fi$/p' <<<"${recover}")"

    grep -Fq 'sf_wait_for_root' <<<"${gate}" || return 1
    grep -Fq 'STAGE: self-flash gate — SD not found after 20s' <<<"${wait_loop}" || return 1
    grep -Fq 'sf_findfs_bounded LABEL=POCKETFORGE_DATA' <<<"${wait_loop}" || return 1
    grep -Fq 'watchdog_ping' <<<"${wait_loop}" || return 1
    ! grep -Eq 'printf .V.|watchdog_disarm_for_selfflash' <<<"${gate}" || return 1
    ! grep -Fq 'SF_ROOTPART="$(findfs LABEL=POCKETFORGE_DATA' <<<"${gate}" || return 1
    ! grep -Fq 'watchdog_disarm_for_selfflash' <<<"${cleanup}" || return 1

    local disarm_line write_line
    if [[ "${board}" == tsp ]]; then
        grep -Fq 'watchdog_disarm_for_selfflash' <<<"${recover}" || return 1
        disarm_line="$(grep -n -m1 '^[[:space:]]*watchdog_disarm_for_selfflash$' <<<"${recover}" | cut -d: -f1)"
        write_line="$(grep -n -F "${first_write}" <<<"${recover}" | cut -d: -f1 | \
            awk -v disarm="${disarm_line}" '$1 > disarm { print; exit }')"
    else
        writer="$(writer_text "${source}")"
        grep -Fq 'selfflash_write_flag armed ' <<<"${recover}" || return 1
        grep -Eq 'selfflash_write_flag armed .* 1$' <<<"${recover}" || return 1
        ! grep -Eq 'selfflash_write_flag failed .* 1$' <<<"${cleanup}" || return 1
        disarm_line="$(grep -n -F '[ "$sf_disarm" = 1 ] && watchdog_disarm_for_selfflash' <<<"${writer}" | cut -d: -f1)"
        write_line="$(grep -n -F "${first_write}" <<<"${writer}" | cut -d: -f1 | \
            awk -v disarm="${disarm_line}" '$1 > disarm { print; exit }')"
    fi
    [[ -n "${disarm_line}" && -n "${write_line}" ]] || return 1
    [[ "${write_line}" -eq $((disarm_line + 1)) ]] || return 1

    if [[ "${board}" == tsp ]]; then
        ! grep -Fq "self-flash gate's read retries" "${source}" || return 1
    fi
}

extract_watchdog_helpers() {
    local source=$1 output=$2 name
    : >"${output}"
    for name in watchdog_present watchdog_ping watchdog_disarm_for_selfflash sf_findfs_bounded sf_wait_for_root; do
        sed -n "/^${name}() {/,/^}/p" "${source}" >>"${output}"
    done
}

exercise_hung_findfs() {
    local source=$1 board=$2 helper_file runner
    helper_file="${SCRATCH}/${board}-helpers.sh"
    runner="${SCRATCH}/${board}-hung-findfs.sh"
    extract_watchdog_helpers "${source}" "${helper_file}"
    [[ -s "${helper_file}" ]] || fail "${board}: watchdog/findfs helpers were not extractable"

    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
        printf 'PID_FILE=%q\nWATCHDOG_DEV=%q\nSF_FIND_TMP=%q\nLOG_FILE=%q\n' \
            "${SCRATCH}/${board}-findfs.pid" "${SCRATCH}/${board}-watchdog.trace" \
            "${SCRATCH}" "${SCRATCH}/${board}-gate.log"
        cat "${helper_file}"
        cat <<'EOF'
watchdog_present() { return 0; }
sleep() { command sleep 0.01; }
log() { printf '%s\n' "$*" >>"${LOG_FILE}"; }
findfs() {
    printf '%s\n' "${BASHPID}" >"${PID_FILE}"
    while :; do command sleep 10; done
}
: >"${WATCHDOG_DEV}"
: >"${LOG_FILE}"
if sf_wait_for_root; then
    echo "never-returning findfs unexpectedly found a root" >&2
    exit 1
fi
[[ "${SF_WAIT}" -eq 20 && -z "${SF_ROOTPART}" ]]
grep -Fqx 'STAGE: self-flash gate — SD not found after 20s — normal boot' "${LOG_FILE}"
pid="$(cat "${PID_FILE}")"
if kill -0 "${pid}" 2>/dev/null; then
    echo "hung findfs survived bounded lookup" >&2
    exit 1
fi
trace_hex="$(od -An -tx1 "${WATCHDOG_DEV}" | tr -d ' \n')"
[[ "${trace_hex}" == 00 ]] || {
    echo "watchdog was not left armed and pinged (trace=${trace_hex})" >&2
    exit 1
}
EOF
    } >"${runner}"
    chmod +x "${runner}"
    timeout 4 "${runner}"
}

exercise_first_write_boundary() {
    local source=$1 board=$2 first_write=$3 helper_file
    helper_file="${SCRATCH}/${board}-write-helpers.sh"
    extract_watchdog_helpers "${source}" "${helper_file}"
    # The source contract above proves these are adjacent inside selfflash_recover.
    # Execute the same boundary with a stubbed first SD mutation: it must observe V,
    # while the pre-boundary keepalive must still be NUL.
    (
        # shellcheck disable=SC1090
        source "${helper_file}"
        WATCHDOG_DEV="${SCRATCH}/${board}-write-watchdog.trace"
        watchdog_present() { return 0; }
        log() { :; }
        : >"${WATCHDOG_DEV}"
        watchdog_ping
        [[ "$(od -An -tx1 "${WATCHDOG_DEV}" | tr -d ' \n')" == 00 ]]
        first_sd_write() {
            [[ "$(cat "${WATCHDOG_DEV}")" == V ]] || return 1
            printf 'write\n' >"${SCRATCH}/${board}-first-write"
        }
        watchdog_disarm_for_selfflash
        first_sd_write
        [[ -s "${SCRATCH}/${board}-first-write" ]]
    )

    # Negative control: a first write without the immediately preceding disarm
    # must fail closed.
    if (
        # shellcheck disable=SC1090
        source "${helper_file}"
        WATCHDOG_DEV="${SCRATCH}/${board}-negative-watchdog.trace"
        watchdog_present() { return 0; }
        log() { :; }
        : >"${WATCHDOG_DEV}"
        watchdog_ping
        [[ "$(od -An -tx1 "${WATCHDOG_DEV}" | tr -d ' \n')" == 56 ]]
    ); then
        fail "${board}: missing-disarm negative control unexpectedly passed (${first_write})"
    fi
}

A133="${ROOT}/boards/tsp/initrd/init"
A523="${ROOT}/boards/tsp-s/initrd/init"

check_source_contract "${A133}" tsp '# --- PowerVR' 'mount -o remount,rw "$MNT"' || \
    fail 'tsp: self-flash watchdog source contract is not satisfied'
check_source_contract "${A523}" tsp-s '# --- find + mount the rootfs' 'dd if=/sf-flag.bin of="$sf_sd"' || \
    fail 'tsp-s: self-flash watchdog source contract is not satisfied'

exercise_hung_findfs "${A133}" tsp
exercise_hung_findfs "${A523}" tsp-s
exercise_first_write_boundary "${A133}" tsp 'mount -o remount,rw "$MNT"'
exercise_first_write_boundary "${A523}" tsp-s 'dd if=/sf-flag.bin of="$sf_sd"'

# Source-contract negative controls: each mutation must be rejected.
for source in "${A133}" "${A523}"; do
    board=tsp; end_marker='# --- PowerVR'; first_write='mount -o remount,rw "$MNT"'
    [[ "${source}" == "${A523}" ]] && {
        board=tsp-s; end_marker='# --- find + mount the rootfs'; first_write='dd if=/sf-flag.bin of="$sf_sd"'
    }
    missing_log="${SCRATCH}/${board}-missing-log"
    sed '/STAGE: self-flash gate — SD not found after 20s/d' "${source}" >"${missing_log}"
    if check_source_contract "${missing_log}" "${board}" "${end_marker}" "${first_write}"; then
        fail "${board}: missing exhausted-loop log negative control passed"
    fi

    early_v="${SCRATCH}/${board}-early-v"
    sed '/STAGE: self-flash gate — waiting for SD enumeration/a\    printf '\''V'\'' > /dev/watchdog' \
        "${source}" >"${early_v}"
    if check_source_contract "${early_v}" "${board}" "${end_marker}" "${first_write}"; then
        fail "${board}: pre-decision watchdog-disarm negative control passed"
    fi
done

echo 'initrd self-flash watchdog regression: PASS'
