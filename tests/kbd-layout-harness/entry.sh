#!/bin/bash
# Container entry for the keyboard-layout end-to-end check (tsp-ihne1.6).
#
# The repo root is mounted read-only at /repo and a host scratch dir at
# /out. Resolves the keyboardLayout preference through the shipping rootfs
# generator (the same one pf-kbd-layout-env.service runs on device) against
# the container's real xkb-data, exports the rendered XKB_DEFAULT_* exactly
# as a session unit would source /run/pocketforge/kbd-layout.env, then runs
# headless gamescope with the keyboard driver as primary child.
set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/xdg}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export PATH="/harness/bin:$PATH"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.x86_64.json}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-llvmpipe}"

OUT="${OUT:-/out}"
mkdir -p "$OUT/transcripts"

cleanup() {
	if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
		if ! chown -R "$HOST_UID:$HOST_GID" "$OUT"; then
			echo "entry: chown of $OUT to $HOST_UID:$HOST_GID failed" >&2
		fi
	fi
}
trap cleanup EXIT

# The preference -> environment seam under test. PF_KBD_PREFS_FILE,
# PF_KBD_SEED_FILE and PF_KBD_ENV_FILE come from the host test; the rules
# XML is the container's real /usr/share/X11/xkb/rules/evdev.xml.
python3 /repo/rootfs-overlay/usr/lib/pocketforge/kbd-layout-env
echo "== ${PF_KBD_ENV_FILE:-/out/kbd.env} =="
cat "${PF_KBD_ENV_FILE:-/out/kbd.env}"
# shellcheck disable=SC1091
. "${PF_KBD_ENV_FILE:-/out/kbd.env}"
export XKB_DEFAULT_RULES XKB_DEFAULT_MODEL XKB_DEFAULT_LAYOUT \
	XKB_DEFAULT_VARIANT XKB_DEFAULT_OPTIONS \
	PF_KEYBOARD_LAYOUT PF_KEYBOARD_LAYOUT_SOURCE

set +e
gamescope --backend headless \
	-W "${PF_OUTPUT_WIDTH:-1280}" -H "${PF_OUTPUT_HEIGHT:-720}" -- \
	python3 /repo/tests/kbd-layout-harness/driver.py "$OUT"
rc=$?
set -e
exit $rc
