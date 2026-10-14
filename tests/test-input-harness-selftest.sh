#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B "${repo_root}/tests/uinput_inventory.py" --self-test
"${repo_root}/tests/input-harness/selftest/test-negative-control-wrapper.sh"
"${repo_root}/tests/input-harness/selftest/test-fake-input-guard.sh"
"${repo_root}/tests/input-harness/selftest/test-apt-proxy-guard.sh"
"${repo_root}/tests/input-harness/selftest/test-payload-reproducibility.sh"
python3 -B "${repo_root}/tests/input-harness/selftest/test-guest-agent.py"
python3 -B "${repo_root}/tests/input-harness/selftest/test-guest-kernel-cleanup.py"
exec python3 -B "${repo_root}/tests/test-input-harness-selftest.py"
