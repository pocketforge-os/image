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
    } | sf_v3_write_sink_real "$@"
}
# Same throttle on the verify sink so the silent verify lasts long enough for a heartbeat.
eval "$(declare -f sf_v3_verify_sink | sed '1s/sf_v3_verify_sink/sf_v3_verify_sink_real/')"
sf_v3_verify_sink() {
    {
        n=0
        while [ "$n" -lt 9 ]; do
            dd bs=32768 count=1 iflag=fullblock status=none
            n=$((n + 1)); sleep 0.3
        done
    } | sf_v3_verify_sink_real
}
SF_V3_PROGRESS_HEARTBEAT_MS=400
export SF_V3_PROGRESS_HEARTBEAT_MS
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

# ---- liveness during the silent verify (bash host run) ----
# The runner only counts grammar markers; DETAIL lines are operator/log evidence
# and must never fullmatch the grammar.
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify bytes=[0-9]+ total=[0-9]+ elapsed_ms=[0-9]+ proc=(found|absent)$' "$log" \
    || fail 'no verify heartbeat DETAIL line'
if grep -E '^PF_SELF_FLASH_V3_PROGRESS_DETAIL' "$log" | grep -Eq "$marker_re"; then
    fail 'a DETAIL line matches the automation grammar'
fi
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify ' "$tmp/noproc.log" \
    || fail 'noproc: verify heartbeat must not depend on finding the process'

# ---- dd found but no /proc/<pid>/io (kernel without CONFIG_TASK_IO_ACCOUNTING) ----
# Heartbeats must say so (proc=noio, not absent), and the write must still pass.
fakeproc="$tmp/fakeproc"; mkdir -p "$fakeproc/4242/fd"
printf 'dd\n' >"$fakeproc/4242/comm"
ln -s "$disk" "$fakeproc/4242/fd/0"; ln -s "$disk" "$fakeproc/4242/fd/1"
reset_disk; stage_xz "$xz_good"; set_contract
SF_V3_PROC="$fakeproc" sf_v3_stream_write 2>"$tmp/noio.log" || fail 'missing io accounting broke the write'
cmp -n "$raw_bytes" "$raw" "$disk" || fail 'noio output bytes differ'
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify bytes=0 total=[0-9]+ elapsed_ms=[0-9]+ proc=noio$' "$tmp/noio.log" \
    || fail 'noio: verify heartbeat does not report proc=noio'
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=0 total=294912 elapsed_ms=[0-9]+ read=0 proc=noio$' "$tmp/noio.log" \
    || fail 'noio: write heartbeat does not report proc=noio'
if grep -q '^PF_SELF_FLASH_V3_PROGRESS phase=write percent' "$tmp/noio.log"; then
    fail 'noio: write percent emitted without io accounting'
fi
grep -qx 'PF_SELF_FLASH_V3_PROGRESS phase=write-end percent=100' "$tmp/noio.log" || fail 'noio: no write-end'

# ---- the REAL initrd shell: BusyBox ash running NOEXEC dd applets ----
# The initrd runs `#!/bin/busybox sh` with standalone applets, so `dd` is forked
# WITHOUT exec: /proc/<pid>/cmdline of the sink dd is the shell's own argv
# ("/bin/busybox sh ..."), never "dd ... of=...". GNU dd above cannot reproduce
# that; this section runs the engine under a real BusyBox with SF_V3_PROC=/proc.
# PF_TEST_BUSYBOX selects the binary (e.g. the image's baked busybox-arm64 via
# binfmt qemu); default is the host busybox-static. No busybox is a FAIL, not a skip.
bb="${PF_TEST_BUSYBOX:-$(command -v busybox || true)}"
[[ -n "$bb" && -x "$bb" ]] || fail 'no busybox (install busybox-static or set PF_TEST_BUSYBOX)'
emptybin="$tmp/emptybin"; mkdir -p "$emptybin"

# Prove the target condition holds for this busybox: the dd child keeps the
# shell's cmdline. Otherwise this section would not test what the DUT runs.
probe_out="$tmp/probe.out"
PATH="$emptybin" "$bb" sh -c '
    { sleep 1; } | dd of="$1" status=none &
    p=$!; sleep 0.3
    printf "cmdline=%s\n" "$(tr "\000" " " <"/proc/$p/cmdline")"
    printf "fd1=%s\n" "$(readlink -f "/proc/$p/fd/1")"
    wait' bbprobe "$tmp/probe.bin" >"$probe_out" 2>&1 || fail "busybox probe failed: $(cat "$probe_out")"
grep -q '^cmdline=.*of=' "$probe_out" \
    && fail "busybox $bb execs dd (cmdline carries of=); cannot model the initrd: $(cat "$probe_out")"
grep -qx "fd1=$(readlink -f "$tmp/probe.bin")" "$probe_out" \
    || fail "busybox dd does not hold of= on fd 1: $(cat "$probe_out")"

bb_driver="$tmp/bb-driver.sh"
{
    printf '. "%s"\n' "$engine"
    # The engine's own sink body, renamed, so the dd starts exactly as in the initrd.
    sed -n '/^sf_v3_write_sink() {$/,/^}$/p' "$engine" | sed '1s/^sf_v3_write_sink()/sf_v3_write_sink_real()/'
    sed -n '/^sf_v3_verify_sink() {$/,/^}$/p' "$engine" | sed '1s/^sf_v3_verify_sink()/sf_v3_verify_sink_real()/'
    cat <<'EOF'
sf_v3_throttle() {
    n=0
    while [ "$n" -lt 9 ]; do
        dd bs=32768 count=1 iflag=fullblock status=none
        n=$((n + 1)); sleep 0.6
    done
}
sf_v3_write_sink() { sf_v3_throttle | sf_v3_write_sink_real "$@"; }
sf_v3_verify_sink() { sf_v3_throttle | sf_v3_verify_sink_real; }
SF_V3_SD="$1"
exec 9<>"$SF_V3_SD"
SF_V3_SD_IO=/proc/self/fd/9
SF_V3_STAGE_OFFSET="$2"; SF_V3_COMPRESSED_BYTES="$3"
SF_V3_TARGET_RAW_BYTES="$4"; SF_V3_TARGET_RAW_SHA256="$5"; SF_V3_WORK="$6"
SF_V3_TRANSFER_BYTES=32768
SF_V3_BOOT_CHAIN_BYTES=65536
SF_V3_SPL_REGION_BYTES=32768
SF_V3_PROC=/proc
SF_V3_PROGRESS_INTERVAL=0.1
SF_V3_PROGRESS_HEARTBEAT_MS=400
export SF_V3_SD SF_V3_SD_IO SF_V3_STAGE_OFFSET SF_V3_COMPRESSED_BYTES
export SF_V3_TARGET_RAW_BYTES SF_V3_TARGET_RAW_SHA256 SF_V3_WORK
if sf_v3_stream_write; then rc=0; else rc=$?; fi
# busybox keeps reaped "Terminated" entries in its job table; what matters is
# that no background job (a sampler) is still alive.
for j in $(jobs -p); do
    ! kill -0 "$j" 2>/dev/null || { echo "BB_DRIVER sampler left running pid=$j" >&2; rc=97; }
done
echo "BB_DRIVER rc=$rc write=$SF_V3_WRITE_RESULT" >&2
exit "$rc"
EOF
} >"$bb_driver"

# Incompressible fixture of the same size: the compressed stage (~288 KiB) then
# outlasts the pipe buffers, so the stage-reader dd stays alive through the
# throttled verify, as the ~600 MB stage read does on the device.
bb_raw="$tmp/bb-raw.img"; bb_xz="$tmp/bb-raw.img.xz"
head -c "$raw_bytes" /dev/urandom >"$bb_raw"
xz -z -c "$bb_raw" >"$bb_xz"
bb_sha="$(sha256sum "$bb_raw" | cut -d' ' -f1)"
reset_disk; stage_xz "$bb_xz"
bb_log="$tmp/bb.log"
PATH="$emptybin" "$bb" sh "$bb_driver" "$disk" "$stage_offset" "$SF_V3_COMPRESSED_BYTES" \
    "$raw_bytes" "$bb_sha" "$work" 2>"$bb_log" \
    || fail "busybox run failed: $(tail -n 20 "$bb_log")"
grep -qx 'BB_DRIVER rc=0 write=pass' "$bb_log" || fail "busybox driver: $(tail -n 5 "$bb_log")"
cmp -n "$raw_bytes" "$bb_raw" "$disk" || fail 'busybox: output bytes differ'
if grep -E '^PF_SELF_FLASH_V3_PROGRESS' "$bb_log" | grep -Ev '^PF_SELF_FLASH_V3_PROGRESS(_DETAIL)? ' | grep -q .; then
    fail 'busybox: malformed progress line'
fi
grep -E '^PF_SELF_FLASH_V3_PROGRESS ' "$bb_log" >"$tmp/bb.markers" || fail 'busybox: no markers'
while IFS= read -r line; do
    [[ "$line" =~ $marker_re ]] || fail "busybox: marker violates automation grammar: $line"
done <"$tmp/bb.markers"
head -n1 "$tmp/bb.markers" | grep -qx 'PF_SELF_FLASH_V3_PROGRESS phase=start percent=0' \
    || fail 'busybox: first marker is not start/0'
tail -n1 "$tmp/bb.markers" | grep -qx 'PF_SELF_FLASH_V3_PROGRESS phase=write-end percent=100' \
    || fail 'busybox: last marker is not write-end/100'
mapfile -t bb_writes < <(sed -n 's/^PF_SELF_FLASH_V3_PROGRESS phase=write percent=//p' "$tmp/bb.markers")
(( ${#bb_writes[@]} >= 2 )) \
    || fail "busybox: sampler never found the NOEXEC sink dd (${#bb_writes[@]} write markers): $(grep PROGRESS "$bb_log" | head -n 12)"
prev=0
for p in "${bb_writes[@]}"; do
    (( p > prev && p < 100 )) || fail "busybox: write percent not strictly increasing: $p after $prev"
    prev=$p
done
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+$' "$bb_log" \
    || fail 'busybox: no write DETAIL line'
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify bytes=[0-9]+ total=[0-9]+ elapsed_ms=[0-9]+ proc=found$' "$bb_log" \
    || fail 'busybox: verify heartbeat never found the stage reader'
# Range 1 skips BOOT_CHAIN bytes before writing anything: liveness must show
# before the first whole percent, with the sink found and still at bytes=0.
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+ read=[0-9]+ proc=found$' "$bb_log" \
    || fail 'busybox: no write heartbeat DETAIL line'
first_write_line="$(grep -n '^PF_SELF_FLASH_V3_PROGRESS phase=write ' "$bb_log" | head -n1 | cut -d: -f1)"
start_line="$(grep -n '^PF_SELF_FLASH_V3_PROGRESS phase=start ' "$bb_log" | head -n1 | cut -d: -f1)"
sed -n "${start_line},${first_write_line}p" "$bb_log" \
    | grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write .* proc=found$' \
    || fail 'busybox: no heartbeat between start/0 and the first write percent'
if grep -E '^PF_SELF_FLASH_V3_PROGRESS_DETAIL' "$bb_log" | grep -Eq "$marker_re"; then
    fail 'busybox: a DETAIL line matches the automation grammar'
fi

printf 'SELF_FLASH_V3_PROGRESS_TEST result=PASS writes=%s busybox_writes=%s busybox=%s\n' \
    "${#writes[@]}" "${#bb_writes[@]}" "$bb"
