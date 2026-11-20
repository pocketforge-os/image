#!/bin/sh
# Verify the common kexec loader and the resolved 7.x A133 kernel config.
# Since kernel-sunxi-7.x#185 both deliberate modes -- the shipping
# a133_defconfig baseline and the a133_kexec_canary.config canary -- resolve
# classic kexec_load(2) (CONFIG_KEXEC + CONFIG_KEXEC_CORE) WITH G2D MIX built
# in: the MIX driver's .shutdown quiesces the mixer before machine_kexec().
# The config no longer distinguishes the modes, so the caller names one.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PF_KERNEL_KEXEC_CONFIG_LIBRARY=1
export PF_KERNEL_KEXEC_CONFIG_LIBRARY
# shellcheck source=/dev/null
. "${script_dir}/verify-kernel-kexec-config.sh"
unset PF_KERNEL_KEXEC_CONFIG_LIBRARY

rootfs="${1:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG baseline|canary}"
kernel_config="${2:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG baseline|canary}"
expected_mode="${3:?usage: verify-rootfs-kexec.sh ROOTFS KERNEL_CONFIG baseline|canary}"
loader="${rootfs}/usr/sbin/kexec"

case "$expected_mode" in
	baseline|canary) ;;
	*) echo "FATAL: kexec rootfs verification: invalid expected mode: ${expected_mode}" >&2; exit 2 ;;
esac

# Every check runs and every miss is reported in one pass (one MISSING line
# per item plus a summary), so a single CI build exposes all of them.
# Output (stderr, one record per line):
#   MISSING item=<id> detail=<text>
#   rootfs-kexec=FAIL mode=<mode> missing=<N>
missing=0
miss() {
	missing=$((missing + 1))
	echo "MISSING item=$1 detail=kexec rootfs verification: $2" >&2
}
finish() {
	if [ "$missing" -gt 0 ]; then
		echo "rootfs-kexec=FAIL mode=${expected_mode} missing=${missing}" >&2
		exit 1
	fi
}

if [ ! -d "$rootfs" ]; then
	miss rootfs "rootfs is not a directory: ${rootfs}"
	finish
fi
if [ ! -f "$loader" ] || [ -L "$loader" ]; then
	miss loader '/usr/sbin/kexec is missing or not a regular file'
elif [ ! -x "$loader" ]; then
	miss loader '/usr/sbin/kexec is not executable'
fi

if [ ! -f "$kernel_config" ] || [ -L "$kernel_config" ]; then
	miss kernel-config "packaged kernel config is missing or not a regular file: ${kernel_config}"
else
	verify_kernel_kexec_config "$kernel_config" "$expected_mode" miss
fi

finish
echo "rootfs-kexec=PASS mode=${expected_mode} loader=/usr/sbin/kexec api=kexec_load g2d=enabled"
