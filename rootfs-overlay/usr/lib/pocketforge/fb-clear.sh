#!/bin/sh
# bd tsp-ooe: zero the framebuffer at boot so the panel shows clean black instead
# of uninitialized CMA memory (the "static noise" screen). Device readiness is
# ordered by the unit (After=dev-fb0.device via the 71-pocketforge-fb udev tag);
# the existence check is only the no-panel fallback. The full-fb write (both
# buffers of the double-buffered virtual size) ends at ENOSPC by design.
set -eu
[ -e /dev/fb0 ] || exit 0
cat /dev/zero > /dev/fb0 2>/dev/null || true
exit 0
