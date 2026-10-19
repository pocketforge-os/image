#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
checker="${root}/scripts/check-overlay-coverage.py"
fixtures="${root}/tests/fixtures/overlay-coverage"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/overlay-coverage-test.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

if ! "${checker}" --repo "${fixtures}/valid" >"${tmp}/valid.out" 2>"${tmp}/valid.err"; then
    echo "FAIL: valid overlay fixture was rejected" >&2
    cat "${tmp}/valid.err" >&2
    exit 1
fi
grep -Fxq 'OVERLAY_COVERAGE PASS files=6 referenced=5 not_installed=1' "${tmp}/valid.out" || {
    echo 'FAIL: valid fixture did not report its complete coverage totals' >&2
    cat "${tmp}/valid.out" >&2
    exit 1
}

if "${checker}" --repo "${fixtures}/orphan" >"${tmp}/orphan.out" 2>"${tmp}/orphan.err"; then
    echo 'FAIL: orphan overlay fixture was accepted' >&2
    exit 1
fi
grep -Fq 'ORPHAN etc/systemd/system/pocketforge-foreground.target.d/10-owner-ghost.conf' \
    "${tmp}/orphan.err" || {
    echo 'FAIL: orphan fixture did not name its unreferenced file' >&2
    cat "${tmp}/orphan.err" >&2
    exit 1
}

if "${checker}" --repo "${fixtures}/dangling" >"${tmp}/dangling.out" 2>"${tmp}/dangling.err"; then
    echo 'FAIL: dangling installer fixture was accepted' >&2
    exit 1
fi
grep -Fq 'DANGLING scripts/build-rootfs.sh:etc/missing.conf' "${tmp}/dangling.err" || {
    echo 'FAIL: dangling fixture did not name its missing overlay path' >&2
    cat "${tmp}/dangling.err" >&2
    exit 1
}

echo 'PASS: overlay coverage accepts complete input and rejects orphan and dangling-reference fixtures'
