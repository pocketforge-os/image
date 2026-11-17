#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages="${root}/rootfs-packages.txt"
verifier="${root}/scripts/verify-rootfs-kexec.sh"
builder="${root}/scripts/build-rootfs.sh"
dockerfile="${root}/build/Dockerfile.pf"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/rootfs-kexec.XXXXXX")"

cleanup() {
	find "$work" -mindepth 1 -delete
	rmdir "$work"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

package_lines() {
	grep -v '^\s*#' "$packages" | grep -v '^\s*$'
}

count=$(package_lines | grep -cx 'kexec-tools' || true)
[ "$count" = 1 ] || fail "rootfs package list requires kexec-tools exactly once (found ${count})"
mapfile -t package_array < <(package_lines)
for index in "${!package_array[@]}"; do
	if [ "${package_array[$index]}" = kexec-tools ]; then
		[ "$index" -gt 0 ] || fail 'kexec-tools has no preceding package'
		[ "$index" -lt "$(( ${#package_array[@]} - 1 ))" ] \
			|| fail 'kexec-tools has no following package'
		[ "${package_array[$((index - 1))]}" = iw ] \
			|| fail 'kexec-tools is not sorted after iw'
		[ "${package_array[$((index + 1))]}" = kmod ] \
			|| fail 'kexec-tools is not sorted before kmod'
	fi
done

mkdir -p "$work/rootfs/usr/sbin"
printf '#!/bin/sh\nexit 0\n' >"$work/rootfs/usr/sbin/kexec"
chmod 0755 "$work/rootfs/usr/sbin/kexec"
# kernel-sunxi-7.x#185 contract: a133_defconfig and the canary fragment both
# resolve classic kexec_load(2) WITH G2D MIX built in (its .shutdown quiesces
# the mixer before machine_kexec()).  Both deliberate modes share that config.
write_valid_config() {
	printf 'CONFIG_KEXEC_CORE=y\nCONFIG_KEXEC=y\nCONFIG_VIDEO_SUN50I_G2D_MIX=y\n' >"$work/kernel.config"
}
write_valid_config
for mode in baseline canary; do
	output=$("$verifier" "$work/rootfs" "$work/kernel.config" "$mode") \
		|| fail "verifier rejected the valid kexec+G2D MIX ${mode} config"
	[ "$output" = "rootfs-kexec=PASS mode=${mode} loader=/usr/sbin/kexec api=kexec_load g2d=enabled" ] \
		|| fail "${mode}: unexpected verifier output: ${output}"
done

expect_fail() {
	local label=$1 expected=$2
	shift 2
	local output rc

	set +e
	output=$("$@" 2>&1)
	rc=$?
	set -e
	[ "$rc" -ne 0 ] || fail "${label}: negative control unexpectedly passed"
	grep -Fq "$expected" <<<"$output" \
		|| fail "${label}: expected '${expected}', got: ${output}"
}

# The resolved config no longer distinguishes the modes, so the caller must
# name one; an implicit/auto mode is refused.
expect_fail implicit-mode 'usage: verify-rootfs-kexec.sh' \
	"$verifier" "$work/rootfs" "$work/kernel.config"
expect_fail auto-mode 'invalid expected mode: auto' \
	"$verifier" "$work/rootfs" "$work/kernel.config" auto

chmod 0644 "$work/rootfs/usr/sbin/kexec"
expect_fail non-executable '/usr/sbin/kexec is not executable' \
	"$verifier" "$work/rootfs" "$work/kernel.config" baseline
chmod 0755 "$work/rootfs/usr/sbin/kexec"

mv "$work/rootfs/usr/sbin/kexec" "$work/kexec.saved"
expect_fail missing '/usr/sbin/kexec is missing or not a regular file' \
	"$verifier" "$work/rootfs" "$work/kernel.config" canary
mv "$work/kexec.saved" "$work/rootfs/usr/sbin/kexec"

expect_fail missing-config 'packaged kernel config is missing' \
	"$verifier" "$work/rootfs" "$work/absent.config" baseline

for mode in baseline canary; do
	# Retired pre-#185 baseline (G2D MIX on, classic kexec off) now fails.
	printf 'CONFIG_VIDEO_SUN50I_G2D_MIX=y\n# CONFIG_KEXEC is not set\n' >"$work/kernel.config"
	expect_fail "${mode}-kexec-off" "${mode} config requires CONFIG_KEXEC=y exactly once" \
		"$verifier" "$work/rootfs" "$work/kernel.config" "$mode"

	# Retired pre-#185 canary (kexec on, G2D MIX traded away) now fails.
	printf 'CONFIG_KEXEC_CORE=y\nCONFIG_KEXEC=y\n# CONFIG_VIDEO_SUN50I_G2D_MIX is not set\n' >"$work/kernel.config"
	expect_fail "${mode}-g2d-missing" "${mode} config requires CONFIG_VIDEO_SUN50I_G2D_MIX=y exactly once" \
		"$verifier" "$work/rootfs" "$work/kernel.config" "$mode"

	printf 'CONFIG_KEXEC=y\n# CONFIG_KEXEC_CORE is not set\nCONFIG_VIDEO_SUN50I_G2D_MIX=y\n' >"$work/kernel.config"
	expect_fail "${mode}-missing-core" "${mode} config requires CONFIG_KEXEC_CORE=y exactly once" \
		"$verifier" "$work/rootfs" "$work/kernel.config" "$mode"

	write_valid_config
	echo 'CONFIG_VIDEO_SUN50I_G2D_MIX=y' >>"$work/kernel.config"
	expect_fail "${mode}-g2d-duplicated" 'CONFIG_VIDEO_SUN50I_G2D_MIX=y appears 2 times' \
		"$verifier" "$work/rootfs" "$work/kernel.config" "$mode"

	write_valid_config
	echo 'CONFIG_KEXEC=y' >>"$work/kernel.config"
	expect_fail "${mode}-kexec-duplicated" 'CONFIG_KEXEC=y appears 2 times' \
		"$verifier" "$work/rootfs" "$work/kernel.config" "$mode"

	write_valid_config
	echo 'CONFIG_KEXEC_CORE=y' >>"$work/kernel.config"
	expect_fail "${mode}-core-duplicated" 'CONFIG_KEXEC_CORE=y appears 2 times' \
		"$verifier" "$work/rootfs" "$work/kernel.config" "$mode"
done

# Optional: a real resolved .config (e.g. from kernel b0d35624 a133_defconfig)
# must pass both modes.
if [ -n "${PF_ROOTFS_KEXEC_REAL_CONFIG:-}" ]; then
	for mode in baseline canary; do
		"$verifier" "$work/rootfs" "$PF_ROOTFS_KEXEC_REAL_CONFIG" "$mode" \
			|| fail "verifier rejected real resolved config ${PF_ROOTFS_KEXEC_REAL_CONFIG} (${mode})"
	done
fi

# The owned build must pass the resolved config from the same kernel stage and
# invoke the verifier after all rootfs producers, before ext4 assembly.
grep -Fq 'COPY --from=kernel /out/build/config /work/kernel-config' "$dockerfile"
grep -Fq 'KERNEL_CONFIG=/work/kernel-config' "$dockerfile"
# Match the literal Dockerfile expansion rather than expanding it in this test.
# shellcheck disable=SC2016
grep -Fq 'PF_KERNEL_DEFCONFIG="${PF_KERNEL_DEFCONFIG}"' "$dockerfile"
grep -Fq 'a133_kexec_canary.config)' "$dockerfile"
grep -Fq 'make a133_defconfig' "$dockerfile"
grep -Fq 'make a133_kexec_canary.config' "$dockerfile"
verify_line=$(grep -n 'scripts/verify-rootfs-kexec.sh' "$builder" | cut -d: -f1)
ext4_line=$(grep -n '^mke2fs -t ext4' "$builder" | cut -d: -f1)
if [ -z "$verify_line" ] || [ -z "$ext4_line" ] || [ "$verify_line" -ge "$ext4_line" ]; then
	fail 'rootfs verifier is not wired before ext4 assembly'
fi
grep -Fq 'a133_kexec_canary.config) kexec_mode=canary' "$builder" \
	|| fail 'rootfs builder does not map the canary fragment to canary verification'
grep -Fq 'a133_defconfig) kexec_mode=baseline' "$builder" \
	|| fail 'rootfs builder does not map the shipping defconfig to baseline verification'
# Match the literal shell condition in the builder; expansion here would test
# this test process's environment instead of the source contract.
# shellcheck disable=SC2016
if sed -n '/if \[ "${PF_KERNEL_REPO}" = kernel-sunxi-7.x \]/,/^fi$/p' "$builder" \
	| grep -Fq 'kexec_mode=auto'; then
	fail 'rootfs builder permits an ambiguous A133 7.x verification mode'
fi

echo 'rootfs-kexec-test=PASS package=kexec-tools baseline=kexec_load+g2d canary=kexec_load+g2d'
