#!/bin/sh
# Verify the common kexec loader and the resolved 7.x A133 kernel config.
# Since kernel-sunxi-7.x#185 both deliberate modes -- the shipping
# a133_defconfig baseline and the a133_kexec_canary.config canary -- resolve
# classic kexec_load(2) (CONFIG_KEXEC + CONFIG_KEXEC_CORE) WITH G2D MIX built
# in: the MIX driver's .shutdown quiesces the mixer before machine_kexec().
# The config no longer distinguishes the modes, so the caller names one.
set -eu

rootfs="${1:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG baseline|canary}"
kernel_config="${2:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG baseline|canary}"
expected_mode="${3:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG baseline|canary}"
loader="${rootfs}/usr/sbin/kexec"

case "$expected_mode" in
	baseline|canary) ;;
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

for symbol in KEXEC KEXEC_CORE VIDEO_SUN50I_G2D_MIX; do
	[ "$(count_enabled "$symbol")" -eq 1 ] || {
		echo "FATAL: kexec rootfs verification: ${expected_mode} config requires CONFIG_${symbol}=y exactly once" >&2
		exit 1
	}
done

echo "rootfs-kexec=PASS mode=${expected_mode} loader=/usr/sbin/kexec api=kexec_load g2d=enabled"
