#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="${root}/.github/workflows/hermetic-tests.yml"

grep -Fq 'tests/test-initrd-selfflash-v3-arm.py' "${workflow}"
grep -Fq 'tests/test-self-flash-v3-growth.py' "${workflow}"
grep -Fq 'tests/test-self-flash-v3-stage.py' "${workflow}"

grep -Fq 'case "${t}" in' "${workflow}" || {
    echo 'FAIL: hermetic test loop does not dispatch by file type' >&2
    exit 1
}
grep -Fq '*.py) runner=(env PYTHONDONTWRITEBYTECODE=1 python3 "${t}") ;;' "${workflow}" || {
    echo 'FAIL: hermetic Python rows can leave bytecode in the source overlay' >&2
    exit 1
}
grep -Fq '*.sh) runner=(bash "${t}") ;;' "${workflow}" || {
    echo 'FAIL: hermetic test loop does not run shell rows with bash' >&2
    exit 1
}
grep -Fq 'if "${runner[@]}"; then' "${workflow}" || {
    echo 'FAIL: hermetic test loop does not invoke the selected runner' >&2
    exit 1
}

echo 'PASS: hermetic test loop dispatches shell and Python rows explicitly'
