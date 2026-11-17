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
# Up to the /sys section below the card file has no /sys/block entry: these
# runs model a kernel with no usable block stat (src=proc|absent).
SF_V3_SYS_BLOCK=/nonexistent

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
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+ sectors=[0-9]+ src=proc$' "$log" \
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
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify bytes=[0-9]+ total=[0-9]+ elapsed_ms=[0-9]+ proc=(found|absent) sectors=[0-9]+ src=(proc|absent)$' "$log" \
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
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify bytes=0 total=[0-9]+ elapsed_ms=[0-9]+ proc=noio sectors=0 src=absent$' "$tmp/noio.log" \
    || fail 'noio: verify heartbeat does not report proc=noio'
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=0 total=294912 elapsed_ms=[0-9]+ read=0 proc=noio sectors=0 src=absent$' "$tmp/noio.log" \
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
SF_V3_PROC="${PF_BB_PROC:-/proc}"
SF_V3_SYS_BLOCK="${PF_BB_SYS_BLOCK:-/nonexistent}"
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
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+ sectors=[0-9]+ src=proc$' "$bb_log" \
    || fail 'busybox: no write DETAIL line'
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify bytes=[0-9]+ total=[0-9]+ elapsed_ms=[0-9]+ proc=found sectors=[0-9]+ src=proc$' "$bb_log" \
    || fail 'busybox: verify heartbeat never found the stage reader'
# Range 1 skips BOOT_CHAIN bytes before writing anything: liveness must show
# before the first whole percent, with the sink found and still at bytes=0.
grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+ read=[0-9]+ proc=found sectors=[0-9]+ src=proc$' "$bb_log" \
    || fail 'busybox: no write heartbeat DETAIL line'
first_write_line="$(grep -n '^PF_SELF_FLASH_V3_PROGRESS phase=write ' "$bb_log" | head -n1 | cut -d: -f1)"
start_line="$(grep -n '^PF_SELF_FLASH_V3_PROGRESS phase=start ' "$bb_log" | head -n1 | cut -d: -f1)"
sed -n "${start_line},${first_write_line}p" "$bb_log" \
    | grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write .* proc=found sectors=[0-9]+ src=proc$' \
    || fail 'busybox: no heartbeat between start/0 and the first write percent'
if grep -E '^PF_SELF_FLASH_V3_PROGRESS_DETAIL' "$bb_log" | grep -Eq "$marker_re"; then
    fail 'busybox: a DETAIL line matches the automation grammar'
fi

# =====================================================================
# Byte source: the card's written-sector counter in /sys/block/<disk>/stat
# =====================================================================
# The DUT base kernel 8c11370b has no CONFIG_TASK_IO_ACCOUNTING, so
# /proc/<pid>/io never exists there (proc=noio) and the dd's wchar cannot be
# read. The sampler instead counts sectors written to the card itself: field 7
# of /sys/block/<disk>/stat (512-byte sectors), baselined when the sampler
# starts so earlier writes and the verify reads never count. Percent is
#   (written sectors since baseline) * 512 * 100 / SF_V3_TARGET_RAW_BYTES
# over all three ranges ([chain,raw), [spl,chain), [0,spl): together exactly
# TargetRawBytes), capped at 99; the boot-chain ranges 2 and 3 run last and
# carry the percent from ~(raw-chain)/raw up to 99.

# ---- resolver: whole-disk node, partition node, unknown node ----
rsys="$tmp/rsys"; mkdir -p "$rsys/mmcblk0/mmcblk0p1"
printf '1 2 3 4 5 6 7 8 9 10 11\n' >"$rsys/mmcblk0/stat"
printf '1 2 3 4 5 6 7 8 9 10 11\n' >"$rsys/mmcblk0/mmcblk0p1/stat"
[[ "$(SF_V3_SYS_BLOCK="$rsys" sf_v3_progress_stat_path /dev/mmcblk0)" == "$rsys/mmcblk0/stat" ]] \
    || fail 'resolver: whole-disk node /dev/mmcblk0 not mapped to <sys>/mmcblk0/stat'
[[ "$(SF_V3_SYS_BLOCK="$rsys" sf_v3_progress_stat_path /dev/mmcblk0p1)" == "$rsys/mmcblk0/mmcblk0p1/stat" ]] \
    || fail 'resolver: partition node not mapped to <sys>/<disk>/<part>/stat'
if SF_V3_SYS_BLOCK="$rsys" sf_v3_progress_stat_path /dev/sdz >/dev/null 2>&1; then
    fail 'resolver: unknown node resolved'
fi
if SF_V3_SYS_BLOCK="$rsys" sf_v3_progress_stat_path '' >/dev/null 2>&1; then
    fail 'resolver: empty node resolved'
fi
[[ "$(sf_v3_progress_stat "$rsys/mmcblk0/stat")" == '3 7' ]] \
    || fail 'stat parse: expected fields 3 (read sectors) and 7 (written sectors)'
printf 'garbage\n' >"$rsys/mmcblk0/stat"
if sf_v3_progress_stat "$rsys/mmcblk0/stat" >/dev/null 2>&1; then fail 'stat parse accepted garbage'; fi

# ---- real kernel format: parse a live /sys/block/<dev>/stat (read-only) ----
real_stat=
for f in /sys/block/*/stat; do [[ -r "$f" ]] && { real_stat="$f"; break; }; done
[[ -n "$real_stat" ]] || fail 'host has no readable /sys/block/*/stat'
before="$(awk '{print $3, $7}' "$real_stat")"
got="$(sf_v3_progress_stat "$real_stat")" || fail "real stat parse failed: $real_stat"
after="$(awk '{print $3, $7}' "$real_stat")"
read -r b3 b7 <<<"$before"; read -r g3 g7 <<<"$got"; read -r a3 a7 <<<"$after"
(( b3 <= g3 && g3 <= a3 && b7 <= g7 && g7 <= a7 )) \
    || fail "real stat parse disagrees with awk fields 3/7: $before / $got / $after ($real_stat)"
real_name="${real_stat#/sys/block/}"; real_name="${real_name%/stat}"
[[ "$(SF_V3_SYS_BLOCK=/sys/block sf_v3_progress_stat_path "/dev/$real_name")" == "$real_stat" ]] \
    || fail "resolver: real node /dev/$real_name not resolved to $real_stat"

# ---- stand-in kernel for a file-backed card ----
# REAL: the card is a sparse regular file at <tmp>/dev/mmcblk0 opened on fd 9
# exactly as the initrd does (SF_V3_SD_IO=/proc/self/fd/9); the dd processes
# that write it are real (GNU dd on the bash host run, NOEXEC BusyBox dd
# applets on the busybox run); the sampler is the engine's, unmodified.
# STOOD IN: <fakesys>/mmcblk0/stat. A host loop rewrites it every 50 ms
# (atomic rename) with field 7 = PRE + the card file's allocated 512-byte
# blocks (st_blocks: grows as the dd fills holes; the kernel's own counter
# grows at writeback completion instead) and field 3 a fixed read count.
# PRE=1000000 models earlier writes: without the baseline every percent would
# be 99 at once.
probe_card="$tmp/probe.card"; truncate -s 1M "$probe_card"
head -c 65536 /dev/urandom | dd of="$probe_card" bs=32768 conv=notrunc status=none
(( $(stat -c '%b*%B' "$probe_card") >= 65536 )) \
    || fail "st_blocks does not track writes on $(df -T "$tmp" | tail -n1); cannot stand in the sector counter"
rm -f "$probe_card"
fake_kernel() {  # $1 card file  $2 stat dir
    local w
    while :; do
        w=$(( 1000000 + $(stat -c '%b*%B' "$1") / 512 ))
        printf '   10        0     4242      100   200    0 %8s   300    0   400   500\n' "$w" >"$2/stat.new"
        mv -f "$2/stat.new" "$2/stat"
        sleep 0.05
    done
}
sysdisk="$tmp/dev/mmcblk0"; fakesys="$tmp/fakesys"; mkdir -p "$tmp/dev" "$fakesys/mmcblk0"
sys_reset_disk() {
    rm -f "$sysdisk"; truncate -s $((16 * 1024 * 1024)) "$sysdisk"
    find "$work" -mindepth 1 -delete
}
fk_pid=
start_fake_kernel() { fake_kernel "$sysdisk" "$fakesys/mmcblk0" & fk_pid=$!; sleep 0.2; }
stop_fake_kernel() {
    [[ -n "$fk_pid" ]] || return 0
    kill "$fk_pid" 2>/dev/null || :
    wait "$fk_pid" 2>/dev/null || :
    fk_pid=
}
trap 'stop_fake_kernel; cleanup' EXIT

# $1 log, $2 label, $3 expected proc=: write markers increase over 1..99, the
# boot-chain ranges count (max percent past range 1's 77%), DETAIL lines carry
# sectors/src and sectors never exceed TargetRawBytes/512 (baseline taken).
check_sysfs_log() {
    local log="$1" label="$2" p prev=0 max_sect=0 s line
    grep -E '^PF_SELF_FLASH_V3_PROGRESS ' "$log" >"$log.markers" || fail "$label: no markers"
    while IFS= read -r line; do
        [[ "$line" =~ $marker_re ]] || fail "$label: marker violates automation grammar: $line"
    done <"$log.markers"
    head -n1 "$log.markers" | grep -qx 'PF_SELF_FLASH_V3_PROGRESS phase=start percent=0' \
        || fail "$label: first marker is not start/0"
    tail -n1 "$log.markers" | grep -qx 'PF_SELF_FLASH_V3_PROGRESS phase=write-end percent=100' \
        || fail "$label: last marker is not write-end/100"
    mapfile -t sys_writes < <(sed -n 's/^PF_SELF_FLASH_V3_PROGRESS phase=write percent=//p' "$log.markers")
    (( ${#sys_writes[@]} >= 3 )) \
        || fail "$label: expected >=3 write markers from the sector counter, got ${#sys_writes[@]}: $(grep PROGRESS "$log" | head -n 12)"
    for p in "${sys_writes[@]}"; do
        (( p > prev && p < 100 )) || fail "$label: write percent not strictly increasing within 1..99: $p after $prev"
        prev=$p
    done
    (( sys_writes[0] <= 50 )) || fail "$label: first percent ${sys_writes[0]}: earlier writes counted (no baseline)"
    (( prev >= 85 )) || fail "$label: max percent $prev: boot-chain ranges 2/3 not counted toward TargetRawBytes"
    grep -Eq '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+ sectors=[1-9][0-9]* src=sysfs$' "$log" \
        || fail "$label: no write DETAIL line with sectors/src=sysfs"
    grep -Eq "^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write bytes=[0-9]+ total=294912 elapsed_ms=[0-9]+ read=[0-9]+ proc=$3 sectors=[0-9]+ src=sysfs\$" "$log" \
        || fail "$label: no write heartbeat with proc=$3 src=sysfs"
    grep -Eq "^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=verify bytes=0 total=[0-9]+ elapsed_ms=[0-9]+ proc=$3 sectors=0 src=sysfs\$" "$log" \
        || fail "$label: verify heartbeat does not report src=sysfs"
    while read -r s; do
        (( s > max_sect )) && max_sect=$s
    done < <(sed -n 's/^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write .* sectors=\([0-9]*\) src=sysfs$/\1/p' "$log")
    (( max_sect <= 294912 / 512 )) || fail "$label: sectors=$max_sect exceeds TargetRawBytes/512 (baseline not taken)"
    while IFS= read -r line; do
        [[ "$line" =~ bytes=([0-9]+).*sectors=([0-9]+) ]] || continue
        (( BASH_REMATCH[1] == BASH_REMATCH[2] * 512 )) || fail "$label: bytes != sectors*512: $line"
    done < <(grep -E '^PF_SELF_FLASH_V3_PROGRESS_DETAIL phase=write .*src=sysfs$' "$log")
    if grep -E '^PF_SELF_FLASH_V3_PROGRESS_DETAIL' "$log" | grep -Eq "$marker_re"; then
        fail "$label: a DETAIL line matches the automation grammar"
    fi
}

# ---- bash host run: real /proc (proc=found) but sysfs preferred ----
sys_reset_disk
dd if="$xz_good" of="$sysdisk" bs=1 seek="$stage_offset" conv=notrunc status=none
set_contract
exec 9>&-
SF_V3_SD="$sysdisk"; exec 9<>"$SF_V3_SD"
SF_V3_COMPRESSED_BYTES="$(stat -c %s "$xz_good")"
export SF_V3_SD SF_V3_COMPRESSED_BYTES
start_fake_kernel
if SF_V3_BOOT_CHAIN_BYTES=65536 SF_V3_SPL_REGION_BYTES=32768 SF_V3_SYS_BLOCK="$fakesys" \
        sf_v3_stream_write 2>"$tmp/sys.log"; then sys_rc=0; else sys_rc=$?; fi
stop_fake_kernel
(( sys_rc == 0 )) || fail "sysfs: valid stream refused: $(tail -n 5 "$tmp/sys.log")"
cmp -n "$raw_bytes" "$raw" "$sysdisk" || fail 'sysfs: output bytes differ'
[[ -z "$(jobs -r)" ]] || fail 'sysfs: progress sampler left running'
check_sysfs_log "$tmp/sys.log" 'sysfs host' found
host_sys_writes=("${sys_writes[@]}")

# ---- the DUT condition under REAL BusyBox: dd found, NO /proc/<pid>/io ----
# Stood in: /proc (a fake tree with a comm=dd entry holding the card on fd 0/1
# and no io file: the host kernel has io accounting, the DUT kernel has none)
# and /sys/block/mmcblk0/stat (fake_kernel above). Real: busybox ash, its
# NOEXEC dd applets writing the card, the engine's sinks and sampler.
bbproc="$tmp/bbproc"; mkdir -p "$bbproc/4242/fd"
printf 'dd\n' >"$bbproc/4242/comm"
ln -s "$sysdisk" "$bbproc/4242/fd/0"; ln -s "$sysdisk" "$bbproc/4242/fd/1"
sys_reset_disk
dd if="$bb_xz" of="$sysdisk" bs=1 seek="$stage_offset" conv=notrunc status=none
start_fake_kernel
if PF_BB_PROC="$bbproc" PF_BB_SYS_BLOCK="$fakesys" PATH="$emptybin" "$bb" sh "$bb_driver" \
        "$sysdisk" "$stage_offset" "$(stat -c %s "$bb_xz")" "$raw_bytes" "$bb_sha" "$work" \
        2>"$tmp/bbsys.log"; then bbsys_rc=0; else bbsys_rc=$?; fi
stop_fake_kernel
(( bbsys_rc == 0 )) || fail "busybox sysfs run failed: $(tail -n 20 "$tmp/bbsys.log")"
grep -qx 'BB_DRIVER rc=0 write=pass' "$tmp/bbsys.log" || fail "busybox sysfs driver: $(tail -n 5 "$tmp/bbsys.log")"
cmp -n "$raw_bytes" "$bb_raw" "$sysdisk" || fail 'busybox sysfs: output bytes differ'
check_sysfs_log "$tmp/bbsys.log" 'busybox sysfs noio' noio
bbsys_writes=("${sys_writes[@]}")

# ---- a REAL kernel block counter: loop device (needs root; never faked) ----
loop_result=skipped_not_root
if [[ "$(id -u)" == 0 ]] && command -v losetup >/dev/null; then
    loopimg="$tmp/loop.img"; truncate -s 4M "$loopimg"
    loopdev="$(losetup -f --show "$loopimg")" || fail 'losetup failed as root'
    lstat="$(sf_v3_progress_stat_path "$loopdev")" || { losetup -d "$loopdev"; fail "no stat for $loopdev"; }
    read -r _ w0 < <(sf_v3_progress_stat "$lstat")
    head -c 1048576 /dev/urandom | dd of="$loopdev" bs=65536 conv=fsync status=none
    read -r _ w1 < <(sf_v3_progress_stat "$lstat")
    losetup -d "$loopdev"
    (( w1 - w0 >= 2048 )) || fail "loop: written sectors moved $((w1 - w0)), expected >= 2048"
    loop_result=PASS
fi

printf 'SELF_FLASH_V3_PROGRESS_TEST result=PASS writes=%s busybox_writes=%s sysfs_percents=%s busybox_sysfs_percents=%s loop=%s busybox=%s\n' \
    "${#writes[@]}" "${#bb_writes[@]}" "$(IFS=,; echo "${host_sys_writes[*]}")" \
    "$(IFS=,; echo "${bbsys_writes[*]}")" "$loop_result" "$bb"
