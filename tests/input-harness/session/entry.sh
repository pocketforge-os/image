#!/bin/bash
# Container entrypoint: set up the runtime dirs, the mangoapp command FIFO
# and the software Vulkan ICD, then exec headless gamescope with the
# harness driver as the primary child.
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

export PF_MANGO_FIFO="${PF_MANGO_FIFO:-/run/pf-mango.fifo}"
if [ ! -p "$PF_MANGO_FIFO" ]; then
	mkfifo "$PF_MANGO_FIFO"
fi
export PATH="/harness/bin:$PATH"

export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.x86_64.json}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"
export XKB_DEFAULT_RULES="${XKB_DEFAULT_RULES:-evdev}"
export LIBINPUT_DEFAULT_SEAT="${LIBINPUT_DEFAULT_SEAT:-seat0}"

OUT="${OUT:-/out}"
mkdir -p "$OUT/transcripts" "$OUT/screenshots"

cleanup() {
	if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
		if ! chown -R "$HOST_UID:$HOST_GID" "$OUT"; then
			echo "entry: chown of $OUT to $HOST_UID:$HOST_GID failed" >&2
		fi
	fi
}
trap cleanup EXIT

set +e
gamescope --backend headless \
	-W "${PF_OUTPUT_WIDTH:-1280}" -H "${PF_OUTPUT_HEIGHT:-720}" \
	--mangoapp -- \
	python3 /harness/session/driver.py "$OUT"
rc=$?
set -e
exit $rc
