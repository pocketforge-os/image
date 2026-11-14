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
printf 'CONFIG_KEXEC_CORE=y\nCONFIG_KEXEC=y\n' >"$work/kernel.config"

"$verifier" "$work/rootfs" "$work/kernel.config" canary >/dev/null \
	|| fail 'verifier rejected a valid canary rootfs and resolved kernel config'

printf 'CONFIG_VIDEO_SUN50I_G2D_MIX=y\n# CONFIG_KEXEC is not set\n' >"$work/kernel.config"
"$verifier" "$work/rootfs" "$work/kernel.config" baseline >/dev/null \
	|| fail 'verifier rejected the valid G2D baseline config'
expect_canary_config="$work/kernel.config"

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

chmod 0644 "$work/rootfs/usr/sbin/kexec"
expect_fail non-executable '/usr/sbin/kexec is not executable' \
	"$verifier" "$work/rootfs" "$work/kernel.config"
chmod 0755 "$work/rootfs/usr/sbin/kexec"

expect_fail disabled-canary 'expected canary config, resolved baseline' \
	"$verifier" "$work/rootfs" "$expect_canary_config" canary

mv "$work/rootfs/usr/sbin/kexec" "$work/kexec.saved"
expect_fail missing '/usr/sbin/kexec is missing or not a regular file' \
	"$verifier" "$work/rootfs" "$work/kernel.config"
mv "$work/kexec.saved" "$work/rootfs/usr/sbin/kexec"

printf '# CONFIG_KEXEC is not set\nCONFIG_KEXEC_CORE=y\n' >"$work/kernel.config"
expect_fail ambiguous-baseline 'baseline config requires CONFIG_VIDEO_SUN50I_G2D_MIX=y exactly once' \
	"$verifier" "$work/rootfs" "$work/kernel.config"

printf 'CONFIG_KEXEC=y\n# CONFIG_KEXEC_CORE is not set\n' >"$work/kernel.config"
expect_fail missing-core 'canary config requires CONFIG_KEXEC_CORE=y exactly once' \
	"$verifier" "$work/rootfs" "$work/kernel.config"

printf 'CONFIG_KEXEC=y\nCONFIG_KEXEC_CORE=y\nCONFIG_VIDEO_SUN50I_G2D_MIX=y\n' >"$work/kernel.config"
expect_fail unsafe-combination 'canary config must not enable CONFIG_VIDEO_SUN50I_G2D_MIX' \
	"$verifier" "$work/rootfs" "$work/kernel.config"

# The owned build must pass the resolved config from the same kernel stage and
# invoke the verifier after all rootfs producers, before ext4 assembly.
grep -Fq 'COPY --from=kernel /out/build/config /work/kernel-config' "$dockerfile"
grep -Fq 'KERNEL_CONFIG=/work/kernel-config' "$dockerfile"
# shellcheck disable=SC2016 -- matching the literal Dockerfile expansion.
grep -Fq 'PF_KERNEL_DEFCONFIG="${PF_KERNEL_DEFCONFIG}"' "$dockerfile"
grep -Fq 'a133_kexec_canary.config)' "$dockerfile"
grep -Fq 'make a133_defconfig' "$dockerfile"
grep -Fq 'make a133_kexec_canary.config' "$dockerfile"
verify_line=$(grep -n 'scripts/verify-rootfs-kexec.sh' "$builder" | cut -d: -f1)
ext4_line=$(grep -n '^mke2fs -t ext4' "$builder" | cut -d: -f1)
if [ -z "$verify_line" ] || [ -z "$ext4_line" ] || [ "$verify_line" -ge "$ext4_line" ]; then
	fail 'rootfs verifier is not wired before ext4 assembly'
fi

echo 'rootfs-kexec-test=PASS package=kexec-tools baseline=g2d canary=kexec_load'
