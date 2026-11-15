#!/usr/bin/env bash
# The kexec canary differs from a133-open-7x-gpu only by kernel defconfig, so
# every device-id allowlist that admits a133-open-7x-gpu must admit it too.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=0
while IFS=: read -r file line text; do
    case "${text}" in
        *a133-open-7x-gpu-kexec-canary*) continue ;;
    esac
    # Allowlist alternation entries only: `a133-open-7x-gpu|` or `a133-open-7x-gpu)` within a case pattern.
    if printf '%s\n' "${text}" | grep -Eq '(^|[ |])a133-open-7x-gpu(\||\))'; then
        echo "FAIL ${file}:${line}: allowlist admits a133-open-7x-gpu but not a133-open-7x-gpu-kexec-canary: ${text}" >&2
        bad=1
    fi
done < <(grep -rnE 'a133-open-7x-gpu(\||\))' scripts rootfs-overlay 2>/dev/null || true)
[ "${bad}" = 0 ] && echo "PASS kexec-canary-allowlists"
exit "${bad}"
