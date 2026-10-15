#!/bin/bash
# Synthesize udev database entries for a fake input device so that
# libinput-based consumers see a seat-tagged device without a running
# udevd. Usage: udev-shim.sh <event-node> <kind>
# Example:   udev-shim.sh /dev/input/event7 keyboard
set -euo pipefail

node="${1:?usage: udev-shim.sh <event-node> <kind>}"
kind="${2:?usage: udev-shim.sh <event-node> <kind>}"

if [ ! -e "$node" ]; then
	echo "udev-shim: $node does not exist" >&2
	exit 1
fi

hex="$(stat -Lc '%t %T' "$node")"
maj=$((16#${hex% *}))
min=$((16#${hex#* }))
dev="$maj:$min"

# Locate the input device by matching maj:min against the event node's dev
# file: /sys/class/input/inputN has no dev file, only eventN does. The
# parent inputN name is derived from the resolved event symlink. Retry
# briefly because the uinput kernel registration and the sysfs view can
# lag the device-node creation.
input_name=""
for _attempt in $(seq 10); do
	for d in /sys/class/input/event*; do
		if [ -r "$d/dev" ] && [ "$(cat "$d/dev")" = "$dev" ]; then
			input_name="$(basename "$(dirname "$(readlink -f "$d")")")"
			break 2
		fi
	done
	sleep 0.5
done
if [ -z "$input_name" ]; then
	echo "udev-shim: no input sysfs entry for $dev" >&2
	exit 1
fi

data_dir="${PF_UDEV_DATA_DIR:-/run/udev/data}"
mkdir -p "$data_dir"

{
	echo "P: /devices/virtual/input/$input_name"
	echo "E: ID_INPUT=1"
	case "$kind" in
		keyboard) echo "E: ID_INPUT_KEYBOARD=1" ;;
		mouse) echo "E: ID_INPUT_MOUSE=1" ;;
		pad)
			echo "E: ID_INPUT_JOYSTICK=1"
			echo "E: ID_INPUT_GAMEPAD=1"
			;;
		*) echo "udev-shim: unknown kind $kind" >&2; exit 2 ;;
	esac
	echo "E: ID_PATH=platform-uinput"
	echo "E: ID_SEAT=seat0"
	echo "E: TAGS=:seat:"
} > "$data_dir/c$dev"

echo "udev-shim: wrote $data_dir/c$dev for $node ($kind)"
