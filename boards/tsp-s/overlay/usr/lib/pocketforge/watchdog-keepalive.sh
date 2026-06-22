#!/bin/sh
# =============================================================================
# watchdog-keepalive.sh — feed the A523 sunxi hardware watchdog (tsp-vuo.4)
# =============================================================================
# The A523 sunxi-wdt (2050000.watchdog, 16s) auto-arms at kernel probe and the
# kernel reports it CANNOT be stopped ("watchdog0: watchdog did not stop!"), so
# something must ping it continuously or the device resets ~16s after the
# initrd's last ping. systemd's native RuntimeWatchdog did NOT engage on this
# board (no "Using hardware watchdog" message; device reset right after reaching
# login on the first tsp-vuo.4 boot), so we feed it directly here.
#
# Holds the device fd open (fd 3) and writes a non-'V' byte every PING_SEC.
# Restart=always in the unit re-opens if this ever exits. TEMPORARY: revisit and
# move to systemd's native RuntimeWatchdog once its non-engagement on the A523
# is root-caused (tracked as a tsp-vuo follow-up).
PING_SEC="${PING_SEC:-6}"
WD=/dev/watchdog0
[ -c "$WD" ] || WD=/dev/watchdog
[ -c "$WD" ] || { echo "watchdog-keepalive: no watchdog device" >&2; exit 1; }
exec 3>"$WD" || { echo "watchdog-keepalive: cannot open $WD" >&2; exit 1; }
echo "watchdog-keepalive: feeding $WD every ${PING_SEC}s"
while :; do
    printf '\0' >&3 2>/dev/null || { echo "watchdog-keepalive: write to $WD failed" >&2; exit 1; }
    sleep "$PING_SEC"
done
