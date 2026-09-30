#!/bin/bash
# =============================================================================
# usbnet-bench.sh -- dev-image bench USB network (usbnet contract v1)
# =============================================================================
# bd: tsp-mc9m.41.984.34.2 (plan label B2 under tsp-mc9m.41.984.34).
#
# DEV VARIANT ONLY. scripts/build-rootfs.sh installs this (with its unit, udev
# rule and 30-usb0.network) only for VARIANT=dev on kernel-sunxi-7.x, and
# scripts/verify-rootfs-usbnet-bench.py fails every other rootfs that contains
# any of them.
#
# What it does, once per boot at most:
#   1. Gate: switch only while EXTERNAL VBUS is present. Both must hold, read
#      fresh from sysfs:
#        a. exactly one power_supply of type USB whose device/of_node is
#           x-powers,axp717-usb-power-supply reports present=1, and
#        b. exactly one regulator named usb0-vbus (the AXP717 boost) reads
#           state=disabled with num_users=0, so the DUT is not the source.
#      PRESENT cannot tell the node's 5 V from our own boost, and switching to
#      peripheral would NOT turn an enabled boost off (EHCI0/OHCI0 hold phy0's
#      power reference), so (b) is required, not optional.
#      Anything unknown, missing or ambiguous holds: no role change.
#   2. Build the configfs CDC-NCM gadget: 1d6b:0104, one ncm function.
#   3. Write "peripheral" to the MUSB `mode` attribute (at most once per boot).
#   4. Bind the gadget to the MUSB UDC. The bind is what applies the switch:
#      the sunxi glue defers phy_set_mode(DEVICE) until musb_start (at bind)
#      sets its ENABLED flag (drivers/usb/musb/sunxi.c:102-103, :142-143).
#
# After a successful switch the role is latched until reboot: VBUS loss ends
# the USB session in the kernel, the gadget stays bound and re-enumerates when
# VBUS returns. This never writes `otg` or `host`: `otg` would hand the role to
# the unmeasured PH8 ID pin.
#
# Writes: ONLY the configfs gadget, the one MUSB `mode` attribute, and
# ${STATE_DIR}. Never /sys/class/regulator, /sys/class/power_supply, any vbus
# attribute, or any WiFi file.
#
# Exit: 0 when switched, already switched, or holding because VBUS is absent
# (a normal state). 1 when holding for an anomaly (unknown/ambiguous inputs,
# boost on, missing controller or gadget support, a failed write).
# =============================================================================
set -u

SYSFS=/sys
CONFIGFS=/sys/kernel/config
STATE_DIR=/run/pocketforge-usbnet-bench

AXP_USB_COMPATIBLE=x-powers,axp717-usb-power-supply
BOOST_REGULATOR=usb0-vbus
MUSB_PARENT=5100000.usb

# usbnet contract v1 (tsp-mc9m.41.984.34; node half tsp-mc9m.41.984.34.3).
GADGET=pocketforge-usbnet
GADGET_VID=0x1d6b
GADGET_PID=0x0104
GADGET_BCD_DEVICE=0x0100
GADGET_BCD_USB=0x0200
NCM_FUNCTION=ncm.usb0
CONFIG=c.1
# Deterministic locally administered MACs. The node must not depend on them.
DUT_MAC=02:70:66:62:00:02
HOST_MAC=02:70:66:62:00:01

declare -A EVIDENCE=()
STATUS_KEYS=(decision reason supply present boost_state boost_users musb udc
             musb_mode_before mode_written bound)

log() { printf 'usbnet-bench: %s\n' "$*"; }
note() { EVIDENCE[$1]="$2"; }

write_status() {
    local key tmp="${STATE_DIR}/status.tmp"
    {
        for key in "${STATUS_KEYS[@]}"; do
            printf '%s=%s\n' "${key}" "${EVIDENCE[${key}]:-}"
        done
    } > "${tmp}" && mv -f "${tmp}" "${STATE_DIR}/status"
}

# finish DECISION REASON EXIT
finish() {
    note decision "$1"
    note reason "$2"
    write_status || log "WARN: cannot write ${STATE_DIR}/status"
    log "decision=$1 reason=$2 supply=${EVIDENCE[supply]:-} present=${EVIDENCE[present]:-}" \
        "boost=${EVIDENCE[boost_state]:-}/${EVIDENCE[boost_users]:-}" \
        "musb=${EVIDENCE[musb]:-} udc=${EVIDENCE[udc]:-}" \
        "mode_written=${EVIDENCE[mode_written]:-} bound=${EVIDENCE[bound]:-}"
    exit "$3"
}

# read_attr PATH -- print the first line; fail if missing, unreadable or empty.
read_attr() {
    local line=""
    IFS= read -r line 2>/dev/null < "$1" || [ -n "${line}" ] || return 1
    [ -n "${line}" ] || return 1
    printf '%s' "${line}"
}

# has_compatible FILE WANTED -- FILE is a devicetree NUL-separated list.
has_compatible() {
    local item=""
    [ -r "$1" ] || return 1
    while IFS= read -r -d '' item || [ -n "${item}" ]; do
        [ "${item}" = "$2" ] && return 0
        item=""
    done < "$1"
    return 1
}

# evaluate_gate -- sets GATE_REASON and GATE_EXIT on hold; returns 0 to switch.
evaluate_gate() {
    local dir type present name state users
    local supplies=() boosts=()

    for dir in "${SYSFS}"/class/power_supply/*; do
        [ -d "${dir}" ] || continue
        type="$(read_attr "${dir}/type")" || continue
        [ "${type}" = USB ] || continue
        has_compatible "${dir}/device/of_node/compatible" "${AXP_USB_COMPATIBLE}" || continue
        supplies+=("${dir##*/}")
    done
    if [ "${#supplies[@]}" -ne 1 ]; then
        note supply "count:${#supplies[@]}"
        GATE_EXIT=1
        if [ "${#supplies[@]}" -eq 0 ]; then
            GATE_REASON=vbus_supply_missing
        else
            GATE_REASON=vbus_supply_ambiguous
        fi
        return 1
    fi
    note supply "${supplies[0]}"
    present="$(read_attr "${SYSFS}/class/power_supply/${supplies[0]}/present")" || present=unreadable
    note present "${present}"
    case "${present}" in
        1) ;;
        0) GATE_REASON=vbus_absent; GATE_EXIT=0; return 1 ;;
        *) GATE_REASON=vbus_unreadable; GATE_EXIT=1; return 1 ;;
    esac

    for dir in "${SYSFS}"/class/regulator/*; do
        [ -d "${dir}" ] || continue
        if ! name="$(read_attr "${dir}/name")"; then
            note boost_state "unknown"
            GATE_REASON=regulator_name_unreadable; GATE_EXIT=1
            return 1
        fi
        [ "${name}" = "${BOOST_REGULATOR}" ] && boosts+=("${dir}")
    done
    if [ "${#boosts[@]}" -ne 1 ]; then
        note boost_state "count:${#boosts[@]}"
        GATE_EXIT=1
        if [ "${#boosts[@]}" -eq 0 ]; then
            GATE_REASON=boost_regulator_missing
        else
            GATE_REASON=boost_regulator_ambiguous
        fi
        return 1
    fi
    state="$(read_attr "${boosts[0]}/state")" || state=unreadable
    users="$(read_attr "${boosts[0]}/num_users")" || users=unreadable
    note boost_state "${state}"
    note boost_users "${users}"
    if [ "${state}" = enabled ] || { [[ "${users}" =~ ^[0-9]+$ ]] && [ "${users}" -gt 0 ]; }; then
        GATE_REASON=boost_enabled; GATE_EXIT=1
        return 1
    fi
    if [ "${state}" != disabled ] || [ "${users}" != 0 ]; then
        GATE_REASON=boost_state_unknown; GATE_EXIT=1
        return 1
    fi
    return 0
}

# discover_controller -- sets MUSB and UDC, or REASON on failure.
discover_controller() {
    local dir parent found=()
    for dir in "${SYSFS}"/bus/platform/devices/musb-hdrc.*; do
        [ -e "${dir}/mode" ] || continue
        found+=("${dir}")
    done
    if [ "${#found[@]}" -ne 1 ]; then
        note musb "count:${#found[@]}"
        if [ "${#found[@]}" -eq 0 ]; then
            REASON=musb_missing
        else
            REASON=musb_ambiguous
        fi
        return 1
    fi
    MUSB="${found[0]##*/}"
    note musb "${MUSB}"
    parent="$(readlink -f "${found[0]}")" || { REASON=musb_unresolvable; return 1; }
    parent="${parent%/*}"
    if [ "${parent##*/}" != "${MUSB_PARENT}" ]; then
        REASON=musb_unexpected_parent
        return 1
    fi
    MUSB_DIR="${found[0]}"
    UDC="${MUSB}"
    if [ ! -d "${SYSFS}/class/udc/${UDC}" ]; then
        REASON=udc_missing
        return 1
    fi
    note udc "${UDC}"
    return 0
}

gadget_write() {
    printf '%s\n' "$2" > "${GADGET_DIR}/$1" 2>/dev/null
}

# prepare_gadget -- idempotent configfs construction; sets REASON on failure.
prepare_gadget() {
    local other bound
    if [ ! -d "${CONFIGFS}/usb_gadget" ]; then
        REASON=configfs_gadget_unavailable
        return 1
    fi
    for other in "${CONFIGFS}"/usb_gadget/*/UDC; do
        [ -e "${other}" ] || continue
        [ "${other}" = "${GADGET_DIR}/UDC" ] && continue
        if [ "$(read_attr "${other}" || true)" = "${UDC}" ]; then
            REASON=udc_in_use
            return 1
        fi
    done
    if [ -d "${GADGET_DIR}" ]; then
        bound="$(read_attr "${GADGET_DIR}/UDC" || true)"
        if [ -n "${bound}" ]; then
            [ "${bound}" = "${UDC}" ] && return 0
            REASON=gadget_bound_elsewhere
            return 1
        fi
    fi
    mkdir -p "${GADGET_DIR}" "${GADGET_DIR}/strings/0x409" \
        "${GADGET_DIR}/configs/${CONFIG}/strings/0x409" 2>/dev/null \
        || { REASON=gadget_create_failed; return 1; }
    mkdir -p "${GADGET_DIR}/functions/${NCM_FUNCTION}" 2>/dev/null \
        || { REASON=ncm_function_unavailable; return 1; }
    if ! { gadget_write idVendor "${GADGET_VID}" &&
            gadget_write idProduct "${GADGET_PID}" &&
            gadget_write bcdDevice "${GADGET_BCD_DEVICE}" &&
            gadget_write bcdUSB "${GADGET_BCD_USB}" &&
            gadget_write strings/0x409/manufacturer "PocketForge" &&
            gadget_write strings/0x409/product "PocketForge bench usbnet (usbnet-v1)" &&
            gadget_write strings/0x409/serialnumber "pocketforge-usbnet-v1" &&
            gadget_write "configs/${CONFIG}/bmAttributes" 0xc0 &&
            gadget_write "configs/${CONFIG}/MaxPower" 100 &&
            gadget_write "configs/${CONFIG}/strings/0x409/configuration" "usbnet-v1 NCM" &&
            gadget_write "functions/${NCM_FUNCTION}/dev_addr" "${DUT_MAC}" &&
            gadget_write "functions/${NCM_FUNCTION}/host_addr" "${HOST_MAC}"; }; then
        REASON=gadget_attribute_write_failed
        return 1
    fi
    if [ ! -L "${GADGET_DIR}/configs/${CONFIG}/${NCM_FUNCTION}" ]; then
        ln -s "${GADGET_DIR}/functions/${NCM_FUNCTION}" \
            "${GADGET_DIR}/configs/${CONFIG}/${NCM_FUNCTION}" 2>/dev/null \
            || { REASON=gadget_link_failed; return 1; }
    fi
    return 0
}

main() {
    local bound
    GADGET_DIR="${CONFIGFS}/usb_gadget/${GADGET}"
    if ! mkdir -p "${STATE_DIR}" 2>/dev/null; then
        log "decision=hold reason=state_dir_unavailable"
        exit 1
    fi
    if [ -e "${STATE_DIR}/mode-written" ]; then
        note mode_written yes
    else
        note mode_written no
    fi
    if [ -e "${STATE_DIR}/switched" ]; then
        note bound latched
        finish already_switched latched_until_reboot 0
    fi

    evaluate_gate || finish hold "${GATE_REASON}" "${GATE_EXIT}"
    discover_controller || finish hold "${REASON}" 1
    prepare_gadget || finish hold "${REASON}" 1
    # Fresh read immediately before the role write.
    evaluate_gate || finish hold "${GATE_REASON}" "${GATE_EXIT}"

    note musb_mode_before "$(read_attr "${MUSB_DIR}/mode" || printf unreadable)"
    if [ ! -e "${STATE_DIR}/mode-written" ]; then
        printf 'peripheral\n' > "${MUSB_DIR}/mode" 2>/dev/null \
            || finish hold musb_mode_write_failed 1
        : > "${STATE_DIR}/mode-written"
        note mode_written yes
    fi

    bound="$(read_attr "${GADGET_DIR}/UDC" || true)"
    if [ "${bound}" != "${UDC}" ]; then
        gadget_write UDC "${UDC}" || { note bound no; finish error udc_bind_failed 1; }
    fi
    note bound yes
    : > "${STATE_DIR}/switched"
    finish switched external_vbus_present 0
}

main "$@"
