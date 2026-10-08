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
# The first-boot seed intentionally has no driver-policy escape hatch. A future
# appliance power manager can own this contextually after the xradio driver's
# power-save path is proven stable.
#
# bd: tsp-cv7.4.12
# =============================================================================
set -eu

IFACE="wlan0"
DESIRED="off"   # product default: stability-first

log() { echo "[pocketforge-wifi-powersave] $*"; }

# --- apply -------------------------------------------------------------------
if [ ! -e "/sys/class/net/${IFACE}" ]; then
    log "WARN: ${IFACE} not present — nothing to do"
    exit 0
fi

log "Setting ${IFACE} power_save ${DESIRED}"
iw dev "${IFACE}" set power_save "${DESIRED}"
log "Applied (power_save ${DESIRED}); current: $(iw dev "${IFACE}" get power_save 2>/dev/null || echo '?')"
