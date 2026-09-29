#!/usr/bin/env bash
# check-device-descriptor.sh — the B3 platform-inputs consume contract
# (bd: tsp-f3fm.202.1 R1, platform#217, image B4).
#
# Usage: check-device-descriptor.sh <gpu-model> <platform-inputs-dir> <descriptor-id> <descriptor-sha256>
#
# Platform emits PF_DEVICE_DESCRIPTOR_ID / PF_DEVICE_DESCRIPTOR_SHA256 and stages
# devices/<ID>/capabilities.toml ONLY for the A133-open app-runtime profiles.
#   non-open: the ID, the SHA-256 and the staged tree must all be empty; prints nothing.
#   open:     the ID must be a133, the SHA-256 well formed, the tree exactly one regular
#             devices/a133/capabilities.toml whose digest matches; prints its path.
# Any other combination is fatal. Parsing the file (Descriptor::load and the
# broker's remap) is the caller's next step.
set -euo pipefail

fail() {
    echo "FATAL: $*" >&2
    exit 1
}

[ "$#" -eq 4 ] || fail "usage: check-device-descriptor.sh <gpu-model> <platform-inputs-dir> <descriptor-id> <descriptor-sha256>"
gpu_model="$1"
inputs="$2"
descriptor_id="$3"
descriptor_sha256="$4"

[ -d "${inputs}" ] || fail "platform-inputs directory missing: ${inputs}"
staged="$(cd "${inputs}" && find . -mindepth 1 -print | LC_ALL=C sort)"

if [ "${gpu_model}" != open ]; then
    [ -z "${descriptor_id}" ] || fail "PF_DEVICE_DESCRIPTOR_ID set on a non-open profile: ${descriptor_id}"
    [ -z "${descriptor_sha256}" ] || fail "PF_DEVICE_DESCRIPTOR_SHA256 set on a non-open profile"
    [ -z "${staged}" ] || fail "platform-inputs staged for a non-open profile: $(tr '\n' ' ' <<<"${staged}")"
    exit 0
fi

[ -n "${descriptor_id}" ] || fail "A133-open build has no PF_DEVICE_DESCRIPTOR_ID (platform-inputs contract missing)"
[ "${descriptor_id}" = a133 ] || fail "unexpected PF_DEVICE_DESCRIPTOR_ID=${descriptor_id} (A133-open ships devices/a133 only)"
printf '%s\n' "${descriptor_sha256}" | grep -Eqx '[0-9a-f]{64}' || fail "malformed PF_DEVICE_DESCRIPTOR_SHA256"
descriptor="${inputs%/}/devices/${descriptor_id}/capabilities.toml"
[ -f "${descriptor}" ] && [ ! -L "${descriptor}" ] || fail "staged descriptor missing or not a regular file: ${descriptor}"
expected_tree="$(printf '%s\n' ./devices "./devices/${descriptor_id}" "./devices/${descriptor_id}/capabilities.toml")"
[ "${staged}" = "${expected_tree}" ] || fail "platform-inputs holds more than the one descriptor: $(tr '\n' ' ' <<<"${staged}")"
actual_sha256="$(sha256sum "${descriptor}" | cut -d' ' -f1)"
[ "${actual_sha256}" = "${descriptor_sha256}" ] || fail "descriptor sha256 ${actual_sha256} != PF_DEVICE_DESCRIPTOR_SHA256 ${descriptor_sha256}"
printf '%s\n' "${descriptor}"
