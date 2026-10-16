#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
exec python3 "$root/tests/test-a133-battery-model-firmware.py"
