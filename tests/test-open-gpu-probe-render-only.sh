#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
python3 -B "$root/tests/test-open-gpu-probe-render-only.py" "$@"
