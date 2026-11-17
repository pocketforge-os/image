#!/usr/bin/env bash
# sf_v3_kernel_kexec_load must not false-negative on a large config.gz under
# pipefail (grep -q exits early, gunzip dies of SIGPIPE). Runs under the
# harness bash and under busybox sh, the shell the initrd uses.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$root/boards/tsp/initrd/self-flash-v3.sh"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-kexec-cfg.XXXXXX")"
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# >= 200 KB raw, mostly incompressible-ish unique lines.
big_tail() { i=0; while [ "$i" -lt 8000 ]; do printf '# CONFIG_PF_FILLER_%08d is not set\n' "$i"; i=$((i+1)); done; }
{ printf 'CONFIG_KEXEC=y\n'; big_tail; } | gzip -c >"$tmp/big-yes.gz"
{ printf '# CONFIG_KEXEC is not set\n'; big_tail; } | gzip -c >"$tmp/big-no.gz"
{ printf 'CONFIG_KEXEC=y\n'; } | gzip -c >"$tmp/small-yes.gz"
[ "$(gunzip -c "$tmp/big-yes.gz" | wc -c)" -ge 200000 ] || fail 'fixture too small'
: >"$tmp/sysfs"; printf '0\n' >"$tmp/disabled"

driver="$tmp/driver.sh"
cat >"$driver" <<'DRV'
. "$1"
SF_V3_KEXEC_LOADED_SYSFS="$2/sysfs"; SF_V3_KEXEC_LOAD_DISABLED="$2/disabled"
SF_V3_KERNEL_CONFIG_GZ="$2/$3"
set -o pipefail
rc=0; sf_v3_kernel_kexec_load || rc=$?
printf '%s %s\n' "$rc" "$SF_V3_KEXEC_KERNEL_REASON"
DRV

shells=(bash)
if [ -x /usr/bin/busybox ]; then shells+=("/usr/bin/busybox sh"); fi
for sh in "${shells[@]}"; do
    check() { # name file want
        got="$($sh "$driver" "$engine" "$tmp" "$2" 2>&1 | tail -n 1)"
        [ "$got" = "$3" ] || fail "[$sh] $1: got '$got' want '$3'"
    }
    check big-with-kexec big-yes.gz '0 available'
    check big-without-kexec big-no.gz '1 kexec_load_not_configured'
    check small-with-kexec small-yes.gz '0 available'
    check no-config absent.gz '0 available'
done
echo "PASS test-self-flash-v3-kexec-config-pipefail (${#shells[@]} shells)"
