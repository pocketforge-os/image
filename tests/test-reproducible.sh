#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY="${ROOT}/scripts/verify-reproducible.sh"
ALLOWLIST="${ROOT}/boards/tsp/repro-allowlist.env"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

# shellcheck source=/dev/null
source "${ALLOWLIST}"

[ "${REPRO_DEVICE}" = a133 ]
[ "${REPRO_IMAGE_SIZE}" = 1195397120 ]
[ "${REPRO_EXPECTED_MASKED_SHA256}" = \
    5ed90ca924f258de9b96aa2e2e32b5c05360efe9ed6356a463eccffc65a16e41 ]

image_a="${SCRATCH}/a.img"
image_b="${SCRATCH}/b.img"
expected_image="${SCRATCH}/expected.img"
truncate -s "${REPRO_IMAGE_SIZE}" "${image_a}"
printf 'content-canary' | dd of="${image_a}" bs=1 seek=4096 conv=notrunc status=none
cp --reflink=auto --sparse=always "${image_a}" "${image_b}"

# Exercise every allowlisted field, not merely a representative offset.
while IFS=: read -r start end _label; do
    [ -n "${start}" ] || continue
    printf '\001' | dd of="${image_a}" bs=1 seek="${start}" conv=notrunc status=none
    printf '\002' | dd of="${image_b}" bs=1 seek="$((end - 1))" conv=notrunc status=none
done <<< "${REPRO_MASK_RANGES}"

cp --reflink=auto --sparse=always "${image_a}" "${expected_image}"
while IFS=: read -r start end _label; do
    [ -n "${start}" ] || continue
    dd if=/dev/zero of="${expected_image}" bs=1 seek="${start}" \
        count="$((end - start))" conv=notrunc status=none
done <<< "${REPRO_MASK_RANGES}"
expected_sha="$(sha256sum "${expected_image}" | awk '{print $1}')"

pass_output="$(${VERIFY} --device a133 --expected-sha "${expected_sha}" \
    "${image_a}" "${image_b}")"
grep -Fq 'PASS: device=a133 masked-sha256 equal' <<< "${pass_output}"
grep -Fq 'extra_offsets=[]' <<< "${pass_output}"
grep -Fq 'masked_bytes=220' <<< "${pass_output}"

# The partition type GUID is content. A difference there must never be hidden by
# the neighboring per-partition unique-GUID allowlist.
printf '\003' | dd of="${image_b}" bs=1 seek=81920 conv=notrunc status=none
if "${VERIFY}" --device a133 --expected-sha "${expected_sha}" \
    "${image_a}" "${image_b}" >"${SCRATCH}/type-guid.out" 2>&1; then
    echo 'FAIL: verifier masked a partition TYPE-GUID difference' >&2
    exit 1
fi
grep -Fq 'extra_offsets=[81920]' "${SCRATCH}/type-guid.out"

# One-image mode must assert the selected expected digest.
if "${VERIFY}" --device a133 --expected-sha \
    0000000000000000000000000000000000000000000000000000000000000000 \
    "${image_a}" >"${SCRATCH}/wrong-sha.out" 2>&1; then
    echo 'FAIL: verifier accepted the wrong expected masked digest' >&2
    exit 1
fi
grep -Fq 'reason=expected-masked-sha-mismatch' "${SCRATCH}/wrong-sha.out"

echo 'PASS: A133 reproducibility mask accepts identity fields and rejects content deltas'
