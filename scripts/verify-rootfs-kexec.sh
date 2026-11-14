#!/bin/sh
# Verify the common kexec loader and the resolved 7.x A133 kernel mode.  The
# normal image must retain the G2D power-removal diagnostic with classic kexec
# off; the bounded canary mode must expose kexec_load(2) with G2D absent.
set -eu

rootfs="${1:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG [auto|baseline|canary]}"
kernel_config="${2:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG [auto|baseline|canary]}"
expected_mode="${3:-auto}"
loader="${rootfs}/usr/sbin/kexec"

case "$expected_mode" in
	auto|baseline|canary) ;;
	*) echo "FATAL: kexec rootfs verification: invalid expected mode: ${expected_mode}" >&2; exit 2 ;;
esac

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

count_enabled() {
	grep -cx "CONFIG_$1=y" "$kernel_config" || true
}

kexec_count=$(count_enabled KEXEC)
core_count=$(count_enabled KEXEC_CORE)
g2d_count=$(count_enabled VIDEO_SUN50I_G2D_MIX)

[ "$kexec_count" -le 1 ] \
	|| { echo "FATAL: kexec rootfs verification: CONFIG_KEXEC=y appears ${kexec_count} times" >&2; exit 1; }
[ "$core_count" -le 1 ] \
	|| { echo "FATAL: kexec rootfs verification: CONFIG_KEXEC_CORE=y appears ${core_count} times" >&2; exit 1; }
[ "$g2d_count" -le 1 ] \
	|| { echo "FATAL: kexec rootfs verification: CONFIG_VIDEO_SUN50I_G2D_MIX=y appears ${g2d_count} times" >&2; exit 1; }

if [ "$kexec_count" -eq 1 ]; then
	[ "$core_count" -eq 1 ] || {
		echo 'FATAL: kexec rootfs verification: canary config requires CONFIG_KEXEC_CORE=y exactly once' >&2
		exit 1
	}
	[ "$g2d_count" -eq 0 ] || {
		echo 'FATAL: kexec rootfs verification: canary config must not enable CONFIG_VIDEO_SUN50I_G2D_MIX' >&2
		exit 1
	}
	actual_mode=canary
else
	[ "$g2d_count" -eq 1 ] || {
		echo 'FATAL: kexec rootfs verification: baseline config requires CONFIG_VIDEO_SUN50I_G2D_MIX=y exactly once' >&2
		exit 1
	}
	actual_mode=baseline
fi

if [ "$expected_mode" != auto ] && [ "$actual_mode" != "$expected_mode" ]; then
	echo "FATAL: kexec rootfs verification: expected ${expected_mode} config, resolved ${actual_mode}" >&2
	exit 1
fi

if [ "$actual_mode" = canary ]; then
	echo 'rootfs-kexec=PASS mode=canary loader=/usr/sbin/kexec api=kexec_load g2d=disabled'
else
	echo 'rootfs-kexec=PASS mode=baseline loader=/usr/sbin/kexec api=unavailable g2d=enabled'
fi
