#!/usr/bin/env bash
# Bracket one explicitly authorized laptop harness run with host-input checks.
# This wrapper is committed before use; do not run it without input-coord's go.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_mode="${PF_NEGATIVE_CONTROL_TESTING:-0}"
if [[ "$test_mode" == 1 ]]; then
	devices_path="${PF_INPUT_DEVICES_PATH:?test mode needs PF_INPUT_DEVICES_PATH}"
	journalctl_cmd="${PF_NEGATIVE_CONTROL_JOURNALCTL:?test mode needs PF_NEGATIVE_CONTROL_JOURNALCTL}"
	runner="${PF_NEGATIVE_CONTROL_RUNNER:?test mode needs PF_NEGATIVE_CONTROL_RUNNER}"
	poll_interval="${PF_NEGATIVE_CONTROL_POLL_INTERVAL:?test mode needs PF_NEGATIVE_CONTROL_POLL_INTERVAL}"
else
	if [[ -n "${PF_INPUT_DEVICES_PATH+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_JOURNALCTL+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_RUNNER+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_REPORTER+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_POLL_INTERVAL+x}" ]]; then
		echo "FAIL: input-harness-negative-control reason=test_override_requires_opt_in"
		exit 1
	fi
	devices_path=/proc/bus/input/devices
	journalctl_cmd=journalctl
	runner="$root/run.sh"
	poll_interval=0.1
fi
limit=50m
out=""
receipt=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--timeout) limit="${2:?--timeout needs a duration}"; shift 2 ;;
		--out) out="${2:?--out needs a directory}"; shift 2 ;;
		--receipt) receipt="${2:?--receipt needs a file}"; shift 2 ;;
		*) echo "usage: negative-control.sh [--timeout 50m] --out DIR --receipt FILE" >&2; exit 2 ;;
	esac
done
[[ -n "$out" && -n "$receipt" ]] || {
	echo "usage: negative-control.sh [--timeout 50m] --out DIR --receipt FILE" >&2
	exit 2
}
[[ -r "$devices_path" ]] || {
	echo "FAIL: input-harness-negative-control reason=input_devices_unreadable path=$devices_path"
	exit 1
}

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/input-negative-control.XXXXXX")"
child_pid=""
cleanup()
{
	if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
		set +e
		kill -TERM -- "-$child_pid" 2>/dev/null
		wait "$child_pid" 2>/dev/null
		set -e
	fi
	find "$tmp" -mindepth 1 -delete
	rmdir "$tmp"
}
trap cleanup EXIT INT TERM

snapshot_entries()
{
	awk 'BEGIN { RS=""; ORS="\n" } NF { gsub(/\n/, "\034"); print }' "$1" | sort
}

cursor_from()
{
	sed -n 's/^-- cursor: //p' "$1" | tail -n 1
}

cp "$devices_path" "$tmp/devices.before"
snapshot_entries "$tmp/devices.before" >"$tmp/entries.before"
"$journalctl_cmd" --user -n 0 --show-cursor --no-pager >"$tmp/user.cursor.raw"
"$journalctl_cmd" -n 0 --show-cursor --no-pager >"$tmp/system.cursor.raw"
user_cursor="$(cursor_from "$tmp/user.cursor.raw")"
system_cursor="$(cursor_from "$tmp/system.cursor.raw")"
[[ -n "$user_cursor" && -n "$system_cursor" ]] || {
	echo "FAIL: input-harness-negative-control reason=journal_cursor_missing"
	exit 1
}

write_receipt()
{
	local reason="$1"
	{
		printf 'result=%s\n' "$reason"
		printf 'devices_path=%s\n' "$devices_path"
		printf 'user_cursor=%s\n' "$user_cursor"
		printf 'system_cursor=%s\n' "$system_cursor"
		printf '%s\n' '--- before /proc/bus/input/devices (verbatim) ---'
		dd if="$tmp/devices.before" status=none
		printf '\n'
		printf '%s\n' '--- after /proc/bus/input/devices (verbatim) ---'
		dd if="$tmp/devices.after" status=none
		printf '\n'
		printf '%s\n' '--- user journal after cursor ---'
		dd if="$tmp/user.after" status=none
		printf '\n'
		printf '%s\n' '--- system journal after cursor ---'
		dd if="$tmp/system.after" status=none
		printf '\n'
		printf '%s\n' '--- harness log ---'
		dd if="$tmp/harness.log" status=none
		printf '\n'
		printf '%s\n' '--- functional report ---'
		dd if="$tmp/report.log" status=none
		printf '\n'
	} >"$receipt"
}

collect_after()
{
	cp "$devices_path" "$tmp/devices.after"
	"$journalctl_cmd" --user --after-cursor "$user_cursor" --no-pager -o short-iso >"$tmp/user.after"
	"$journalctl_cmd" --after-cursor "$system_cursor" --no-pager -o short-iso >"$tmp/system.after"
	: >"$tmp/report.log"
}

terminate_child()
{
	if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
		set +e
		kill -TERM -- "-$child_pid" 2>/dev/null
		wait "$child_pid" 2>/dev/null
		set -e
	fi
	child_pid=""
}

setsid timeout --signal=TERM --kill-after=5s "$limit" \
	"$runner" --out "$out" >"$tmp/harness.log" 2>&1 &
child_pid=$!
appeared=0
while kill -0 "$child_pid" 2>/dev/null; do
	set +e
	state="$(ps -o stat= -p "$child_pid" 2>/dev/null | tr -d ' ')"
	ps_rc=$?
	set -e
	[[ $ps_rc -ne 0 ]] && break
	[[ "$state" == Z* ]] && break
	cp "$devices_path" "$tmp/devices.current"
	snapshot_entries "$tmp/devices.current" >"$tmp/entries.current"
	comm -13 "$tmp/entries.before" "$tmp/entries.current" >"$tmp/entries.added"
	if [[ -s "$tmp/entries.added" ]]; then
		appeared=1
		terminate_child
		break
	fi
	sleep "$poll_interval"
done
if [[ -n "$child_pid" ]]; then
	set +e
	wait "$child_pid"
	harness_rc=$?
	set -e
	child_pid=""
else
	harness_rc=1
fi

collect_after
snapshot_entries "$tmp/devices.after" >"$tmp/entries.after"
comm -13 "$tmp/entries.before" "$tmp/entries.after" >"$tmp/entries.added.after"
if [[ $appeared -eq 1 || -s "$tmp/entries.added.after" ]]; then
	write_receipt "FAIL reason=host_input_device_appeared"
	echo "FAIL: input-harness-negative-control reason=host_input_device_appeared receipt=$receipt"
	exit 1
fi

journal_pattern='PocketForge|XINPUT: Adding extended input device|config/udev: Adding input device|libinput.*(Adding|added|device added)'
if grep -Eiq "$journal_pattern" "$tmp/user.after" "$tmp/system.after"; then
	write_receipt "FAIL reason=host_input_journal_activity"
	echo "FAIL: input-harness-negative-control reason=host_input_journal_activity receipt=$receipt"
	exit 1
fi
if [[ $harness_rc -ne 0 ]]; then
	write_receipt "FAIL reason=harness_failed rc=$harness_rc"
	echo "FAIL: input-harness-negative-control reason=harness_failed rc=$harness_rc receipt=$receipt"
	exit 1
fi
if [[ ! -s "$out/screenshots/manifest.json" ]]; then
	write_receipt "FAIL reason=screenshot_manifest_missing"
	echo "FAIL: input-harness-negative-control reason=screenshot_manifest_missing receipt=$receipt"
	exit 1
fi

set +e
if [[ "$test_mode" == 1 ]]; then
	"$PF_NEGATIVE_CONTROL_REPORTER" "$out" >"$tmp/report.log" 2>&1
else
	python3 -B "$root/report/report.py" "$out" >"$tmp/report.log" 2>&1
fi
report_rc=$?
set -e
if [[ $report_rc -ne 0 ]]; then
	write_receipt "FAIL reason=functional_checks_failed rc=$report_rc"
	echo "FAIL: input-harness-negative-control reason=functional_checks_failed rc=$report_rc receipt=$receipt"
	exit 1
fi

write_receipt "PASS"
echo "PASS: input-harness-negative-control host_devices=unchanged journals=clean functional_checks=pass receipt=$receipt"
