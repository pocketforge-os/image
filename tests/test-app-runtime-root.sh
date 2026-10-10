#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B "${root}/tests/test_app_runtime_root.py" "$@"
exec python3 -B "${root}/tests/test_app_runtime_abi.py" "$@"
