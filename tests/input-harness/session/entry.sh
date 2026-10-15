#!/bin/bash
# Container entrypoint: set up the runtime dirs, the mangoapp command FIFO
# and the software Vulkan ICD, then exec headless gamescope with the
# harness driver as the primary child.
set -euo pipefail

export PATH="/harness/bin:$PATH"

export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export XKB_DEFAULT_RULES="${XKB_DEFAULT_RULES:-evdev}"
export LIBINPUT_DEFAULT_SEAT="${LIBINPUT_DEFAULT_SEAT:-seat0}"

OUT="${OUT:-/out}"
mkdir -p "$OUT/transcripts" "$OUT/screenshots"

run_session() {
	local session_out="$1" session_name="$2"
	export XDG_RUNTIME_DIR="/run/pf-input-harness-${session_name}"
	export PF_MANGO_FIFO="/run/pf-input-harness-${session_name}.fifo"
	mkdir -p "$XDG_RUNTIME_DIR"
	chmod 700 "$XDG_RUNTIME_DIR"
	if [ ! -p "$PF_MANGO_FIFO" ]; then
		mkfifo "$PF_MANGO_FIFO"
	fi
	mkdir -p "$session_out/transcripts" "$session_out/screenshots"
	gamescope --backend headless --expose-wayland \
		-W "${PF_OUTPUT_WIDTH:-1280}" -H "${PF_OUTPUT_HEIGHT:-720}" \
		--mangoapp -- \
		python3 /harness/session/driver.py "$session_out"
}

run_layout() {
	local layout="$1" expected="$2" session_out="$OUT/layout-scenario/$layout"
	local state_dir="/run/pf-layout-scenario/$layout"
	mkdir -p "$state_dir"
	printf '{"keyboardLayout":"%s"}\n' "$layout" >"$state_dir/prefs.json"
	PF_KBD_PREFS_FILE="$state_dir/prefs.json" \
	PF_KBD_SEED_FILE="$state_dir/absent-seed.json" \
	PF_KBD_ENV_FILE="$state_dir/kbd-layout.env" \
	PF_KBD_RULES_XML=/usr/share/X11/xkb/rules/evdev.xml \
		python3 -B /usr/lib/pocketforge/kbd-layout-env
	set -a
	# shellcheck disable=SC1090
	. "$state_dir/kbd-layout.env"
	set +a
	PF_LAYOUT_SCENARIO="$layout" PF_LAYOUT_EXPECT="$expected" \
		run_session "$session_out" "layout-$layout"
}

cleanup() {
	if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
		if ! chown -R "$HOST_UID:$HOST_GID" "$OUT"; then
			echo "entry: chown of $OUT to $HOST_UID:$HOST_GID failed" >&2
		fi
	fi
}
trap cleanup EXIT

run_session "$OUT" main
run_layout de 'zö'

# Live negative control: the German transcript must reject the U.S. result,
# and the rejection must carry a machine-readable reason= token.
set +e
wrong_output="$(python3 -B /harness/report/layout_scenario.py \
	"$OUT/layout-scenario/de/transcripts/gtk4-text.jsonl" 'y;' de-wrong)"
wrong_rc=$?
set -e
printf '%s\n' "$wrong_output"
if [ "$wrong_rc" -eq 0 ] || ! printf '%s\n' "$wrong_output" | \
	grep -q 'reason=layout_widget_text_mismatch'; then
	echo 'FAIL: layout-scenario-negative-control reason=wrong_expectation_accepted'
	exit 1
fi
echo 'PASS: layout-scenario-negative-control reason=layout_widget_text_mismatch'

# Re-render the production environment and restart the compositor, proving
# the reset rather than mutating a client-local keymap.
run_layout us 'y;'
exit 0
