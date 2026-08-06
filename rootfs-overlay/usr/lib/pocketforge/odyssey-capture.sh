#!/bin/sh
# Fire the diagnostic capture without relying on the fragile serial command path.
# This file is installed only when PF_ODYSSEY_CAPTURE=1.
set -u

echo "PF-ODYSSEY-CAPTURE-UNIT: start"

if ! printf 'Y\n' > /sys/module/pvrsrvkm/parameters/odyssey_capture; then
    echo "PF-ODYSSEY-CAPTURE-UNIT: capture parameter unavailable"
    exit 0
fi

pf-take-panel env SDL_VIDEODRIVER=sunxifb \
    /opt/pocketforge/bin/testgles2 --quit-after-ms 15000 &
runner_pid=$!
echo "PF-ODYSSEY-CAPTURE-UNIT: fired"

# testgles2 can wedge after its first rendered frames. Give the capture ample
# time to fire, then kill the renderer and bound cleanup of the systemd-run
# client so this diagnostic can never hold up boot indefinitely.
sleep 16
pkill -9 -x testgles2 2>/dev/null || true

cleanup_wait=0
while kill -0 "${runner_pid}" 2>/dev/null && [ "${cleanup_wait}" -lt 3 ]; do
    sleep 1
    cleanup_wait=$((cleanup_wait + 1))
done
kill "${runner_pid}" 2>/dev/null || true
wait "${runner_pid}" 2>/dev/null || true

echo "PF-ODYSSEY-CAPTURE-UNIT: complete"
exit 0
