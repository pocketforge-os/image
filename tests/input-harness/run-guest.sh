#!/bin/bash
# Guest/DUT-only real-kernel tier. The opener remains guarded inside fake-input.
set -euo pipefail

out=
while [ $# -gt 0 ]; do
	case "$1" in
		--out) out="${2:?--out requires a directory}"; shift 2 ;;
		*) echo "FAIL: input-harness reason=invalid_argument argument=$1"; exit 2 ;;
	esac
done
test -n "$out" || { echo "FAIL: input-harness reason=missing_output"; exit 2; }

if systemd-detect-virt --container --quiet; then
	echo "FAIL: input-harness reason=unsafe_uinput_domain domain=container"
	exit 77
fi

compatible=/proc/device-tree/compatible
if [ ! -r "$compatible" ]; then
	echo "FAIL: input-harness reason=unsafe_uinput_domain domain=bare-metal"
	exit 77
fi
for token in pocketforge,tsp allwinner,sun50i-a133 allwinner,sun50i-a100; do
	tr '\0' '\n' < "$compatible" | grep -Fqx "$token" || {
		echo "FAIL: input-harness reason=unsafe_uinput_domain domain=dut-mismatch"
		exit 77
	}
done

entry=/opt/pf-input-harness/session/entry-guest.sh
test -x "$entry" || {
	echo "FAIL: input-harness reason=guest_package_missing" | tee "$out/report.txt"
	exit 1
}
test -e /dev/dri/card0 || {
	echo "FAIL: input-harness reason=guest_drm_missing" | tee "$out/report.txt"
	exit 1
}
test -e /dev/input/pf-gamepad || {
	echo "FAIL: input-harness reason=guest_decode_missing" | tee "$out/report.txt"
	exit 1
}
systemctl is-active --quiet pf-input-decode.service || {
	echo "FAIL: input-harness reason=guest_decode_inactive" | tee "$out/report.txt"
	exit 1
}

set +e
OUT="$out" "$entry" >"$out/session.txt" 2>&1
rc=$?
/opt/pf-input-harness/usr/bin/python3 -B \
	/opt/pf-input-harness/report/report.py "$out" >"$out/report.txt" 2>&1
report_rc=$?
set -e
if [ "$rc" -ne 0 ] && [ "$report_rc" -eq 0 ]; then
	echo "FAIL: input-harness reason=guest_runner_rc rc=$rc" >>"$out/report.txt"
	exit 1
fi
exit "$report_rc"
