#!/bin/sh
set -eu

rootfs="${1:?usage: verify-rootfs-bluetooth.sh ROOTFS}"

require_file() {
	path="$1"
	[ -f "${rootfs}/${path}" ] || {
		echo "FATAL: rootfs Bluetooth: /${path} is missing" >&2
		exit 1
	}
}

require_file usr/libexec/pocketforge/xr829-hciattach
[ -x "${rootfs}/usr/libexec/pocketforge/xr829-hciattach" ] || {
	echo "FATAL: rootfs Bluetooth: /usr/libexec/pocketforge/xr829-hciattach is not executable" >&2
	exit 1
}
require_file etc/systemd/system/pocketforge-xr829-hciattach.service
require_file lib/firmware/fw_xr829_bt.bin

want="${rootfs}/etc/systemd/system/multi-user.target.wants/pocketforge-xr829-hciattach.service"
[ -L "$want" ] || {
	echo "FATAL: rootfs Bluetooth: pocketforge-xr829-hciattach.service is not enabled" >&2
	exit 1
}
[ "$(readlink "$want")" = /etc/systemd/system/pocketforge-xr829-hciattach.service ] || {
	echo "FATAL: rootfs Bluetooth: attach service enable link has the wrong target" >&2
	exit 1
}

echo 'rootfs-bluetooth=PASS attach=xr829-hciattach uart=/dev/ttyS1 host_stack=NOT-SHIPPED'
