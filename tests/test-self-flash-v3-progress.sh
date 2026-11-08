#!/usr/bin/env bash
# Hermetic test: self-flash-v3.sh emits PF_SELF_FLASH_V3_PROGRESS markers (the exact
# grammar parsed by pocketforge-automation pf_self_flash_v3_live._PROGRESS) at intervals
# during the SD write, and the write/verify path is otherwise unchanged
# (docs/ota-v3-failure-rca.md in pocketforge-automation: initrd progress visibility).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"  # contract invokes via sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$root/boards/tsp/initrd/self-flash-v3.sh"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-selfflash-v3-progress.XXXXXX")"
cleanup() { find "$tmp" -mindepth 1 -delete; rmdir "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$engine"
declare -F sf_v3_write_sink >/dev/null || fail 'sf_v3_write_sink missing'

raw="$tmp/raw.img"; xz_good="$tmp/good.img.xz"; xz_corrupt="$tmp/corrupt.img.xz"
disk="$tmp/card.img"; work="$tmp/work"; mkdir -p "$work"
# 9 x 32768 bytes: the throttled sink below moves exactly one 32 KiB block per tick.
for value in $(seq 0 32767); do printf '%08x\n' "$value"; done >"$raw"
raw_bytes="$(stat -c %s "$raw")"
[[ "$raw_bytes" == 294912 ]] || fail 'fixture size changed'
raw_sha="$(sha256sum "$raw" | cut -d' ' -f1)"
xz -z -c "$raw" >"$xz_good"
cp "$xz_good" "$xz_corrupt"
printf '\377' | dd of="$xz_corrupt" bs=1 seek=32 conv=notrunc status=none
stage_offset=$((8 * 1024 * 1024))

reset_disk() {
    truncate -s $((16 * 1024 * 1024)) "$disk"
    find "$work" -mindepth 1 -delete
}
stage_xz() {
    SF_V3_COMPRESSED_BYTES="$(stat -c %s "$1")"
    dd if="$1" of="$disk" bs=1 seek="$stage_offset" conv=notrunc status=none
}
set_contract() {
    SF_V3_SD="$disk"
    exec 9<>"$SF_V3_SD"
    SF_V3_SD_IO=/proc/self/fd/9
    SF_V3_STAGE_OFFSET="$stage_offset"
    SF_V3_TARGET_RAW_BYTES="$raw_bytes"
    SF_V3_TARGET_RAW_SHA256="$raw_sha"
    SF_V3_WORK="$work"
    export SF_V3_SD SF_V3_SD_IO SF_V3_STAGE_OFFSET SF_V3_COMPRESSED_BYTES
    export SF_V3_TARGET_RAW_BYTES SF_V3_TARGET_RAW_SHA256 SF_V3_WORK
}

# Slow the real sink down (one 32 KiB block per tick) so the sampler observes mid-write.
eval "$(declare -f sf_v3_write_sink | sed '1s/sf_v3_write_sink/sf_v3_write_sink_real/')"
sf_v3_write_sink() {
    {
        n=0
        while [ "$n" -lt 9 ]; do
            dd bs=32768 count=1 iflag=fullblock status=none
            n=$((n + 1)); sleep 0.6
        done
    } | sf_v3_write_sink_real
}
SF_V3_TRANSFER_BYTES=32768
SF_V3_PROGRESS_INTERVAL=0.1

# Exact grammar from pf_self_flash_v3_live._PROGRESS (fullmatch per line).
marker_re='^PF_SELF_FLASH_V3_PROGRESS phase=(start|write|write-end|stamp) percent=(0|[1-9][0-9]?|100)$'

# ---- positive: markers appear at intervals, monotonic, grammar-exact ----
reset_disk; stage_xz "$xz_good"; set_contract
log="$tmp/pos.log"
sf_v3_stream_write 2>"$log" || fail 'valid stream refused'
cmp -n "$raw_bytes" "$raw" "$disk" || fail 'output bytes differ'
[[ "$SF_V3_RAW_STREAM_SHA256" == "$raw_sha" && "$SF_V3_WRITE_RESULT" == pass ]] \
    || fail 'verification fields changed'
[[ -z "$(jobs -r)" ]] || fail 'progress sampler left running'

grep -E '^PF_SELF_FLASH_V3_PROGRESS( |$)' "$log" >"$tmp/markers" || fail 'no progress markers'
while IFS= read -r line; do
    [[ "$line" =~ $marker_re ]] || fail "marker violates automation grammar: $line"
done <"$tmp/markers"
head -n1 "$tmp/markers" | grep -qx 'PF_SELF_FLASH_V3_PROGRESS phase=start percent=0' \
    || fail 'first marker is not start/0'
tail -n1 "$tmp/markers" | grep -qx 'PF_SELF_FLASH_V3_PROGRESS phase=write-end percent=100' \
    || fail 'last marker is not write-end/100'
mapfile -t writes < <(sed -n 's/^PF_SELF_FLASH_V3_PROGRESS phase=write percent=//p' "$tmp/markers")
(( ${#writes[@]} >= 2 )) || fail "expected >=2 intermediate write markers, got ${#writes[@]}"
prev=0
for p in "${writes[@]}"; do
    (( p > prev && p < 100 )) || fail "write percent not strictly increasing within 1..99: $p after $prev"
    prev=$p
done
# Bytes written + elapsed accompany each write marker (separate line; the
# automation regex fullmatches, so extra fields cannot ride on the marker line).
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+$' "$log" \
    || fail 'no detail line with bytes/elapsed'

# ---- progress source unavailable: write must still pass, only start/write-end ----
reset_disk; stage_xz "$xz_good"; set_contract
SF_V3_PROC=/nonexistent sf_v3_stream_write 2>"$tmp/noproc.log" || fail 'unreadable /proc broke the write'
cmp -n "$raw_bytes" "$raw" "$disk" || fail 'noproc output bytes differ'
grep -q 'phase=write-end percent=100' "$tmp/noproc.log" || fail 'noproc: no write-end'

# ---- negative: corrupt stream still fails, and never claims write-end ----
reset_disk; stage_xz "$xz_corrupt"; set_contract
if sf_v3_stream_write 2>"$tmp/neg.log"; then fail 'corrupt stream accepted'; fi
if grep -q 'phase=write-end' "$tmp/neg.log"; then fail 'write-end emitted for failed write'; fi
[[ -z "$(jobs -r)" ]] || fail 'sampler left running after failure'

# ---- stamp marker never changes install_stamp's status ----
grep -q 'sf_v3_progress_marker stamp 100' "$engine" || fail 'stamp marker missing from engine'

printf 'SELF_FLASH_V3_PROGRESS_TEST result=PASS writes=%s\n' "${#writes[@]}"
