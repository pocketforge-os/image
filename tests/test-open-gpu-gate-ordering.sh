#!/usr/bin/env bash
# The open-GPU gate waits for its own render node (bounded, named failure), never
# for systemd-udev-settle. The logic and its phases are documented in
# tests/test-open-gpu-gate-ordering.py (bd tsp-3rd3.18).
#
# It uses only unprivileged tools: `systemd --test`, which executes nothing, and
# bwrap views with a read-only root. It runs no container and no user or system
# manager.
#
# Usage: tests/test-open-gpu-gate-ordering.sh [--ref GIT_REF] [--keep]
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

work="$(mktemp -d "${TMPDIR:-/tmp}/pf-open-gpu-gate-ordering.XXXXXX")"
cleanup() {
    if [ "$keep" = 1 ]; then
        echo "kept: $work"
    else
        [ ! -e "$work" ] || find "$work" -depth -delete
    fi
}
trap cleanup EXIT

python3 -B "$root/tests/test-open-gpu-gate-ordering.py" --work "$work" "${args[@]+"${args[@]}"}"
