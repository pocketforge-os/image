#!/usr/bin/env bash
# The open-GPU gate's strict virtual branch (tsp-mc9m.41.984.54.18): the real
# gate script runs in an unprivileged bwrap fixture view (fake virtio_gpu
# sysfs, canned probe, fake Venus ICD) covering the virtual success path, its
# negative controls (guest lavapipe, vgem node, missing capset, missing ICD,
# software GLES) and the byte-identity of the physical branch against
# BASE_REF. Cases are documented in tests/test-open-gpu-gate-virtual.py.
#
# It runs no container and no user or system manager.
#
# Usage: tests/test-open-gpu-gate-virtual.sh [--keep]
# Exit status: 0 PASS, 1 FAIL, 75 BLOCKED.
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
keep=0
args=()
for arg in "$@"; do
    case "$arg" in
        --keep) keep=1 ;;
        *) args+=("$arg") ;;
    esac
done

work="$(mktemp -d "${TMPDIR:-/tmp}/pf-open-gpu-gate-virtual.XXXXXX")"
cleanup() {
    if [ "$keep" = 1 ]; then
        echo "kept: $work"
    else
        [ ! -e "$work" ] || find "$work" -depth -delete
    fi
}
trap cleanup EXIT

python3 -B "$root/tests/test-open-gpu-gate-virtual.py" --work "$work" "${args[@]+"${args[@]}"}"
