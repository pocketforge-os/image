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
require_file usr/bin/bluetoothctl
require_file usr/bin/btmgmt

for firmware in fw_xr829.bin boot_xr829.bin sdd_xr829.bin fw_xr829_bt.bin; do
	require_file "lib/firmware/${firmware}"
done

require_file usr/share/doc/xr829-hciattach/SOURCE.md
require_file usr/share/doc/xr829-hciattach/COPYING
grep -Fq 'bluez-5.54-xradio' "${rootfs}/usr/share/doc/xr829-hciattach/SOURCE.md" || {
	echo 'FATAL: rootfs Bluetooth: XR829 attach source provenance is missing' >&2
	exit 1
}

want="${rootfs}/etc/systemd/system/multi-user.target.wants/pocketforge-xr829-hciattach.service"
[ -L "$want" ] || {
	echo "FATAL: rootfs Bluetooth: pocketforge-xr829-hciattach.service is not enabled" >&2
	exit 1
}
[ "$(readlink "$want")" = /etc/systemd/system/pocketforge-xr829-hciattach.service ] || {
	echo "FATAL: rootfs Bluetooth: attach service enable link has the wrong target" >&2
	exit 1
}

echo 'rootfs-bluetooth=PASS attach=xr829-hciattach uart=/dev/ttyS1 host_tools=bluez:bluetoothctl,btmgmt hciconfig=NOT-CONTRACTED firmware=xr829-4 provenance=xr829-hciattach'
