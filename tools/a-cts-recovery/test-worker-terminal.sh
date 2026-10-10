#!/usr/bin/env bash
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${RUNNER_TEMP:-/tmp}/a-cts-terminal-test.XXXXXX")
supervisor_pid=
mutator_pid=
cleanup() {
    if [[ -n $mutator_pid ]] && kill -0 "$mutator_pid" 2>/dev/null; then
        kill -KILL "$mutator_pid"
    fi
    if [[ -n $supervisor_pid ]] && kill -0 "$supervisor_pid" 2>/dev/null; then
        kill -TERM "$supervisor_pid"
    fi
    find "$TMP" -mindepth 1 -delete
    rmdir "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'A_CTS_TERMINAL_TEST FAIL step=%s\n' "$1" >&2
    exit 1
}

control=$TMP/control
root=$control/worker-run
mkdir -p "$root"
cp "$KIT/a-cts-dut" "$root/a-cts-dut"
chmod 0755 "$root/a-cts-dut"
: >"$root/ledger.tsv"
: >"$root/qpa-manifest.tsv"
: >"$root/crash-evidence.tsv"
: >"$root/harness-errors.tsv"
for n in $(seq 1 2938); do
    printf 'a5b-recovery-cases-r26.txt\tcase.%04d\n' "$n"
done >"$root/expected.tsv"
printf '[    1.000000] powervr terminal fixture: healthy\n' >"$control/dmesg.fixture"

PF_ACTS_ROOT="$root" PF_ACTS_WORKER_FIXTURE=r41 \
    PF_ACTS_R41_FINALIZE_DELAY=2 PF_ACTS_CONTROL_DIRECT=1 \
    PF_ACTS_DMESG_FIXTURE="$control/dmesg.fixture" \
    "$root/a-cts-dut" worker-launch >"$control/supervisor.outer" 2>&1

for _ in $(seq 1 50); do
    [[ -s $root/state ]] && break
    sleep 0.1
done
[[ -s $root/state ]] || fail r41_fixture_state
[[ -s $root/worker.pid && -s $root/worker.pgid ]] || fail worker_identity
supervisor_pid=$(<"$root/worker.pid")
[[ $(<"$root/worker.pgid") == "$supervisor_pid" ]] || fail isolated_process_group
grep -qx 'state=finalizing reason=harness_stop list=a5b-recovery-cases-r26.txt unit=0000 attempt=39 rc=0 commit_rc=76' \
    "$root/state" || fail r41_fixture_progress
awk -F '\t' '$1=="a5b-recovery-cases-r26.txt" && $2=="0000" && $3==39 && \
    $4==0 && $5=="no" && $6==0 && $7=="case.0001" && length($8)==64 && \
    length($9)==64 && length($10)==64 { found=1 } END { exit !found }' \
    "$root/harness-errors.tsv" || fail rc0_empty_qpa_evidence

PF_ACTS_ROOT="$control" PF_ACTS_CONTROL_DIRECT=1 \
    "$root/a-cts-dut" worker-poll >"$control/poll.out"
grep -qx 'A_CTS_SANITY_BASELINE verdict=pass instrument=gles-uncompressed user=gamer uid=1000' \
    "$control/poll.out" || fail sanity_receipt
grep -qx 'A_CTS_PROGRESS state=running worker=alive worker_state=finalizing reason=harness_stop list=a5b-recovery-cases-r26.txt unit=0000 attempt=39 rc=0 commit_rc=76' \
    "$control/poll.out" || fail live_progress_normalized

started=$SECONDS
PF_ACTS_ROOT="$control" PF_ACTS_CONTROL_DIRECT=1 PF_ACTS_FINALIZE_WAIT_SECONDS=20 \
    PF_ACTS_DMESG_FIXTURE="$control/dmesg.fixture" \
    "$root/a-cts-dut" worker-finalize >"$control/finalize.out"
elapsed=$((SECONDS - started))
[[ $elapsed -lt 20 ]] || fail finalize_bound
grep -Eq '^A_CTS_WORKER_FINALIZE state=ready outcome=partial .* waited=yes terminated=no$' \
    "$control/finalize.out" || fail finalize_waited

for _ in $(seq 1 50); do
    [[ -s $root/worker.exit ]] && break
    sleep 0.1
done
[[ -s $root/worker.exit ]] || fail supervisor_exit_missing
supervisor_rc=$(sed -n 's/^exit_code=//p' "$root/worker.exit")
supervisor_pid=
[[ $supervisor_rc -eq 76 ]] || fail supervisor_exit

PF_ACTS_ROOT="$control" "$root/a-cts-dut" archive-receipt >"$control/receipt.out"
sha_line=$("$KIT/response-select" terminal-sha '^sha256=[0-9a-f]{64}$' "$control/receipt.out") \
    || fail receipt_sha
bytes_line=$("$KIT/response-select" terminal-bytes '^bytes=[0-9]+$' "$control/receipt.out") \
    || fail receipt_bytes
archive_sha=${sha_line#sha256=}
archive_bytes=${bytes_line#bytes=}
chunks=$(((archive_bytes + 35999) / 36000))
: >"$control/collected.tar.gz"
for ((index=0; index<chunks; index++)); do
    PF_ACTS_ROOT="$control" "$root/a-cts-dut" archive-chunk "$index" \
        >"$control/chunk-$index.stdout"
    "$KIT/collect-response-chunk" "terminal-chunk-$index" \
        "$control/chunk-$index.stdout" "$control/chunk-$index.bin" \
        >"$control/chunk-$index.result" || fail chunk_verify
    cat "$control/chunk-$index.bin" >>"$control/collected.tar.gz"
done
[[ $(wc -c <"$control/collected.tar.gz") == "$archive_bytes" ]] || fail archive_bytes
[[ $(sha256sum "$control/collected.tar.gz" | cut -d' ' -f1) == "$archive_sha" ]] \
    || fail archive_sha
mkdir -p "$control/unpacked"
tar -xzf "$control/collected.tar.gz" -C "$control/unpacked"
"$KIT/verify-results.sh" "$control/unpacked" >"$control/verify.out" || fail host_verify
grep -q '^A_CTS_VERIFY PASS outcome=partial expected=2938 ' "$control/verify.out" \
    || fail host_verify_marker
[[ $(wc -l <"$control/unpacked/ledger.tsv") -eq 2938 ]] || fail ledger_total
[[ $(awk -F '\t' '$3=="NotRun" { n++ } END { print n+0 }' "$control/unpacked/ledger.tsv") -eq 2938 ]] \
    || fail not_run_total
grep -qx 'A_CTS_SANITY_BASELINE verdict=pass instrument=gles-uncompressed user=gamer uid=1000' \
    "$control/unpacked/recovery-sanity/baseline.summary" || fail sanity_archived

cat >"$control/dmesg.before" <<'DMESG_BEFORE'
[    1.000000] old one
[    2.000000] old two
[    3.000000] boundary
DMESG_BEFORE
cp "$control/dmesg.before" "$control/dmesg.unchanged"
cat >"$control/dmesg.rotated" <<'DMESG_ROTATED'
[    2.000000] old two
[    3.000000] boundary
[    4.000000] new reset evidence
DMESG_ROTATED
PF_ACTS_ROOT="$root" PF_ACTS_SELFTEST=1 \
    PF_ACTS_DMESG_BEFORE="$control/dmesg.before" \
    PF_ACTS_DMESG_AFTER="$control/dmesg.unchanged" \
    PF_ACTS_DMESG_OUTPUT="$control/dmesg.empty" \
    "$root/a-cts-dut" selftest-dmesg-delta >/dev/null || fail dmesg_unchanged_call
[[ ! -s $control/dmesg.empty ]] || fail dmesg_unchanged_control
PF_ACTS_ROOT="$root" PF_ACTS_SELFTEST=1 \
    PF_ACTS_DMESG_BEFORE="$control/dmesg.before" \
    PF_ACTS_DMESG_AFTER="$control/dmesg.rotated" \
    PF_ACTS_DMESG_OUTPUT="$control/dmesg.delta" \
    "$root/a-cts-dut" selftest-dmesg-delta >/dev/null || fail dmesg_rotation_call
grep -qx '\[    4.000000\] new reset evidence' "$control/dmesg.delta" \
    || fail dmesg_equal_count_rotation

mutator=$TMP/mutator
mutator_root=$mutator/worker-run
mkdir -p "$mutator_root"
cp "$KIT/a-cts-dut" "$mutator_root/a-cts-dut"
chmod 0755 "$mutator_root/a-cts-dut"
: >"$mutator_root/ledger.tsv"
: >"$mutator_root/qpa-manifest.tsv"
: >"$mutator_root/crash-evidence.tsv"
: >"$mutator_root/harness-errors.tsv"
printf 'fixture-list.txt\tcase.mutator\n' >"$mutator_root/expected.tsv"
PF_ACTS_ROOT="$mutator_root" PF_ACTS_WORKER_FIXTURE=mutator \
    PF_ACTS_CONTROL_DIRECT=1 PF_ACTS_DMESG_FIXTURE="$control/dmesg.fixture" \
    "$mutator_root/a-cts-dut" worker-launch >/dev/null
for _ in $(seq 1 50); do
    [[ -s $mutator_root/mutator.pid && -s $mutator_root/mutations ]] && break
    sleep 0.1
done
[[ -s $mutator_root/mutator.pid && -s $mutator_root/mutations ]] || fail mutator_started
mutator_pid=$(<"$mutator_root/mutator.pid")
mutator_supervisor=$(<"$mutator_root/worker.pid")
kill -TERM "$mutator_supervisor"
for _ in $(seq 1 50); do
    [[ -s $mutator_root/worker.exit ]] && break
    sleep 0.1
done
[[ -s $mutator_root/worker.exit ]] || fail mutator_supervisor_exit
PF_ACTS_ROOT="$mutator" PF_ACTS_CONTROL_DIRECT=1 \
    "$mutator_root/a-cts-dut" worker-poll >"$mutator/poll.out" || fail orphan_poll
grep -qx 'A_CTS_PROGRESS state=running worker=alive worker_state=finalizing reason=fixture_mutator' \
    "$mutator/poll.out" || fail process_group_source_of_truth
PF_ACTS_ROOT="$mutator" PF_ACTS_CONTROL_DIRECT=1 \
    PF_ACTS_FINALIZE_WAIT_SECONDS=0 PF_ACTS_TERM_GRACE_SECONDS=1 \
    PF_ACTS_DMESG_FIXTURE="$control/dmesg.fixture" \
    "$mutator_root/a-cts-dut" worker-finalize >"$mutator/finalize.out" || fail mutator_finalize
kill -0 "$mutator_pid" 2>/dev/null && fail mutator_survived_finalize
mutation_bytes=$(wc -c <"$mutator_root/mutations")
sleep 0.2
[[ $(wc -c <"$mutator_root/mutations") -eq $mutation_bytes ]] || fail mutation_after_archive
grep -Eq '^A_CTS_WORKER_FINALIZE state=ready outcome=partial .* waited=yes terminated=yes$' \
    "$mutator/finalize.out" || fail mutator_finalize_marker

printf 'A_CTS_TERMINAL_TEST PASS r41=reenacted label=fresh-request attempt=in-boot-39 commit_rc=76 empty_qpa=evidence live_state=running finalize=bounded sanity=receipt archive=host-verified dmesg=rotation-safe process_tree=stopped total=2938\n'
