#!/bin/sh
# =============================================================================
# wifi-watchdog.sh — Self-heal wlan0 when the xr819/xr829 drops its DHCP lease
# =============================================================================
# The XR819/XR829 (xradio) WiFi chip enters a frame-dropping state after the
# link goes idle for a while (~15 min observed on the a133 owned substrate):
# wpa_supplicant still reports CTRL-EVENT-CONNECTED (no disconnect event), but
# the DHCP lease is gone — `ip -4 addr show wlan0` is empty and the device
# becomes unreachable. `networkctl reconfigure wlan0` does NOT recover it;
# `systemctl restart wpa_supplicant@wlan0` recovers it fully in ~15s (clean
# deauth reason=3 -> rejoin -> lease). See bd tsp-h1o (evidence 2026-07-04,
# image 6b8bc7f4). The driver-level fix lives in tsp-urq; this is the cheap
# userspace mitigation that keeps the device reachable (Goal-2 OTA depends on
# sustained reachability) until that lands.
#
# Design:
#   - Authoritative health signal = a global IPv4 lease on wlan0. This is the
#     directly-observed failure mode (lease disappears), and it never false-
#     positives.
#   - Secondary signal = the default gateway answers a ping. This catches the
#     "lease still present but link is dead/lossy" case. To stay false-positive
#     safe on APs that filter ICMP to the gateway, ping-failure only counts as
#     unhealthy AFTER the gateway has answered at least once this session
#     (gw_pingable) — so a permanently-filtered gateway is treated as "ping not
#     a usable signal" and we fall back to lease-only.
#   - Act only after FAIL_THRESHOLD consecutive failures (debounce), then
#     restart wpa_supplicant@wlan0 and grant a recovery grace period for DHCP.
#   - Backoff: if restarts aren't restoring the link (AP genuinely down/out of
#     range), the post-restart cooldown grows (capped) so we don't tight-loop.
#   - A WiFi-less image never reaches here: the unit's ConditionPathExists on
#     the generated wpa_supplicant conf skips it cleanly.
#
# Policy knob (parity with wifi-powersave.sh): set WIFI_WATCHDOG=off in
# /boot/wifi.txt to disable the watchdog without a rebuild.
#
# bd: tsp-h1o
# =============================================================================
set -u   # NOT -e: the health loop must survive transient command failures.

WIFI_CONF="/boot/wifi.txt"
IFACE="wlan0"
SERVICE="wpa_supplicant@wlan0.service"

CHECK_INTERVAL=30      # seconds between health checks
FAIL_THRESHOLD=3       # consecutive failures before acting (~90s of sustained loss)
RECOVERY_GRACE=45      # seconds to let DHCP resettle after a restart
BACKOFF_MAX=300        # cap (s) on the post-restart cooldown when restarts don't help

log() { echo "[pocketforge-wifi-watchdog] $*"; }

# --- optional disable knob from /boot/wifi.txt -------------------------------
ENABLED="on"
if [ -f "${WIFI_CONF}" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$line" in
            ""|\#*) continue ;;
        esac
        key="${line%%=*}"
        val="${line#*=}"
        if [ "$key" = "WIFI_WATCHDOG" ]; then
            case "$(echo "$val" | tr '[:upper:]' '[:lower:]')" in
                off|false|0) ENABLED="off" ;;
                on|true|1)   ENABLED="on" ;;
                *) log "WARN: unrecognized WIFI_WATCHDOG='${val}' — using default (on)" ;;
            esac
        fi
    done < "${WIFI_CONF}"
fi
if [ "${ENABLED}" = "off" ]; then
    log "disabled via WIFI_WATCHDOG=off in ${WIFI_CONF} — exiting"
    exit 0
fi

# --- health probes -----------------------------------------------------------
gw_of() {
    # default gateway reachable via wlan0, if any
    ip -4 route show default 2>/dev/null \
        | awk -v ifc="${IFACE}" '$0 ~ ("dev " ifc){for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}
has_lease() {
    # a global-scope IPv4 address on wlan0 (the DHCP lease); link-local excluded
    ip -4 -o addr show dev "${IFACE}" scope global 2>/dev/null | grep -q .
}

gw_pingable=0   # set to 1 once the gateway has answered — rules out ICMP filtering

healthy() {
    # Authoritative: no lease => unhealthy (the observed xr819 failure).
    has_lease || return 1
    gw="$(gw_of)"
    [ -n "${gw}" ] || return 0   # lease present but route not up yet: don't thrash
    if ping -c 1 -W 2 -I "${IFACE}" "${gw}" >/dev/null 2>&1; then
        gw_pingable=1
        return 0
    fi
    # ping failed: only trust it as "unhealthy" once we've seen the gw answer.
    [ "${gw_pingable}" = "1" ] && return 1
    return 0
}

log "starting (interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD} grace=${RECOVERY_GRACE}s)"
fails=0
backoff=0
while :; do
    sleep "${CHECK_INTERVAL}"

    # Interface gone entirely (driver unload / no hardware): don't count it as a
    # link failure — nothing to restart-heal, and we must not tight-loop.
    if [ ! -e "/sys/class/net/${IFACE}" ]; then
        fails=0
        continue
    fi

    if healthy; then
        [ "${fails}" -ne 0 ] || [ "${backoff}" -ne 0 ] && log "link healthy"
        fails=0
        backoff=0
        continue
    fi

    fails=$((fails + 1))
    log "health check failed (${fails}/${FAIL_THRESHOLD}): no lease or gateway unreachable on ${IFACE}"
    [ "${fails}" -lt "${FAIL_THRESHOLD}" ] && continue

    log "restarting ${SERVICE} to recover ${IFACE}"
    systemctl restart "${SERVICE}" || log "WARN: 'systemctl restart ${SERVICE}' failed"
    fails=0

    cooldown=$((RECOVERY_GRACE + backoff))
    [ "${cooldown}" -gt "${BACKOFF_MAX}" ] && cooldown=${BACKOFF_MAX}
    log "waiting ${cooldown}s for DHCP to resettle"
    sleep "${cooldown}"

    if healthy; then
        log "link recovered after restart"
        backoff=0
    else
        # still down (AP likely genuinely absent): grow the cooldown, capped.
        backoff=$((backoff + RECOVERY_GRACE))
        [ "${backoff}" -gt "${BACKOFF_MAX}" ] && backoff=${BACKOFF_MAX}
    fi
done
