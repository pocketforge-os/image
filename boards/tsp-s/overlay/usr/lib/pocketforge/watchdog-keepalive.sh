#!/bin/sh
# =============================================================================
# watchdog-keepalive.sh — A523 hardware-watchdog SAFETY NET (yields to systemd)
# =============================================================================
# Proper owner of the sunxi watchdog is systemd's RuntimeWatchdog
# (RuntimeWatchdogSec in /etc/systemd/system.conf.d/watchdog.conf). This script
# is only a fallback: the A523 sunxi-wdt (2050000.watchdog, 16s) auto-arms at
# probe and CANNOT be stopped, so if systemd's early RuntimeWatchdog open ever
# races/fails on this board the device would reset-loop. We open /dev/watchdog0
# ONLY if systemd hasn't already claimed it — if systemd owns it our open gets
# EBUSY and we yield (exit 0, no-op). When systemd engages (the normal, verified
# case) this does nothing. bd: tsp-vuo.4.
PING_SEC="${PING_SEC:-6}"
WD=/dev/watchdog0
[ -c "$WD" ] || WD=/dev/watchdog
[ -c "$WD" ] || { echo "watchdog-keepalive: no watchdog device present" >&2; exit 0; }

# Probe in a SUBSHELL so a failed open (EBUSY = systemd owns it) cannot kill us.
if ( exec 9>"$WD" ) 2>/dev/null; then
    : # device was free — systemd's RuntimeWatchdog did not claim it; we will.
else
    echo "watchdog-keepalive: $WD busy — systemd RuntimeWatchdog owns it; yielding (no-op)" >&2
    exit 0
fi

# Claim it for real and feed it. (Reaching here means systemd did NOT take it.)
if ! ( exec 3>"$WD" ) 2>/dev/null; then
    echo "watchdog-keepalive: lost race opening $WD; yielding" >&2
    exit 0
fi
exec 3>"$WD"
echo "watchdog-keepalive: systemd did NOT claim the watchdog — feeding $WD every ${PING_SEC}s"
while :; do
    printf '\0' >&3 2>/dev/null || { echo "watchdog-keepalive: write to $WD failed" >&2; exit 1; }
    sleep "$PING_SEC"
done
