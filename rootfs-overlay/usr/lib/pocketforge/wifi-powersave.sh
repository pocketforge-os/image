#!/bin/sh
# =============================================================================
# wifi-powersave.sh — Apply the WiFi power-save policy to wlan0
# =============================================================================
# PocketForge is a WiFi game-streaming appliance (Steam Link). A stable, low-
# latency link is a product requirement, so the DEFAULT policy is power-save
# OFF:
#   - During streaming the radio is saturated, so 802.11 power-save never
#     engages anyway — it would only add latency risk.
#   - The XR819/XR829 (xradio) power-save implementation is unreliable and
#     causes a ~30s deauth (Reason 6) / reassociate flap that prevents a
#     stable DHCP lease. See bd tsp-cv7.4.12.
#   - The real battery lever on this handheld is screen-off / suspend (which
#     powers the radio down entirely), not dozing the radio mid-session.
#
# This is a POLICY KNOB, not a hardcode. It reads an optional POWER_SAVE key
# from the same user-editable /boot/wifi.txt that holds the credentials, so the
# setting can be changed from the OS (edit + reboot) without a rebuild, and a
# future appliance power-manager can own it contextually (force-off while
# streaming, suspend-based idle savings, re-enable only once the owned xradio
# driver's power-save is proven stable).
#
#   POWER_SAVE=off   (default) — stability-first; recommended.
#   POWER_SAVE=on              — let the chip doze when idle (may flap on xradio).
#
# bd: tsp-cv7.4.12
# =============================================================================
set -eu

WIFI_CONF="/boot/wifi.txt"
IFACE="wlan0"
DESIRED="off"   # product default: stability-first

log() { echo "[pocketforge-wifi-powersave] $*"; }

# --- read the optional POWER_SAVE knob from /boot/wifi.txt --------------------
if [ -f "${WIFI_CONF}" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$line" in
            ""|\#*) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        if [ "$key" = "POWER_SAVE" ]; then
            case "$(echo "$val" | tr '[:upper:]' '[:lower:]')" in
                on|true|1)  DESIRED="on" ;;
                off|false|0) DESIRED="off" ;;
                *) log "WARN: unrecognized POWER_SAVE='${val}' — using default (off)" ;;
            esac
        fi
    done < "${WIFI_CONF}"
fi

# --- apply -------------------------------------------------------------------
if [ ! -e "/sys/class/net/${IFACE}" ]; then
    log "WARN: ${IFACE} not present — nothing to do"
    exit 0
fi

log "Setting ${IFACE} power_save ${DESIRED}"
iw dev "${IFACE}" set power_save "${DESIRED}"
log "Applied (power_save ${DESIRED}); current: $(iw dev "${IFACE}" get power_save 2>/dev/null || echo '?')"
