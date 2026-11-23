#!/bin/bash
# a133-open-7x-gpu-resetcap-off differs from a133-open-7x-gpu only by the
# bootchain reset-capability override, so every PF_DEVICE_ID allowlist that
# admits a133-open-7x-gpu must admit it too. The canonical Gamescope
# PF_GAMESCOPE_PROFILE_CLASS case arm is exempt: it matches the class name, not
# a device id.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

while IFS= read -r hit; do
    file="${hit%%:*}"
    rest="${hit#*:}"
    lineno="${rest%%:*}"
    text="${rest#*:}"

    # The case subject is on an earlier line, so inspect a small window to skip
    # the PF_GAMESCOPE_PROFILE_CLASS arm (build-rootfs.sh ~211/~472).
    window_start=$((lineno > 2 ? lineno - 2 : 1))
    if sed -n "${window_start},${lineno}p" "${file}" | grep -q 'PF_GAMESCOPE_PROFILE_CLASS'; then
        continue
    fi
    if printf '%s\n' "${text}" | grep -q 'a133-open-7x-gpu-resetcap-off'; then
        continue
    fi
    echo "FAIL: ${file}:${lineno} has a133-open-7x-gpu but missing a133-open-7x-gpu-resetcap-off: ${text}" >&2
    fail=1
done < <(grep -rnE 'a133-open-7x-gpu(\||\))' scripts/ 2>/dev/null || true)

# Also check the Python set in gamescope_package.py
if grep -q 'a133-open-7x-gpu' scripts/gamescope_package.py; then
    if ! grep 'a133-open-7x-gpu' scripts/gamescope_package.py | grep -q 'resetcap-off'; then
        echo "FAIL: scripts/gamescope_package.py profile_enabled set missing a133-open-7x-gpu-resetcap-off" >&2
        fail=1
    fi
fi

[ "${fail}" = 0 ] && echo "PASS resetcap-off-allowlists"
exit "${fail}"