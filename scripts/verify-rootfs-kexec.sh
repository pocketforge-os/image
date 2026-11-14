#!/bin/sh
# Fail closed unless the assembled 7.x A133 rootfs and its packaged kernel
# expose the classic kexec_load(2) path consumed by pf-kexec-sd-canary.
set -eu

rootfs="${1:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG}"
kernel_config="${2:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG}"
loader="${rootfs}/usr/sbin/kexec"

[ -d "$rootfs" ] || {
	echo "FATAL: kexec rootfs verification: rootfs is not a directory: ${rootfs}" >&2
	exit 1
}
if [ ! -f "$loader" ] || [ -L "$loader" ]; then
	echo 'FATAL: kexec rootfs verification: /usr/sbin/kexec is missing or not a regular file' >&2
	exit 1
fi
[ -x "$loader" ] || {
	echo 'FATAL: kexec rootfs verification: /usr/sbin/kexec is not executable' >&2
	exit 1
}
if [ ! -f "$kernel_config" ] || [ -L "$kernel_config" ]; then
	echo "FATAL: kexec rootfs verification: packaged kernel config is missing or not a regular file: ${kernel_config}" >&2
	exit 1
fi

for symbol in KEXEC KEXEC_CORE; do
	count=$(grep -cx "CONFIG_${symbol}=y" "$kernel_config" || true)
	[ "$count" -eq 1 ] || {
		echo "FATAL: kexec rootfs verification: packaged kernel config requires CONFIG_${symbol}=y exactly once (found ${count})" >&2
		exit 1
	}
done

echo 'rootfs-kexec=PASS loader=/usr/sbin/kexec api=kexec_load config=CONFIG_KEXEC:y,CONFIG_KEXEC_CORE:y'
