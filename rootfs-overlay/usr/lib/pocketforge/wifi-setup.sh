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
#   # Optional — ISO 3166-1 alpha-2 regulatory domain; defaults to US if omitted:
#   COUNTRY=US
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
COUNTRY=""

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
        COUNTRY)  COUNTRY="$val" ;;
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

# --- roam profile (board-scoped) --------------------------------------------
# Roaming/scan policy is radio-specific, so it is selected per board. The
# DEFAULT is "xr829" (base A133 single-radio soft-MAC): userspace 802.11r
# FT-PSK + a channel-learning bgscan. The Smart Pro S / A523 fullmac AIC8800D80
# does roaming AND scanning in its own firmware and must NOT be handed userspace
# FT/bgscan (the vendor stock image associates cleanly with a plain WPA-PSK
# config on this radio); it opts into the "fullmac" profile by shipping
# /etc/pocketforge/wifi-roam.conf (written by boards/tsp-s/rootfs-customize.sh).
# Sourcing that optional file may set WIFI_ROAM_PROFILE — it is the ONLY
# board-specific input to this otherwise-shared script.
WIFI_ROAM_PROFILE="xr829"
if [ -r /etc/pocketforge/wifi-roam.conf ]; then
    . /etc/pocketforge/wifi-roam.conf
fi

# Default key management if not specified in wifi.txt — plain WPA-PSK on BOTH
# profiles.
# tsp-p6p5: FT-PSK was REMOVED from the xr829 default. The xr829 has NO working
# 802.11r Fast BSS Transition (tsp-rcb source audit: no `.update_ft_ies` op, the
# umac FT path is "TODO not supported", vendor states 11r "not supported by XR
# solution"). Requesting FT-PSK made wpa_supplicant attempt FT transitions across
# a multi-AP mesh (e.g. Cobblejob, 2 same-SSID APs on ch3+ch11); on the FT reassoc
# the driver's join state stays UNJOINED when mac80211 programs the key
# (`[AP_WRN] BSS_CHANGED_ASSOC but driver is unjoined` → `set_key` with no join
# context → `[RX] No key found` → data plane dead, with `[WSM] unjoin TMO` churn).
# Plain WPA-PSK forces a full reassociation + 4-way handshake on every roam, which
# programs the key with a valid join context (the only path this radio supports).
# fullmac (A523): plain WPA-PSK too — its chip firmware owns roaming.
if [ -z "${KEY_MGMT}" ]; then
    KEY_MGMT="WPA-PSK"
fi

# --- regulatory domain (tsp-myp1.8.2) -----------------------------------------
# Nothing in the image set a regdomain before this, so the kernel stayed on the
# world domain ("00" — the most-restrictive intersection: lower TX power caps and
# no-IR on several channels). Set it explicitly via wpa_supplicant `country=`
# (an nl80211 regdomain hint applied when the interface comes up — no extra
# service or iw call needed, and it rides the same generated conf that already
# survives the profile split). Optional COUNTRY= in wifi.txt overrides; default
# US. Applied to the xr829/A133 profile only — the fullmac/A523 profile stays a
# minimal vendor-parity config (its chip firmware manages its own regulatory
# behavior; do not disturb a proven-associating config). Verify on-device with
# `iw reg get` before/after (epic tsp-myp1.8 verify-item (d)).
COUNTRY="$(printf '%s' "${COUNTRY}" | tr 'a-z' 'A-Z')"
case "${COUNTRY}" in
    [A-Z][A-Z]) : ;;   # exactly two letters — keep
    "")         COUNTRY="US" ;;
    *)          log "WARN: invalid COUNTRY '${COUNTRY}' in ${WIFI_CONF} — using US"
                COUNTRY="US" ;;
esac

# --- template wpa_supplicant config ------------------------------------------
mkdir -p "${WPA_DIR}"

case "${WIFI_ROAM_PROFILE}" in
fullmac)
    # fullmac profile (AIC8800D80 / A523): minimal WPA-PSK, no userspace bgscan
    # or FT. The chip firmware owns roaming/scanning, and this mirrors the vendor
    # stock config proven to associate on this radio. ctrl_interface is kept so
    # wpa_cli / health probes work.
    log "Generating ${WPA_CONF} (SSID=${SSID}, key_mgmt=${KEY_MGMT}, profile=fullmac)"
    cat > "${WPA_CONF}" << EOF
# Auto-generated by pocketforge wifi-setup.sh from /boot/wifi.txt
# Do not edit directly — edit /boot/wifi.txt instead and reboot.
# Profile: fullmac (AIC8800D80 / A523) — roaming + scanning are done in the chip
# firmware, so this is a minimal WPA-PSK config with no userspace bgscan/FT
# (matches the vendor stock config, which associates cleanly on this radio).
ctrl_interface=/run/wpa_supplicant
update_config=0

network={
    ssid="${SSID}"
    psk="${PSK}"
    key_mgmt=${KEY_MGMT}
}
EOF
    ;;
*)
    # --- roaming policy: xr829 (base A133 soft-MAC) (tsp-008) ----------------
    # The base unit's XR829 is a single-radio soft-MAC whose foreground scan is
    # NON-split, so each scan briefly stalls the associated link (and is the state
    # its firmware is most fragile in). We therefore roam CONSERVATIVELY — only when
    # the link is already weak — using the channel-LEARNING bgscan so a background
    # scan touches just this network's channels (~3-5) instead of all ~25+. The
    # firmware-offloaded CQM RSSI events drive the trigger. 802.11v BSS-TM is honored
    # by default (wpa_supplicant is built with WNM), letting the AP hand us a roam
    # target with no scan at all. 802.11r FT-PSK is deliberately NOT requested
    # (key_mgmt above is plain WPA-PSK): the xr829 has no working FT support, so an
    # FT transition leaves the driver unjoined when the key is programmed and wedges
    # the data plane on a mesh (tsp-p6p5). Roams therefore use a full reassociation +
    # 4-way handshake — the reassociation gap is real but the link stays usable;
    # seamless/FT roaming remains future work on the driver side (tsp-rcb).
    # A near-dormant "don't scan during an active stream" profile is deferred to the
    # kiosk supervisor (tsp-rcb).
    # Tunables — learn:<short_s>:<signal_threshold_dBm>:<long_s>:<db>. RETUNED
    # 30:-67 → 60:-72 (tsp-myp1.8.5 Fix 2): the v4 live A/B showed learn:30:-67
    # costing 56-62ms AVG idle RTT with >100ms spikes + packet loss — even at
    # -34dBm — vs 4.3ms with bgscan off (scans steal airtime on this single-radio
    # non-split-scan chip, and in practice the SHORT-interval regime stays engaged
    # at strong signal: the laggy 16-sample RCPI averaging and the DB's
    # learning-probe scans keep it active). bgscan is NOT removed because it owns
    # weak→strong roam-back — `wpa_cli reassociate` deterministically re-picked a
    # -78dBm far AP twice in the same window; bgscan is what un-sticks that
    # (tsp-5f7's original purpose). The retune trades roam-back detection latency
    # for idle airtime: short interval 30s→60s halves worst-case scan theft
    # (weak-link roam-back now ~1-2 min, acceptable — a weak link is already
    # degraded); threshold -67→-72 widens the strong-signal long-interval band so
    # RCPI dips don't spuriously re-enter short-interval mode, while a genuinely
    # stuck weak link (the -78dBm case) still sits below threshold and keeps
    # short-interval roam-back scanning. Long interval stays 600s. Full tradeoff
    # record: bd tsp-5f7 + tsp-myp1.8.5. The DB self-learns at runtime, so this
    # works on ANY user network with no per-network configuration; it persists
    # across reboots under /var/lib (tsp-5f7 AP-selection / roam-stickiness).
    BGSCAN_DB_DIR="/var/lib/wpa_supplicant"
    SSID_SAFE="$(printf '%s' "${SSID}" | tr -c 'A-Za-z0-9._-' '_')"
    BGSCAN_DB="${BGSCAN_DB_DIR}/bgscan-${SSID_SAFE}.db"
    mkdir -p "${BGSCAN_DB_DIR}"
    log "Generating ${WPA_CONF} (SSID=${SSID}, key_mgmt=${KEY_MGMT}, country=${COUNTRY}, bgscan=learn)"
    cat > "${WPA_CONF}" << EOF
# Auto-generated by pocketforge wifi-setup.sh from /boot/wifi.txt
# Do not edit directly — edit /boot/wifi.txt instead and reboot.
ctrl_interface=/run/wpa_supplicant
update_config=0
# Explicit regulatory domain (nl80211 hint; default US, override via COUNTRY=
# in /boot/wifi.txt). Without it the kernel sits on the restrictive world
# domain "00" (tsp-myp1.8.2; verify with iw reg get — epic verify-item (d)).
country=${COUNTRY}
# Keep BSSes seen in the table between our infrequent background scans, so a
# learned roam target isn't aged out before the next (rare) scan (tsp-008).
# 600s matches the bgscan LONG interval below, so a learned roam target seen on
# the previous (rare) strong-link scan survives until the next one (tsp-5f7).
ap_scan=1
bss_expiration_age=600

network={
    ssid="${SSID}"
    psk="${PSK}"
    key_mgmt=${KEY_MGMT}
    # Probe for the SSID directly in scans (finds same-SSID mesh nodes that a
    # passive/broadcast scan on a brief dwell can miss) (tsp-5f7).
    scan_ssid=1
    # Channel-learning background scan: roam off a weak link toward the strongest
    # AP, with scans narrowed to this network's channels. Self-learns; works on
    # any net.
    bgscan="learn:60:-72:600:${BGSCAN_DB}"
}
EOF
    ;;
esac

chmod 0600 "${WPA_CONF}"
log "WiFi config written successfully (profile=${WIFI_ROAM_PROFILE})"
