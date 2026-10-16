#!/bin/bash
# Request an orderly shutdown before the AXP717 reaches its hard cutoff.
set -u

SYSFS_ROOT="${PF_SYSFS_ROOT:-/sys}"
STATE_DIR="${PF_STATE_DIR:-/run/pocketforge-low-battery-shutdown}"
SYSTEMCTL="${PF_SYSTEMCTL:-/usr/bin/systemctl}"
BATTERY="${SYSFS_ROOT}/class/power_supply/axp20x-battery"
EXTERNAL="${SYSFS_ROOT}/class/power_supply/axp20x-usb"
REQUEST="${STATE_DIR}/requested"
VOLTAGE_FLOOR_UV=3500000

log() {
    printf '%s\n' "$*"
}

read_attr() {
    local value=""

    [ -r "$1" ] || return 1
    IFS= read -r value < "$1" || [ -n "${value}" ] || return 1
    [ -n "${value}" ] || return 1
    printf '%s' "${value}"
}

is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

if [ -e "${REQUEST}" ]; then
    log "decision=coalesced reason=shutdown_already_requested"
    exit 0
fi

present="$(read_attr "${BATTERY}/present")" || {
    log "decision=error reason=battery_present_unreadable" >&2
    exit 1
}
if [ "${present}" = 0 ]; then
    log "decision=continue reason=battery_absent"
    exit 0
fi
if [ "${present}" != 1 ]; then
    log "decision=error reason=battery_present_invalid value=${present}" >&2
    exit 1
fi

capacity="$(read_attr "${BATTERY}/capacity")" || {
    log "decision=error reason=capacity_unreadable" >&2
    exit 1
}
voltage_uv="$(read_attr "${BATTERY}/voltage_now")" || {
    log "decision=error reason=voltage_unreadable" >&2
    exit 1
}
# kernel-sunxi-7.x#106 emits the low-SOC events but does not yet publish the
# optional capacity_level attribute. Observe and record it when present without
# making its absence disable the numeric SOC and voltage safety thresholds.
capacity_level="$(read_attr "${BATTERY}/capacity_level")" || capacity_level=Unavailable
external_online="$(read_attr "${EXTERNAL}/online")" || {
    log "decision=error reason=external_power_unreadable" >&2
    exit 1
}

if ! is_uint "${capacity}" || [ "${capacity}" -gt 100 ]; then
    log "decision=error reason=capacity_invalid value=${capacity}" >&2
    exit 1
fi
if ! is_uint "${voltage_uv}"; then
    log "decision=error reason=voltage_invalid value=${voltage_uv}" >&2
    exit 1
fi
if [ "${external_online}" != 0 ] && [ "${external_online}" != 1 ]; then
    log "decision=error reason=external_power_invalid value=${external_online}" >&2
    exit 1
fi

# Match the boot gate: while external power is online, keep charging instead
# of shutting down. The kernel alarm will retrigger evaluation if power leaves.
if [ "${external_online}" = 1 ]; then
    log "decision=continue reason=external_power_online capacity=${capacity} voltage_uv=${voltage_uv}"
    exit 0
fi

reason=""
missed_lvl1=0
if [ "${capacity}" -eq 0 ]; then
    reason=soc_lvl2
    missed_lvl1=1
elif [ "${capacity}" -le 5 ]; then
    reason=soc_lvl1
elif [ "${voltage_uv}" -le "${VOLTAGE_FLOOR_UV}" ]; then
    reason=voltage_floor
else
    log "decision=continue reason=battery_safe capacity=${capacity} capacity_level=${capacity_level} voltage_uv=${voltage_uv}"
    exit 0
fi

mkdir -p "${STATE_DIR}" || {
    log "decision=error reason=state_directory_create_failed" >&2
    exit 1
}
chmod 0700 "${STATE_DIR}" || {
    log "decision=error reason=state_directory_chmod_failed" >&2
    exit 1
}

tmp="${STATE_DIR}/.requested.$$"
{
    printf 'reason=%s\n' "${reason}"
    printf 'capacity=%s\n' "${capacity}"
    printf 'capacity_level=%s\n' "${capacity_level}"
    printf 'voltage_uv=%s\n' "${voltage_uv}"
    printf 'missed_lvl1=%s\n' "${missed_lvl1}"
} > "${tmp}" || {
    log "decision=error reason=request_record_write_failed" >&2
    exit 1
}
chmod 0600 "${tmp}" || {
    rm "${tmp}"
    log "decision=error reason=request_record_chmod_failed" >&2
    exit 1
}
if ! ln "${tmp}" "${REQUEST}" 2>/dev/null; then
    rm "${tmp}"
    log "decision=coalesced reason=shutdown_already_requested"
    exit 0
fi
rm "${tmp}"

log "decision=poweroff reason=${reason} capacity=${capacity} capacity_level=${capacity_level} voltage_uv=${voltage_uv} missed_lvl1=${missed_lvl1}"
if ! "${SYSTEMCTL}" --no-block poweroff; then
    rm "${REQUEST}"
    log "decision=error reason=systemctl_poweroff_failed" >&2
    exit 1
fi

exit 0
