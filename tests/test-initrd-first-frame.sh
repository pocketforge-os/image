#!/usr/bin/env bash
# Hermetic tests for the initrd first-light frame-000 hook (bd tsp-3rd3.7): the
# real boards/tsp/initrd/init end to end in a bubblewrap fake root (bash, and the
# device busybox ash via qemu when PF_TEST_BUSYBOX_ARM64 is set), the build-
# initrd.sh staging gate, and red runs of deliberately broken copies. No device.
# See tests/test_initrd_first_frame.py.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -B "${root}/tests/test_initrd_first_frame.py" "$@"
