#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$root/tools/require-apt-proxy.sh"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-apt-proxy-test.XXXXXX")"
cleanup() {
    find "$work" -mindepth 1 -delete
    rmdir "$work"
}
trap cleanup EXIT INT TERM

set +e
env -u PF_APT_PROXY sh -c ". '$guard'" >"$work/missing.out" 2>&1
missing_rc=$?
set -e
[[ "$missing_rc" -eq 64 ]]
grep -qx 'input-harness-payload=REFUSED reason=missing_apt_proxy' "$work/missing.out"

set +e
PF_APT_PROXY=https://proxy.invalid sh -c ". '$guard'" >"$work/invalid.out" 2>&1
invalid_rc=$?
set -e
[[ "$invalid_rc" -eq 64 ]]
grep -qx 'input-harness-payload=REFUSED reason=invalid_apt_proxy' "$work/invalid.out"

PF_APT_PROXY=http://10.0.32.86:3142 sh -c ". '$guard'; printf '%s\n' \"\$http_proxy\"" \
    >"$work/present.out"
grep -qx 'http://10.0.32.86:3142' "$work/present.out"
echo 'apt-proxy-guard: PASS missing=red invalid=red present=green'
