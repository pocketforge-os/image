#!/bin/sh
# =============================================================================
# audio-defaults.sh: apply boot-time mixer defaults to the sun4i-codec card
# =============================================================================
# Installed only on open-kernel profiles (kernel-sunxi-6.x / kernel-sunxi-7.x)
# by scripts/install-alsa-config.sh. The mainline sun4i-codec driver comes up
# with the speaker path muted (DAC-to-mixer, Line Out enable and Line Out
# volume all reset to off/mute), so without this nothing is audible even when
# playback runs. Values and their provenance live in the defaults file.
#
# Run by pocketforge-audio-defaults.service, which sound.target pulls in when
# a sound card appears.
#
# bd: tsp-f3fm.220
# =============================================================================
set -u

CARD="${PF_AUDIO_CARD:-Codec}"
DEFAULTS="${PF_AUDIO_DEFAULTS:-/usr/share/pocketforge/alsa/mixer-defaults.sun4i-codec}"
# Test seams (tests/test-alsa-config.sh); the unit sets none of these.
PROC_ASOUND="${PF_AUDIO_PROC_ASOUND:-/proc/asound}"
WAIT_TRIES="${PF_AUDIO_WAIT_TRIES:-20}"

log() { echo "pocketforge-audio-defaults: $*"; }

[ -r "${DEFAULTS}" ] || { log "FAIL: defaults file missing: ${DEFAULTS}"; exit 1; }

# Debian's 90-alsa-restore.rules runs `alsactl restore` from udev when the
# control device appears. Let that finish first so it cannot overwrite the
# values set below. Bounded wait: on timeout, apply anyway.
udevadm settle --timeout=10 || log "WARN: udevadm settle timed out; applying anyway"

# /proc/asound/<id> is the card-id symlink. Wait up to 10 s for it.
tries=0
while [ ! -e "${PROC_ASOUND}/${CARD}" ]; do
    tries=$((tries + 1))
    if [ "${tries}" -gt "${WAIT_TRIES}" ]; then
        log "FAIL: card '${CARD}' not present in ${PROC_ASOUND}"
        exit 1
    fi
    sleep 0.5
done

failed=0
while IFS= read -r line || [ -n "${line}" ]; do
    case "${line}" in
        ''|'#'*) continue ;;
    esac
    name="${line%%=*}"
    value="${line#*=}"
    if amixer -q -c "${CARD}" cset "name=${name}" "${value}"; then
        log "set '${name}' = ${value}"
    else
        log "FAIL: could not set '${name}' = ${value} on card ${CARD}"
        failed=1
    fi
done < "${DEFAULTS}"

exit "${failed}"
