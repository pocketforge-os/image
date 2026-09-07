#!/usr/bin/env bash
# Compare decompressed PocketForge images after masking per-unit identity.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: verify-reproducible.sh --device DEVICE [--expected-sha SHA256] IMAGE_A [IMAGE_B]

Masks the device allowlist in scratch copies and verifies their SHA-256 digest.
With one image, the masked digest must equal the committed device baseline (or
--expected-sha). With two images, both masked digests must also equal each other.
Images must already be decompressed.
EOF
}

fail() {
    echo "FAIL: device=${DEVICE:-unknown} reason=$*" >&2
    exit 1
}

DEVICE=""
EXPECTED_OVERRIDE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --device)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            DEVICE="$2"
            shift 2
            ;;
        --expected-sha)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            EXPECTED_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "verify-reproducible.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            break
            ;;
    esac
done

[ -n "${DEVICE}" ] || { usage >&2; exit 2; }
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage >&2
    exit 2
fi
IMAGE_A="$1"
IMAGE_B="${2:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${DEVICE}" in
    a133) BOARD=tsp ;;
    a523) BOARD=tsp-s ;;
    *)    BOARD="${DEVICE}" ;;
esac
ALLOWLIST="${ROOT}/boards/${BOARD}/repro-allowlist.env"
[ -f "${ALLOWLIST}" ] || fail "allowlist-not-found path=${ALLOWLIST}"

unset REPRO_DEVICE REPRO_IMAGE_SIZE REPRO_EXPECTED_MASKED_SHA256 REPRO_MASK_RANGES
# The allowlist is committed input beside the board definition.
# shellcheck source=/dev/null
source "${ALLOWLIST}"

[ "${REPRO_DEVICE:-}" = "${DEVICE}" ] || \
    fail "allowlist-device-mismatch configured=${REPRO_DEVICE:-unset}"
case "${REPRO_IMAGE_SIZE:-}" in
    ''|*[!0-9]*) fail "invalid-image-size value=${REPRO_IMAGE_SIZE:-unset}" ;;
esac
[ "${REPRO_IMAGE_SIZE}" -gt 0 ] || fail "invalid-image-size value=${REPRO_IMAGE_SIZE}"

EXPECTED_SHA="${EXPECTED_OVERRIDE:-${REPRO_EXPECTED_MASKED_SHA256:-}}"
EXPECTED_SHA="$(printf '%s' "${EXPECTED_SHA}" | tr 'A-F' 'a-f')"
case "${EXPECTED_SHA}" in
    *[!0-9a-f]*|'') fail "invalid-expected-sha256" ;;
esac
[ "${#EXPECTED_SHA}" -eq 64 ] || fail "invalid-expected-sha256"

for command in awk cmp cp dd sha256sum stat; do
    command -v "${command}" >/dev/null 2>&1 || fail "missing-command command=${command}"
done

validate_image() {
    local image="$1" role="$2" size
    if [ ! -f "${image}" ] || [ ! -r "${image}" ]; then
        fail "image-${role}-not-readable path=${image}"
    fi
    size="$(stat -c%s "${image}")"
    [ "${size}" = "${REPRO_IMAGE_SIZE}" ] || \
        fail "image-${role}-size-mismatch expected=${REPRO_IMAGE_SIZE} actual=${size}"
}

validate_image "${IMAGE_A}" a
if [ -n "${IMAGE_B}" ]; then
    validate_image "${IMAGE_B}" b
fi

RANGES_CSV=""
previous_end=0
range_count=0
masked_bytes=0
while IFS=: read -r start end label extra; do
    [ -n "${start}" ] || continue
    case "${start}:${end}:${label}:${extra}" in
        *[!0-9A-Za-z_.:-]*) fail "invalid-allowlist-line" ;;
    esac
    case "${start}" in *[!0-9]*|'') fail "invalid-range-start value=${start}" ;; esac
    case "${end}" in *[!0-9]*|'') fail "invalid-range-end value=${end}" ;; esac
    if [ -z "${label}" ] || [ -n "${extra}" ]; then
        fail "invalid-range-label start=${start}"
    fi
    [ "${start}" -lt "${end}" ] || fail "empty-or-reversed-range start=${start} end=${end}"
    [ "${start}" -ge "${previous_end}" ] || fail "unsorted-or-overlapping-range start=${start}"
    [ "${end}" -le "${REPRO_IMAGE_SIZE}" ] || fail "range-past-image-end end=${end}"
    RANGES_CSV="${RANGES_CSV}${RANGES_CSV:+,}${start}:${end}"
    previous_end="${end}"
    range_count=$((range_count + 1))
    masked_bytes=$((masked_bytes + end - start))
done <<< "${REPRO_MASK_RANGES:-}"
[ "${range_count}" -gt 0 ] || fail "empty-allowlist"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/verify-reproducible.XXXXXX")"
trap 'rm -rf "${SCRATCH}"' EXIT

mask_and_hash() {
    local source="$1" destination="$2" start end label
    cp --reflink=auto --sparse=always -- "${source}" "${destination}"
    chmod u+w "${destination}"
    while IFS=: read -r start end label; do
        [ -n "${start}" ] || continue
        dd if=/dev/zero of="${destination}" bs=1 seek="${start}" \
            count="$((end - start))" conv=notrunc status=none
    done <<< "${REPRO_MASK_RANGES}"
    sha256sum "${destination}" | awk '{print $1}'
}

SHA_A="$(mask_and_hash "${IMAGE_A}" "${SCRATCH}/image-a.masked")"
SHA_B=""
if [ -n "${IMAGE_B}" ]; then
    SHA_B="$(mask_and_hash "${IMAGE_B}" "${SCRATCH}/image-b.masked")"
fi

if [ -n "${IMAGE_B}" ]; then
    # cmp reports one-based offsets. Summarize them without exposing raw bytes.
    summary="$(
        (cmp -l -- "${IMAGE_A}" "${IMAGE_B}" || [ "$?" -eq 1 ]) |
            awk -v ranges="${RANGES_CSV}" '
                BEGIN {
                    count = split(ranges, items, ",")
                    for (i = 1; i <= count; i++) {
                        split(items[i], bounds, ":")
                        starts[i] = bounds[1] + 0
                        ends[i] = bounds[2] + 0
                    }
                }
                {
                    offset = $1 - 1
                    total++
                    allowed_here = 0
                    for (i = 1; i <= count; i++) {
                        if (offset >= starts[i] && offset < ends[i]) {
                            allowed_here = 1
                            break
                        }
                    }
                    if (allowed_here) {
                        allowed++
                    } else {
                        extra++
                        if (extra <= 16) {
                            extras = extras (extras == "" ? "" : ",") offset
                        }
                    }
                }
                END { printf "%d|%d|%d|%s\n", total, allowed, extra, extras }
            '
    )"
    IFS='|' read -r raw_count allowed_count extra_count extra_offsets <<< "${summary}"
    extra_offsets="[${extra_offsets}]"
    echo "INFO: device=${DEVICE} raw_diff_count=${raw_count} allowlisted_diff_count=${allowed_count} extra_offsets=${extra_offsets}"

    if [ "${extra_count}" -ne 0 ]; then
        fail "raw-differences-outside-allowlist extra_offsets=${extra_offsets}"
    fi
    if [ "${SHA_A}" != "${SHA_B}" ]; then
        fail "masked-images-differ image_a=${SHA_A} image_b=${SHA_B}"
    fi
fi

if [ "${SHA_A}" != "${EXPECTED_SHA}" ]; then
    fail "expected-masked-sha-mismatch expected=${EXPECTED_SHA} actual=${SHA_A}"
fi
if [ -n "${SHA_B}" ] && [ "${SHA_B}" != "${EXPECTED_SHA}" ]; then
    fail "expected-masked-sha-mismatch expected=${EXPECTED_SHA} actual=${SHA_B}"
fi

if [ -n "${SHA_B}" ]; then
    echo "PASS: device=${DEVICE} masked-sha256 equal sha256=${SHA_A} expected=${EXPECTED_SHA} ranges=${range_count} masked_bytes=${masked_bytes}"
else
    echo "PASS: device=${DEVICE} masked-sha256=${SHA_A} expected=${EXPECTED_SHA} ranges=${range_count} masked_bytes=${masked_bytes}"
fi
