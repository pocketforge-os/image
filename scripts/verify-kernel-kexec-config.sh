#!/bin/sh
# Validate the resolved 7.x A133 kexec/G2D kernel contract.
#
# This file is both an executable early kernel-stage gate and a sourceable
# library for the late rootfs gate.  Keeping the symbol loop here prevents the
# two gates from drifting while the rootfs verifier retains its loader check.
set -eu

verify_kernel_kexec_config() {
	_pf_kexec_config=$1
	_pf_kexec_mode=$2
	_pf_kexec_miss_fn=$3

	case "$_pf_kexec_mode" in
		baseline|canary) ;;
		*) echo "FATAL: kernel kexec config verification: invalid expected mode: ${_pf_kexec_mode}" >&2; return 2 ;;
	esac

	if [ ! -f "$_pf_kexec_config" ] || [ -L "$_pf_kexec_config" ]; then
		"$_pf_kexec_miss_fn" kernel-config \
			"resolved kernel config is missing or not a regular file: ${_pf_kexec_config}"
		return 0
	fi

	for _pf_kexec_symbol in KEXEC KEXEC_CORE VIDEO_SUN50I_G2D_MIX; do
		_pf_kexec_count=$(grep -cx "CONFIG_${_pf_kexec_symbol}=y" "$_pf_kexec_config" || true)
		if [ "$_pf_kexec_count" -gt 1 ]; then
			"$_pf_kexec_miss_fn" "CONFIG_${_pf_kexec_symbol}" \
				"CONFIG_${_pf_kexec_symbol}=y appears ${_pf_kexec_count} times"
		elif [ "$_pf_kexec_count" -ne 1 ]; then
			"$_pf_kexec_miss_fn" "CONFIG_${_pf_kexec_symbol}" \
				"${_pf_kexec_mode} config requires CONFIG_${_pf_kexec_symbol}=y exactly once"
		fi
	done
}

# A sourcing caller supplies its own miss collector and summary.  Keeping the
# executable body in a conditional avoids relying on shell-specific source
# detection or a top-level return.
if [ "${PF_KERNEL_KEXEC_CONFIG_LIBRARY:-0}" != 1 ]; then
	kernel_config="${1:?usage: verify-kernel-kexec-config.sh KERNEL_CONFIG baseline|canary}"
	expected_mode="${2:?usage: verify-kernel-kexec-config.sh KERNEL_CONFIG baseline|canary}"
	missing=0

	kernel_kexec_config_miss() {
		missing=$((missing + 1))
		echo "MISSING item=$1 detail=kernel kexec config verification: $2" >&2
	}

	verify_kernel_kexec_config "$kernel_config" "$expected_mode" kernel_kexec_config_miss
	if [ "$missing" -gt 0 ]; then
		echo "kernel-kexec-config=FAIL mode=${expected_mode} missing=${missing}" >&2
		exit 1
	fi

	echo "kernel-kexec-config=PASS mode=${expected_mode} api=kexec_load g2d=enabled"
fi
