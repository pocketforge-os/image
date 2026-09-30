#!/usr/bin/env bash
# The dev bench USB0 role script switches to peripheral only under external
# VBUS with the boost off, writes `mode` at most once per boot before binding
# the usbnet contract v1 gadget, and never writes a regulator, power_supply or
# vbus path (bd tsp-mc9m.41.984.34.2). The cases and the write recorder are
# documented in tests/test-usbnet-bench-role.py.
#
# It runs the production script in an unprivileged bwrap view with a read-only
# root; a fake /sys and /run are the only writable trees. No container, no
# systemd, no device.
#
# Usage: tests/test-usbnet-bench-role.sh [--keep]
# Exit status: 0 PASS, 1 FAIL, 75 BLOCKED.
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
exec python3 -B "${root}/tests/test-usbnet-bench-role.py" "$@"
