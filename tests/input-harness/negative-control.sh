#!/usr/bin/env bash
# Bracket one explicitly authorized host-side harness run with input checks.
# This wrapper is committed before use; do not run it without input-coord's go.
set -Eeuo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_mode="${PF_NEGATIVE_CONTROL_TESTING:-0}"
if [[ "$test_mode" == 1 ]]; then
	devices_path="${PF_INPUT_DEVICES_PATH:?test mode needs PF_INPUT_DEVICES_PATH}"
	journalctl_cmd="${PF_NEGATIVE_CONTROL_JOURNALCTL:?test mode needs PF_NEGATIVE_CONTROL_JOURNALCTL}"
	runner="${PF_NEGATIVE_CONTROL_RUNNER:?test mode needs PF_NEGATIVE_CONTROL_RUNNER}"
	reporter_path="${PF_NEGATIVE_CONTROL_REPORTER:?test mode needs PF_NEGATIVE_CONTROL_REPORTER}"
	poll_interval="${PF_NEGATIVE_CONTROL_POLL_INTERVAL:?test mode needs PF_NEGATIVE_CONTROL_POLL_INTERVAL}"
else
	if [[ -n "${PF_INPUT_DEVICES_PATH+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_JOURNALCTL+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_RUNNER+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_REPORTER+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_POLL_INTERVAL+x}" ||
	      -n "${PF_NEGATIVE_CONTROL_TEST_INTERNAL_ERROR_AFTER_POLLS+x}" ]]; then
		echo "FAIL: input-harness-negative-control reason=test_override_requires_opt_in"
		exit 1
	fi
	devices_path=/proc/bus/input/devices
	journalctl_cmd="$(command -v journalctl)"
	runner="$root/run.sh"
	reporter_path="$root/report/report.py"
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
		--runner)
			[[ "$test_mode" == 0 ]] || {
				echo "FAIL: input-harness-negative-control reason=runner_option_in_test_mode"
				exit 2
			}
			runner="${2:?--runner needs an executable}"; shift 2 ;;
		*) echo "usage: negative-control.sh [--timeout 50m] [--runner PATH] --out DIR --receipt FILE" >&2; exit 2 ;;
	esac
done
[[ -n "$out" && -n "$receipt" ]] || {
	echo "usage: negative-control.sh [--timeout 50m] [--runner PATH] --out DIR --receipt FILE" >&2
	exit 2
}
[[ "$runner" = /* && -f "$runner" && -x "$runner" && ! -L "$runner" ]] || {
	echo "FAIL: input-harness-negative-control reason=invalid_runner path=$runner"
	exit 2
}

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/input-negative-control.XXXXXX")"
evidence="${receipt}.evidence"
mkdir -m 0700 "$evidence"
child_pid=""
final_reason=""
final_rc=0
announced=0
poll_count=0
user_cursor=""
system_cursor=""
hazard_pattern_pocketforge_fake='PocketForge Fake'
hazard_pattern_xinput_xf86='(XINPUT|xf86).*(Adding( extended)? input device)'
hazard_pattern_desktop_input='(libinput|gnome|mutter).*(input device|Adding device)'
hazard_pattern_kernel_input='kernel.*input: '
user_pocketforge_info_count=0
user_hazard_pocketforge_fake_count=0
user_hazard_xinput_xf86_count=0
user_hazard_desktop_input_count=0
user_hazard_kernel_input_count=0
user_input_hazard_count=0
system_pocketforge_info_count=0
system_hazard_pocketforge_fake_count=0
system_hazard_xinput_xf86_count=0
system_hazard_desktop_input_count=0
system_hazard_kernel_input_count=0
system_input_hazard_count=0
journal_collection="not_attempted"

for file in devices.after user.after system.after harness.log report.log; do
	: >"$tmp/$file"
done

cursor_from()
{
	sed -n 's/^-- cursor: //p' "$1" | tail -n 1
}

snapshot_entries()
{
	awk 'BEGIN { RS=""; ORS="\n" } NF { gsub(/\n/, "\034"); print }' "$1" | sort
}

terminate_child()
{
	if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
		kill -TERM -- "-$child_pid" 2>/dev/null || :
		wait "$child_pid" 2>/dev/null || :
	fi
	child_pid=""
	return 0
}

count_pattern()
{
	local pattern="$1" file="$2"
	awk -v pattern="$pattern" 'BEGIN { IGNORECASE=1 } $0 ~ pattern { count++ } END { print count + 0 }' "$file"
}

count_generic_pocketforge()
{
	local file="$1"
	awk 'BEGIN { IGNORECASE=1 } /PocketForge/ && !/PocketForge Fake/ { count++ } END { print count + 0 }' "$file"
}

collect_after()
{
	local ok=0
	if ! cat "$devices_path" >"$tmp/devices.after"; then
		ok=1
	fi
	if [[ -n "$user_cursor" ]]; then
		if ! "$journalctl_cmd" --user --after-cursor "$user_cursor" --no-pager -o short-iso >"$tmp/user.after"; then
			ok=1
		fi
	else
		ok=1
	fi
	if [[ -n "$system_cursor" ]]; then
		if ! "$journalctl_cmd" --after-cursor "$system_cursor" --no-pager -o short-iso >"$tmp/system.after"; then
			ok=1
		fi
	else
		ok=1
	fi
	user_pocketforge_info_count="$(count_generic_pocketforge "$tmp/user.after")"
	user_hazard_pocketforge_fake_count="$(count_pattern "$hazard_pattern_pocketforge_fake" "$tmp/user.after")"
	user_hazard_xinput_xf86_count="$(count_pattern "$hazard_pattern_xinput_xf86" "$tmp/user.after")"
	user_hazard_desktop_input_count="$(count_pattern "$hazard_pattern_desktop_input" "$tmp/user.after")"
	user_hazard_kernel_input_count="$(count_pattern "$hazard_pattern_kernel_input" "$tmp/user.after")"
	user_input_hazard_count=$((user_hazard_pocketforge_fake_count + user_hazard_xinput_xf86_count + user_hazard_desktop_input_count + user_hazard_kernel_input_count))
	system_pocketforge_info_count="$(count_generic_pocketforge "$tmp/system.after")"
	system_hazard_pocketforge_fake_count="$(count_pattern "$hazard_pattern_pocketforge_fake" "$tmp/system.after")"
	system_hazard_xinput_xf86_count="$(count_pattern "$hazard_pattern_xinput_xf86" "$tmp/system.after")"
	system_hazard_desktop_input_count="$(count_pattern "$hazard_pattern_desktop_input" "$tmp/system.after")"
	system_hazard_kernel_input_count="$(count_pattern "$hazard_pattern_kernel_input" "$tmp/system.after")"
	system_input_hazard_count=$((system_hazard_pocketforge_fake_count + system_hazard_xinput_xf86_count + system_hazard_desktop_input_count + system_hazard_kernel_input_count))
	if [[ $ok -eq 0 ]]; then
		journal_collection=complete
	else
		journal_collection=failed
	fi
	return "$ok"
}

# Called from the EXIT trap; shellcheck does not resolve the quoted trap handler.
# shellcheck disable=SC2317
write_receipt()
{
	local result=FAIL draft="$tmp/receipt"
	[[ "$final_reason" == pass ]] && result=PASS
	{
		printf 'result=%s\n' "$result"
		printf 'rc=%s\n' "$final_rc"
		printf 'reason=%s\n' "$final_reason"
		printf 'poll_count=%s\n' "$poll_count"
		printf 'test_mode=%s\n' "$test_mode"
		printf 'devices_path=%s\n' "$devices_path"
		printf 'journalctl_path=%s\n' "$journalctl_cmd"
		printf 'runner_path=%s\n' "$runner"
		printf 'reporter_path=%s\n' "$reporter_path"
		printf 'out_path=%s\n' "$out"
		printf 'receipt_path=%s\n' "$receipt"
		printf 'evidence_path=%s\n' "$evidence"
		printf 'user_cursor=%s\n' "$user_cursor"
		printf 'system_cursor=%s\n' "$system_cursor"
		printf 'journal_collection=%s\n' "$journal_collection"
		printf 'journal_hazard_pattern_pocketforge_fake=%s\n' "$hazard_pattern_pocketforge_fake"
		printf 'journal_hazard_pattern_xinput_xf86=%s\n' "$hazard_pattern_xinput_xf86"
		printf 'journal_hazard_pattern_desktop_input=%s\n' "$hazard_pattern_desktop_input"
		printf 'journal_hazard_pattern_kernel_input=%s\n' "$hazard_pattern_kernel_input"
		printf 'user_pocketforge_info_count=%s\n' "$user_pocketforge_info_count"
		printf 'user_hazard_pocketforge_fake_count=%s\n' "$user_hazard_pocketforge_fake_count"
		printf 'user_hazard_xinput_xf86_count=%s\n' "$user_hazard_xinput_xf86_count"
		printf 'user_hazard_desktop_input_count=%s\n' "$user_hazard_desktop_input_count"
		printf 'user_hazard_kernel_input_count=%s\n' "$user_hazard_kernel_input_count"
		printf 'user_input_hazard_count=%s\n' "$user_input_hazard_count"
		printf 'system_pocketforge_info_count=%s\n' "$system_pocketforge_info_count"
		printf 'system_hazard_pocketforge_fake_count=%s\n' "$system_hazard_pocketforge_fake_count"
		printf 'system_hazard_xinput_xf86_count=%s\n' "$system_hazard_xinput_xf86_count"
		printf 'system_hazard_desktop_input_count=%s\n' "$system_hazard_desktop_input_count"
		printf 'system_hazard_kernel_input_count=%s\n' "$system_hazard_kernel_input_count"
		printf 'system_input_hazard_count=%s\n' "$system_input_hazard_count"
		printf '%s\n' '--- before /proc/bus/input/devices (verbatim) ---'
		[[ -f "$evidence/devices.before" ]] && dd if="$evidence/devices.before" status=none
		printf '\n%s\n' '--- after /proc/bus/input/devices (verbatim) ---'
		dd if="$tmp/devices.after" status=none
		printf '\n%s\n' '--- user journal after cursor ---'
		dd if="$tmp/user.after" status=none
		printf '\n%s\n' '--- system journal after cursor ---'
		dd if="$tmp/system.after" status=none
		printf '\n%s\n' '--- harness log ---'
		dd if="$tmp/harness.log" status=none
		printf '\n%s\n' '--- functional report ---'
		dd if="$tmp/report.log" status=none
		printf '\n'
	} >"$draft"
	mv "$draft" "$receipt"
}

# shellcheck disable=SC2317
on_exit()
{
	local incoming_rc="$1" collection_rc=0
	trap - EXIT INT TERM
	set +e
	terminate_child
	if [[ -z "$final_reason" ]]; then
		final_reason=wrapper_internal_error
		final_rc="$incoming_rc"
		[[ $final_rc -ne 0 ]] || final_rc=70
	fi
	collect_after
	collection_rc=$?
	if [[ $collection_rc -ne 0 && "$final_reason" == pass ]]; then
		final_reason=wrapper_internal_error
		final_rc=70
	fi
	write_receipt
	local receipt_rc=$?
	if [[ $announced -eq 0 ]]; then
		echo "FAIL: input-harness-negative-control reason=$final_reason rc=$final_rc receipt=$receipt"
	fi
	find "$tmp" -mindepth 1 -delete
	rmdir "$tmp"
	if [[ $receipt_rc -ne 0 ]]; then
		echo "FAIL: input-harness-negative-control reason=wrapper_internal_error detail=receipt_write_failed" >&2
		exit 70
	fi
	exit "$final_rc"
}

# shellcheck disable=SC2317
on_signal()
{
	final_reason=wrapper_internal_error
	final_rc="$1"
	exit "$final_rc"
}

trap 'on_exit $?' EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

finish()
{
	final_reason="$1"
	final_rc="$2"
	announced=1
	if [[ "$final_reason" == pass ]]; then
		echo "PASS: input-harness-negative-control host_devices=unchanged journals=clean functional_checks=pass receipt=$receipt"
	else
		echo "FAIL: input-harness-negative-control reason=$final_reason rc=$final_rc receipt=$receipt"
	fi
	exit "$final_rc"
}

[[ -r "$devices_path" ]] || finish input_devices_unreadable 1
cat "$devices_path" >"$evidence/devices.before"
snapshot_entries "$evidence/devices.before" >"$tmp/entries.before"
"$journalctl_cmd" --user -n 0 --show-cursor --no-pager >"$evidence/user.cursor.raw"
"$journalctl_cmd" -n 0 --show-cursor --no-pager >"$evidence/system.cursor.raw"
user_cursor="$(cursor_from "$evidence/user.cursor.raw")"
system_cursor="$(cursor_from "$evidence/system.cursor.raw")"
[[ -n "$user_cursor" && -n "$system_cursor" ]] || finish journal_cursor_missing 1

setsid timeout --signal=TERM --kill-after=5s "$limit" \
	"$runner" --out "$out" >"$tmp/harness.log" 2>&1 &
child_pid=$!
appeared=0
: >"$tmp/devices.current"
while kill -0 "$child_pid" 2>/dev/null; do
	set +e
	state="$(ps -o stat= -p "$child_pid" 2>/dev/null | tr -d ' ')"
	ps_rc=$?
	set -e
	[[ $ps_rc -ne 0 ]] && break
	[[ "$state" == Z* ]] && break
	cat "$devices_path" >"$tmp/devices.current"
	poll_count=$((poll_count + 1))
	if [[ "$test_mode" == 1 && -n "${PF_NEGATIVE_CONTROL_TEST_INTERNAL_ERROR_AFTER_POLLS:-}" &&
	      "$poll_count" -ge "$PF_NEGATIVE_CONTROL_TEST_INTERNAL_ERROR_AFTER_POLLS" ]]; then
		final_reason=wrapper_internal_error
		final_rc=70
		exit "$final_rc"
	fi
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

if ! collect_after; then
	finish wrapper_internal_error 70
fi
snapshot_entries "$tmp/devices.after" >"$tmp/entries.after"
comm -13 "$tmp/entries.before" "$tmp/entries.after" >"$tmp/entries.added.after"
if [[ $appeared -eq 1 || -s "$tmp/entries.added.after" ]]; then
	finish host_input_device_appeared 1
fi
if (( user_input_hazard_count + system_input_hazard_count > 0 )); then
	finish host_input_journal_activity 1
fi
if [[ $harness_rc -eq 124 ]]; then
	finish harness_timeout 124
fi
if [[ $harness_rc -ne 0 ]]; then
	finish harness_failed "$harness_rc"
fi
if [[ ! -s "$out/screenshots/manifest.json" ]]; then
	finish screenshot_manifest_missing 1
fi

set +e
if [[ "$test_mode" == 1 ]]; then
	"$reporter_path" "$out" >"$tmp/report.log" 2>&1
else
	python3 -B "$reporter_path" "$out" >"$tmp/report.log" 2>&1
fi
report_rc=$?
set -e
if [[ $report_rc -ne 0 ]]; then
	finish functional_checks_failed "$report_rc"
fi

finish pass 0
