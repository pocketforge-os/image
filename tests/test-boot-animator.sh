#!/usr/bin/env bash
# Hermetic boot-animator tests (bd tsp-3rd3.6): orientation goldens against the
# kernel's table, vendor byte-identity, hold-last-frame, crop reproducibility,
# cost budget, unit verification. No device. See
# apps/pocketforge-boot-animator/tests/test_animator.py.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 -B "${root}/apps/pocketforge-boot-animator/tests/test_animator.py" "$@"
