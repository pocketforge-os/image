#!/bin/sh
# =============================================================================
# wifi-setup.sh — Template WiFi credentials from /boot/wifi.txt
# =============================================================================
# Reads a plain key=value config from the boot-resource FAT partition
# (mounted read-only at /boot) and generates a wpa_supplicant config at
# /etc/wpa_supplicant/wpa_supplicant-wlan0.conf.
#
# Called by pocketforge-wifi-setup.service (Type=oneshot, Before=
# wpa_supplicant@wlan0.service). Idempotent: re-running with the same
# wifi.txt produces the same output; re-running with a changed wifi.txt
# overwrites the old config.
#
# wifi.txt format (one key=value per line, # comments, blank lines ok):
#   SSID=MyNetwork
#   PSK=MyPassword
#   # Optional — defaults to WPA-PSK if omitted:
#   KEY_MGMT=WPA-PSK
#
# If wifi.txt is missing or does not contain both SSID and PSK, this
# script logs a warning and exits 0 (graceful degradation — wlan0 stays
# down but the device boots normally). wpa_supplicant@wlan0.service will
# fail to start (no config file) and systemd will not loop on it because
# the service is Type=simple, not Restart=always.
#
# bd: tsp-iuz.2.2
# =============================================================================
set -eu

WIFI_CONF="/boot/wifi.txt"
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
WPA_DIR="$(dirname "${WPA_CONF}")"

log() { echo "[pocketforge-wifi] $*"; }

# --- read wifi.txt -----------------------------------------------------------
if [ ! -f "${WIFI_CONF}" ]; then
    log "WARN: ${WIFI_CONF} not found — WiFi will not be configured"
    exit 0
fi

SSID=""
PSK=""
KEY_MGMT=""

while IFS= read -r line || [ -n "$line" ]; do
    # Strip leading/trailing whitespace, skip comments and blank lines
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$line" in
        ""|\#*) continue ;;
    esac

    key="${line%%=*}"
    val="${line#*=}"

    case "$key" in
        SSID)     SSID="$val" ;;
        PSK)      PSK="$val" ;;
        KEY_MGMT) KEY_MGMT="$val" ;;
        *)        log "WARN: unknown key '${key}' in ${WIFI_CONF} — ignored" ;;
    esac
done < "${WIFI_CONF}"

# --- validate ----------------------------------------------------------------
if [ -z "${SSID}" ]; then
    log "WARN: SSID not set in ${WIFI_CONF} — WiFi will not be configured"
    exit 0
fi

if [ -z "${PSK}" ]; then
    log "WARN: PSK not set in ${WIFI_CONF} — WiFi will not be configured"
    exit 0
fi

# Default key management if not specified.
# We list FT-PSK alongside WPA-PSK so wpa_supplicant uses 802.11r Fast BSS
# Transition when the AP advertises it (same Mobility Domain), and falls back to
# plain WPA-PSK otherwise — see the FT note in the roaming-policy block below
# (tsp-rcb). wpa_supplicant negotiates per-AP, so this is safe on any network.
if [ -z "${KEY_MGMT}" ]; then
    KEY_MGMT="WPA-PSK FT-PSK"
fi

# --- roaming policy (tsp-008) -------------------------------------------------
# The base unit's XR829 is a single-radio soft-MAC whose foreground scan is
# NON-split, so each scan briefly stalls the associated link (and is the state
# its firmware is most fragile in). We therefore roam CONSERVATIVELY — only when
# the link is already weak — using the channel-LEARNING bgscan so a background
# scan touches just this network's channels (~3-5) instead of all ~25+. The
# firmware-offloaded CQM RSSI events drive the trigger. 802.11v BSS-TM is honored
# by default (wpa_supplicant is built with WNM), letting the AP hand us a roam
# target with no scan at all. 802.11r FT-PSK is now also requested (key_mgmt
# above): the xr829 is a soft-MAC and wpa_supplicant runs FT over-the-air via the
# kernel's userspace-SME auth/assoc path, so an FT transition skips the 4-way
# handshake and collapses the reassociation gap (tsp-rcb — under on-device
# validation; falls back to a full reassoc on APs that don't advertise FT).
# A near-dormant "don't scan during an active stream" profile is deferred to the
# kiosk supervisor (tsp-rcb).
# Tunables — learn:<short_s>:<signal_threshold_dBm>:<long_s>:<db>. Threshold -67:
# keep short-interval (30s) scanning whenever the link is NOT clearly strong, so we
# roam OFF a weak mesh node back to the strongest AP instead of sticking on it
# (also compensates for the driver's laggy 16-sample RCPI averaging). The long
# interval stays 600s so a clearly-strong link scans rarely — the firmware-fragile
# off-channel scan dwell is the costly moment on this single-radio non-split-scan
# radio, so we minimise it when the link is already good. The DB self-learns at
# runtime, so this works on ANY user network with no per-network configuration; it
# persists across reboots under /var/lib (tsp-5f7 AP-selection / roam-stickiness).
BGSCAN_DB_DIR="/var/lib/wpa_supplicant"
SSID_SAFE="$(printf '%s' "${SSID}" | tr -c 'A-Za-z0-9._-' '_')"
BGSCAN_DB="${BGSCAN_DB_DIR}/bgscan-${SSID_SAFE}.db"
mkdir -p "${BGSCAN_DB_DIR}"

# --- template wpa_supplicant config ------------------------------------------
log "Generating ${WPA_CONF} (SSID=${SSID}, key_mgmt=${KEY_MGMT}, bgscan=learn)"

mkdir -p "${WPA_DIR}"

cat > "${WPA_CONF}" << EOF
# Auto-generated by pocketforge wifi-setup.sh from /boot/wifi.txt
# Do not edit directly — edit /boot/wifi.txt instead and reboot.
ctrl_interface=/run/wpa_supplicant
update_config=0
# Keep BSSes seen in the table between our infrequent background scans, so a
# learned roam target (incl. the strongest AP) isn't aged out before the next
# (rare) scan — survives a transient missed scan during a recovery window, so the
# strong AP stays selectable instead of leaving only a weak node (tsp-008, tsp-5f7).
ap_scan=1
bss_expiration_age=600

network={
    ssid="${SSID}"
    psk="${PSK}"
    key_mgmt=${KEY_MGMT}
    # Active-probe the SSID on every scan so ALL member BSSes (incl. the strongest
    # AP) are reliably present at initial / post-recovery selection — wpa_supplicant
    # has no minimum-signal association floor and simply picks the strongest BSS
    # present in the scan results, so "lands on a weak node" means the strong AP was
    # missing from that scan; active probing closes that gap (tsp-5f7).
    scan_ssid=1
    # Channel-learning background scan: short-interval scan whenever the link is NOT
    # clearly strong (< -67 dBm) so we discover + roam back to the strongest AP
    # instead of sticking on a weak mesh node; a clearly-strong link uses the long
    # interval (rare scans), keeping the firmware-fragile off-channel dwell minimal.
    # Self-learns channels; works on any net (tsp-5f7).
    bgscan="learn:30:-67:600:${BGSCAN_DB}"
}
EOF

chmod 0600 "${WPA_CONF}"
log "WiFi config written successfully (roaming: bgscan=learn, 802.11v BTM active)"
