#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="${root}/scripts/verify-kernel-kexec-config.sh"
rootfs_verifier="${root}/scripts/verify-rootfs-kexec.sh"
dockerfile="${root}/build/Dockerfile.pf"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/kernel-stage-kexec.XXXXXX")"

cleanup() {
	find "$work" -mindepth 1 -delete
	rmdir "$work"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[ -x "$verifier" ] || fail 'kernel-stage kexec config verifier is missing or not executable'

write_valid_config() {
	printf 'CONFIG_KEXEC_CORE=y\nCONFIG_KEXEC=y\nCONFIG_VIDEO_SUN50I_G2D_MIX=y\n' \
		>"$work/$1"
}

expect_fail() {
	local label=$1 mode=$2 missing_symbol=$3
	local config="$work/${label}.config" output rc

	write_valid_config "${label}.config"
	sed -i "s/^CONFIG_${missing_symbol}=y$/# CONFIG_${missing_symbol} is not set/" "$config"
	set +e
	output=$("$verifier" "$config" "$mode" 2>&1)
	rc=$?
	set -e
	[ "$rc" -ne 0 ] || fail "${label}: contradictory fixture unexpectedly passed"
	grep -Fq "${mode} config requires CONFIG_${missing_symbol}=y exactly once" <<<"$output" \
		|| fail "${label}: missing CONFIG_${missing_symbol} reason: ${output}"
}

# Four baseline fixtures preserve the two observed failure classes (two runs
# apiece).  The two historical canary runs exposed the now-retired policy that
# rejected G2D; post-kernel#185, canary requires the same three symbols as the
# baseline, so its negative fixtures enforce both sides of that corrected
# contract while the valid-canary fixture below prevents the old rejection.
expect_fail baseline-g2d-run-44081756591 baseline VIDEO_SUN50I_G2D_MIX
expect_fail baseline-g2d-run-44081755798 baseline VIDEO_SUN50I_G2D_MIX
expect_fail baseline-kexec-run-44075712210 baseline KEXEC
expect_fail baseline-kexec-run-44075703556 baseline KEXEC
expect_fail canary-kexec-disabled canary KEXEC
expect_fail canary-g2d-disabled canary VIDEO_SUN50I_G2D_MIX

for mode in baseline canary; do
	write_valid_config "valid-${mode}.config"
	"$verifier" "$work/valid-${mode}.config" "$mode" >/dev/null \
		|| fail "valid ${mode} config rejected"
done

# The late rootfs gate must consume the same symbol checker, preserving one
# policy implementation while retaining its independent loader/package check.
grep -Fq 'verify-kernel-kexec-config.sh' "$rootfs_verifier" \
	|| fail 'rootfs verifier does not share the kernel config checker'

# Only the checker is added as a kernel-stage image-repo input.  It must run
# after defconfig/fragment resolution and before any compile work begins.
grep -Fq 'COPY --chmod=0555 --from=image-src scripts/verify-kernel-kexec-config.sh /usr/local/bin/verify-kernel-kexec-config' "$dockerfile" \
	|| fail 'kernel stage does not copy only the config checker'
grep -Fq 'a133_defconfig) kexec_mode=baseline' "$dockerfile" \
	|| fail 'kernel stage does not map a133_defconfig to baseline mode'
grep -Fq 'a133_kexec_canary.config) kexec_mode=canary' "$dockerfile" \
	|| fail 'kernel stage does not map the canary fragment to canary mode'

verify_line=$(grep -n '/usr/local/bin/verify-kernel-kexec-config \.config' "$dockerfile" | cut -d: -f1)
guard_line=$(grep -n '^# --- VERMAGIC / REPRODUCIBILITY GUARDS' "$dockerfile" | cut -d: -f1)
build_line=$(grep -n 'make -j.*Image modules' "$dockerfile" | cut -d: -f1)
[ -n "$verify_line" ] || fail 'kernel-stage config verification call is absent'
[ "$verify_line" -lt "$guard_line" ] || fail 'kernel config check does not run immediately after defconfig'
[ "$verify_line" -lt "$build_line" ] || fail 'kernel config check runs after compilation starts'

echo 'kernel-stage-kexec-test=PASS fixtures=6 modes=baseline,canary placement=post-defconfig'
