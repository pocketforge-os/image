#!/usr/bin/env bash
# Kill-at-offset controls for the self-flash v3 write order (tsp-1a7a5b84).
# The write sink is cut after K cumulative bytes; the SD must then hold either
# the complete old boot chain (cut during the rootfs range) or a state where a
# new SPL implies everything else is already new. A corrupt stage must not
# touch the SD at all.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$root/boards/tsp/initrd/self-flash-v3.sh"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-selfflash-v3-kill.XXXXXX")"
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$engine"

# Scaled geometry: 1 MiB raw, "SPL region" 64 KiB, "boot chain" 256 KiB.
raw_bytes=1048576
export SF_V3_SPL_REGION_BYTES=65536 SF_V3_BOOT_CHAIN_BYTES=262144
SF_V3_TRANSFER_BYTES=16384
old="$tmp/old.img" new="$tmp/new.img" xz_new="$tmp/new.img.xz" disk="$tmp/card.img"
head -c "$raw_bytes" /dev/zero | tr '\0' 'O' >"$old"
for v in $(seq 0 131071); do printf '%07x\n' "$v"; done | head -c "$raw_bytes" >"$new"
xz -z -c "$new" >"$xz_new"
stage_offset=$((2 * 1024 * 1024))
raw_sha="$(sha256sum "$new" | cut -d' ' -f1)"

reset_disk() {
    cp "$old" "$disk"
    truncate -s $((4 * 1024 * 1024)) "$disk"
    dd if="$1" of="$disk" bs=1 seek="$stage_offset" conv=notrunc status=none
    SF_V3_COMPRESSED_BYTES="$(stat -c %s "$1")"
    exec 9<>"$disk"
    SF_V3_SD_IO=/proc/self/fd/9 SF_V3_STAGE_OFFSET="$stage_offset"
    SF_V3_TARGET_RAW_BYTES="$raw_bytes" SF_V3_TARGET_RAW_SHA256="$raw_sha"
    SF_V3_WORK="$tmp/work"
    rm -rf "$SF_V3_WORK"; mkdir -p "$SF_V3_WORK"
    export SF_V3_SD_IO SF_V3_STAGE_OFFSET SF_V3_COMPRESSED_BYTES
    export SF_V3_TARGET_RAW_BYTES SF_V3_TARGET_RAW_SHA256 SF_V3_WORK
}

# Cumulative byte budget across the three write ranges.
eval "$(declare -f sf_v3_write_sink | sed '1s/sf_v3_write_sink/sf_v3_write_sink_real/')"
budget_file="$tmp/budget"
sf_v3_write_sink() {
    local b n=$(( $2 - $1 )) cut=0
    b="$(cat "$budget_file")"
    if [ "$n" -gt "$b" ]; then n=$b cut=1; fi
    printf '%s' $(( b - n )) >"$budget_file"
    if [ "$n" -gt 0 ]; then
        dd of="$SF_V3_SD_IO" bs=4096 iflag=skip_bytes,count_bytes,fullblock \
            oflag=seek_bytes skip="$1" seek="$1" count="$n" \
            conv=notrunc,fsync status=none 2>/dev/null || :
    fi
    cat >/dev/null 2>&1 || :
    if [ "$cut" -eq 1 ]; then return 137; fi
}

# region: first $1 bytes of the SD compared against old/new, 0 = identical.
same() { cmp -s -n "$3" <(dd if="$disk" bs=1 skip="$2" count="$3" status=none 2>/dev/null) \
            <(dd if="$1" bs=1 skip="$2" count="$3" status=none 2>/dev/null); }

spl=$SF_V3_SPL_REGION_BYTES chain=$SF_V3_BOOT_CHAIN_BYTES

# Positive control: full write is exactly the new image.
reset_disk "$xz_new"
printf '%s' "$raw_bytes" >"$budget_file"
sf_v3_stream_write || fail 'full write refused'
cmp -n "$raw_bytes" "$new" "$disk" || fail 'full write differs from new image'

# Kill at offsets, including every range boundary +-1.
points="0 1 4095 4096 100000 $((chain - 1)) $chain $((chain + 1)) 524288 $((raw_bytes - 1))
$((raw_bytes - chain - 1)) $((raw_bytes - chain)) $((raw_bytes - chain + 1))
$((raw_bytes - spl - 1)) $((raw_bytes - spl)) $((raw_bytes - spl + 1)) $((raw_bytes - 1))"
tail_bytes=$((raw_bytes - chain))
count=0
for k in $points; do
    [ "$k" -lt "$raw_bytes" ] || continue
    reset_disk "$xz_new"
    printf '%s' "$k" >"$budget_file"
    if sf_v3_stream_write; then fail "kill at $k did not fail the write"; fi
    count=$((count + 1))
    if [ "$k" -lt "$tail_bytes" ]; then
        # Cut inside the rootfs range: the whole old boot chain is intact.
        same "$old" 0 "$chain" || fail "kill at $k: boot chain not the complete old chain"
    else
        # Past the rootfs range. The SPL region is written last, so anything
        # past it must already be the complete new image; only the final
        # SPL-region write itself may be partial (documented window).
        same "$new" "$spl" $((raw_bytes - spl)) || {
            # still inside range 2: the SPL region must be wholly old
            same "$old" 0 "$spl" || fail "kill at $k: SPL region touched before range 2 finished"
            [ "$k" -ge "$tail_bytes" ] || fail "kill at $k: unexpected state"
        }
        if [ "$k" -lt $((raw_bytes - spl)) ]; then
            same "$old" 0 "$spl" || fail "kill at $k: SPL region changed before the final range"
            same "$new" "$chain" $((raw_bytes - chain)) || fail "kill at $k: rootfs range incomplete"
        fi
    fi
done

# Corrupt stage: verified before the first write, SD raw range untouched.
xz_bad="$tmp/bad.img.xz"; cp "$xz_new" "$xz_bad"
printf '\377' | dd of="$xz_bad" bs=1 seek=$(( $(stat -c %s "$xz_bad") / 2 )) conv=notrunc status=none
reset_disk "$xz_bad"
printf '%s' "$raw_bytes" >"$budget_file"
if sf_v3_stream_write; then fail 'corrupt stage accepted'; fi
cmp -n "$raw_bytes" "$old" "$disk" || fail 'corrupt stage modified the SD before verify failed'
[ "$(cat "$budget_file")" = "$raw_bytes" ] || fail 'sink was invoked for a corrupt stage'

printf 'SELF_FLASH_V3_KILLPOINTS result=PASS points=%s\n' "$count"
