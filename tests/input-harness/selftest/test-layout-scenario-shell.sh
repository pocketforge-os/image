#!/usr/bin/env bash
# Execute the entrypoint's shell orchestration without gamescope or devices.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../" && pwd)"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/layout-scenario-shell.XXXXXX")"
cleanup_test() {
	find "$tmp" -mindepth 1 -delete
	rmdir "$tmp"
}
trap cleanup_test EXIT

generator="$tmp/kbd-layout-env"
reporter="$tmp/layout-scenario.py"
trace="$tmp/trace"

cat >"$generator" <<'PY'
#!/usr/bin/env python3
import json
import os

with open(os.environ["PF_KBD_PREFS_FILE"], encoding="utf-8") as source:
    layout = json.load(source)["keyboardLayout"]
with open(os.environ["PF_KBD_ENV_FILE"], "w", encoding="utf-8") as output:
    output.write(f'XKB_DEFAULT_LAYOUT="{layout}"\n')
    output.write('XKB_DEFAULT_VARIANT=""\n')
    output.write(f'PF_KEYBOARD_LAYOUT="{layout}"\n')
PY
chmod +x "$generator"

cat >"$reporter" <<'PY'
#!/usr/bin/env python3
import sys

print(
    f"FAIL: layout-scenario label={sys.argv[3]} "
    "reason=layout_widget_text_mismatch expected='y;' actual='zö'"
)
raise SystemExit(1)
PY
chmod +x "$reporter"

export OUT="$tmp/out"
export PF_INPUT_HARNESS_ENTRY_SOURCE_ONLY=1
export PF_KBD_LAYOUT_ENV_BIN="$generator"
export PF_LAYOUT_SCENARIO_REPORT="$reporter"
export PF_LAYOUT_STATE_ROOT="$tmp/state"
# shellcheck source=tests/input-harness/session/entry.sh
. "$root/tests/input-harness/session/entry.sh"

run_session() {
	local session_out="$1" session_name="$2"
	mkdir -p "$session_out/transcripts"
	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$session_name" "${PF_LAYOUT_SCENARIO:-}" "${PF_LAYOUT_EXPECT:-}" \
		"${XKB_DEFAULT_LAYOUT:-}" "${PF_KEYBOARD_LAYOUT:-}" >>"$trace"
	printf '%s\n' '{"event":"widget_text","text":"zö"}' \
		>"$session_out/transcripts/gtk4-text.jsonl"
}

run_layout_sequence >"$tmp/output"

expected_trace="$tmp/expected-trace"
printf '%s\n' \
	$'layout-de\tde\tzö\tde\tde' \
	$'layout-us\tus\ty;\tus\tus' >"$expected_trace"
cmp "$expected_trace" "$trace"
grep -q '^FAIL: layout-scenario label=de-wrong reason=layout_widget_text_mismatch ' \
	"$tmp/output"
grep -q '^PASS: layout-scenario-negative-control reason=layout_widget_text_mismatch$' \
	"$tmp/output"

echo 'layout-scenario-shell: PASS sequence=de,negative,us devices=none'
