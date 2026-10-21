#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$root/boards/tsp/initrd/self-flash-v3.sh"
builder="$root/boards/tsp/initrd/build-initrd.sh"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-selfflash-v3.XXXXXX")"
cleanup() {
    find "$tmp" -mindepth 1 -delete
    rmdir "$tmp"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$engine" ]] || fail 'production self-flash v3 engine missing'
# shellcheck source=/dev/null
. "$engine"
for function in sf_v3_require_pipefail sf_v3_stream_write sf_v3_write_sink; do
    declare -F "$function" >/dev/null || fail "$function missing"
done

grep -Fq 'pocketforge.self-flash-initrd-capability/v3' "$builder" \
    || fail 'initrd v3 capability marker is not assembled'
grep -Fq 'ContractSHA256=' "$builder" \
    || fail 'initrd v3 capability marker is not contract-bound'
grep -Fq 'iflag=skip_bytes,count_bytes' "$engine" \
    || fail 'tail reader does not enforce its exact compressed byte range'
grep -Fq 'conv=notrunc,fsync' "$engine" \
    || fail 'whole-image writer lacks checked durable completion'
grep -Fq 'FullDeviceReadback=not-performed' "$engine" \
    || fail 'v3 receipt is not truthful about omitted full readback'
if grep -Eq '(/run|/dev/shm|/tmp)/.*(stage|seed|image|xz)' "$engine"; then
    fail 'candidate or seed staging path uses RAM-backed storage'
fi

raw="$tmp/raw.img"
long_raw="$tmp/raw-long.img"
short_raw="$tmp/raw-short.img"
xz_good="$tmp/good.img.xz"
xz_long="$tmp/long.img.xz"
xz_short="$tmp/short.img.xz"
xz_corrupt="$tmp/corrupt.img.xz"
xz_truncated="$tmp/truncated.img.xz"
disk="$tmp/card.img"
work="$tmp/work"
mkdir -p "$work"

# Non-repeating text makes both byte-count and digest controls observable while
# keeping the fixture small enough for the deliberately exact stream checks.
for value in $(seq 0 32767); do printf '%08x\n' "$value"; done >"$raw"
cp "$raw" "$long_raw"
printf 'trailing-decompressed-byte' >>"$long_raw"
head -c $(( $(stat -c %s "$raw") - 17 )) "$raw" >"$short_raw"
xz -z -c "$raw" >"$xz_good"
xz -z -c "$long_raw" >"$xz_long"
xz -z -c "$short_raw" >"$xz_short"
cp "$xz_good" "$xz_corrupt"
printf '\377' | dd of="$xz_corrupt" bs=1 seek=32 conv=notrunc status=none
head -c $(( $(stat -c %s "$xz_good") - 7 )) "$xz_good" >"$xz_truncated"

raw_bytes="$(stat -c %s "$raw")"
raw_sha="$(sha256sum "$raw" | cut -d' ' -f1)"
stage_offset=$((8 * 1024 * 1024))

reset_disk() {
    truncate -s $((16 * 1024 * 1024)) "$disk"
    printf 'TAIL-SENTINEL' | dd of="$disk" bs=1 seek="$raw_bytes" conv=notrunc status=none
    find "$work" -mindepth 1 -delete
}

stage_xz() {
    local source=$1
    SF_V3_COMPRESSED_BYTES="$(stat -c %s "$source")"
    dd if="$source" of="$disk" bs=1 seek="$stage_offset" conv=notrunc status=none
}

set_contract() {
    SF_V3_SD="$disk"
    SF_V3_STAGE_OFFSET="$stage_offset"
    SF_V3_TARGET_RAW_BYTES="$raw_bytes"
    SF_V3_TARGET_RAW_SHA256="$raw_sha"
    SF_V3_WORK="$work"
    export SF_V3_SD SF_V3_STAGE_OFFSET SF_V3_COMPRESSED_BYTES
    export SF_V3_TARGET_RAW_BYTES SF_V3_TARGET_RAW_SHA256 SF_V3_WORK
}

reset_disk
stage_xz "$xz_good"
set_contract
sf_v3_stream_write || fail 'valid checked stream refused'
cmp -n "$raw_bytes" "$raw" "$disk" || fail 'positive output bytes differ'
[[ "$SF_V3_RAW_STREAM_BYTES" == "$raw_bytes" ]] || fail 'positive raw count differs'
[[ "$SF_V3_RAW_STREAM_SHA256" == "$raw_sha" ]] || fail 'positive raw digest differs'
[[ "$SF_V3_XZ_RESULT" == pass && "$SF_V3_WRITE_RESULT" == pass ]] \
    || fail 'positive result fields are not pass'
tail_value="$(dd if="$disk" bs=1 skip="$raw_bytes" count=13 status=none)"
[[ "$tail_value" == TAIL-SENTINEL ]] || fail 'writer crossed TargetRawBytes'

expect_stream_failure() {
    local name=$1 source=$2
    reset_disk
    stage_xz "$source"
    set_contract
    if sf_v3_stream_write; then
        fail "$name negative control was accepted"
    fi
}

expect_stream_failure corrupt-xz "$xz_corrupt"
expect_stream_failure truncated-xz "$xz_truncated"
expect_stream_failure short-raw "$xz_short"
expect_stream_failure trailing-raw "$xz_long"

reset_disk
stage_xz "$xz_good"
set_contract
SF_V3_TARGET_RAW_SHA256="$(printf wrong | sha256sum | cut -d' ' -f1)"
export SF_V3_TARGET_RAW_SHA256
if sf_v3_stream_write; then
    fail 'wrong decompressed SHA negative control was accepted'
fi

reset_disk
stage_xz "$xz_good"
set_contract
eval "$(declare -f sf_v3_write_sink | sed '1s/sf_v3_write_sink/sf_v3_write_sink_real/')"
sf_v3_write_sink() { return 23; }
if sf_v3_stream_write; then
    fail 'write failure negative control was accepted'
fi
eval "$(declare -f sf_v3_write_sink_real | sed '1s/sf_v3_write_sink_real/sf_v3_write_sink/')"

reset_disk
stage_xz "$xz_good"
set_contract
eval "$(declare -f sf_v3_require_pipefail | sed '1s/sf_v3_require_pipefail/sf_v3_require_pipefail_real/')"
sf_v3_require_pipefail() { return 1; }
if sf_v3_stream_write; then
    fail 'unsupported pipefail negative control was accepted'
fi

printf 'SELF_FLASH_V3_INITRD_TEST result=PASS controls=positive,corrupt,truncated,short,trailing,raw-sha,write,pipefail\n'
