#!/bin/sh
# bd tsp-ooe: zero the framebuffer at boot so the panel shows clean black instead
# of uninitialized CMA memory (the "static noise" screen). Writes the whole fb
# (both buffers of the double-buffered virtual size); the write stops at ENOSPC.
i=0
while [ ! -e /dev/fb0 ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
done
[ -e /dev/fb0 ] || exit 0
cat /dev/zero > /dev/fb0 2>/dev/null || true
exit 0
