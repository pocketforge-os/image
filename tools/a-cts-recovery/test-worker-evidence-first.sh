#!/usr/bin/env bash
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${RUNNER_TEMP:-/tmp}/a-cts-evidence-first-test.XXXXXX")
cleanup() {
    find "$TMP" -mindepth 1 -delete
    rmdir "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'A_CTS_EVIDENCE_FIRST_TEST FAIL step=%s\n' "$1" >&2
    exit 1
}

make_fixture() {
    fixture=$1
    evidence_status=$2
    pc=$3
    module_offset=$4
    root=$fixture/worker-run
    label=a5b-recovery-cases-r43.txt
    crash_case=dEQP-GLES3.functional.shaders.derivate.dfdx.fbo_msaa2.vec2_mediump
    mkdir -p "$root/nonpass-qpa/$label" "$root/crash-evidence/$label" \
        "$root/gpu-reset-events/$label" "$root/harness-evidence" \
        "$root/recovery-sanity"
    cp "$KIT/a-cts-dut" "$root/a-cts-dut"
    chmod 0755 "$root/a-cts-dut"
    : >"$root/harness-errors.tsv"
    : >"$root/recovery-wait.tsv"

    for n in $(seq 1 2938); do
        if [[ $n -eq 447 ]]; then
            printf '%s\t%s\n' "$label" "$crash_case"
        else
            printf '%s\tcase.%04d\n' "$label" "$n"
        fi
    done >"$root/expected.tsv"
    for n in $(seq 1 446); do
        printf '%s\tcase.%04d\tPass\t0004\t1\n' "$label" "$n"
    done >"$root/ledger.tsv"
    printf '%s\t%s\tCrash\t0004\t2\n' "$label" "$crash_case" >>"$root/ledger.tsv"

    qpa="$root/nonpass-qpa/$label/0004-2.qpa"
    printf '#beginTestCaseResult %s\n<Text>Watchdog timer timeout for touch interval</Text>\n' \
        "$crash_case" >"$qpa"
    qpa_sha=$(sha256sum "$qpa" | cut -d' ' -f1)
    printf '%s\t0004\t2\t%s\n' "$label" "$qpa_sha" >"$root/qpa-manifest.tsv"

    evidence="$root/crash-evidence/$label/0004-2.txt"
    dmesg="$root/crash-evidence/$label/0004-2.dmesg"
    first_reset="$root/crash-evidence/$label/0004-2.first-reset"
    printf 'A_CTS_CRASH case=%s signal=SIGKILL exit_code=137 started=2026-10-10T08:33:00Z ended=2026-10-10T08:33:31Z sanity=pass gpu_reset=yes\nA_CTS_CRASH_PC address=%s module_offset=%s\n' \
        "$crash_case" "$pc" "$module_offset" >"$evidence"
    cat >"$dmesg" <<'DMESG'
[ 2900.000000] powervr 1800000.gpu: [drm] Reset reason=1 (Guilty lockup)
[ 2900.010000] powervr 1800000.gpu: [drm] Data Master=3 (Fragment)
DMESG
    sed -n '1p' "$dmesg" >"$first_reset"
    evidence_bytes=$(wc -c <"$evidence")
    evidence_sha=$(sha256sum "$evidence" | cut -d' ' -f1)
    dmesg_bytes=$(wc -c <"$dmesg")
    dmesg_sha=$(sha256sum "$dmesg" | cut -d' ' -f1)
    first_reset_bytes=$(wc -c <"$first_reset")
    first_reset_sha=$(sha256sum "$first_reset" | cut -d' ' -f1)
    printf '%s\t%s\tSIGKILL\t%s\t%s\t0004\t2\t%s\t%s\t2026-10-10T08:33:00Z\t2026-10-10T08:33:31Z\tpass\t%s\t%s\tyes\t%s\t%s\t%s\n' \
        "$label" "$crash_case" "$pc" "$module_offset" "$evidence_bytes" \
        "$evidence_sha" "$dmesg_bytes" "$dmesg_sha" "$first_reset_bytes" \
        "$first_reset_sha" "$evidence_status" >"$root/crash-evidence.tsv"

    cp "$dmesg" "$root/gpu-reset-events/$label/0004-2.dmesg"
    printf '%s\t0004\t2\t7\t%s\t2026-10-10T08:33:00Z\t2026-10-10T08:33:31Z\t%s\t%s\n' \
        "$label" "$crash_case" "$dmesg_bytes" "$dmesg_sha" >"$root/gpu-reset-events.tsv"
    printf 'PF_GLES_SANITY verdict=pass clear=pass texture=pass renderer=zink-powervr\n' \
        >"$root/recovery-sanity/baseline.stdout"
    : >"$root/recovery-sanity/baseline.stderr"
    printf 'A_CTS_RECOVERY_SANITY list=baseline unit=baseline attempt=0 user=gamer uid=1000 started=2026-10-10T07:52:00Z ended=2026-10-10T07:52:01Z rc=0 verdict=pass probe_sha256=fixture\n' \
        >"$root/recovery-sanity/baseline.result"
    printf '[ 2900.000000] powervr fixture dmesg\n' >"$fixture/dmesg.fixture"
}

incomplete=$TMP/incomplete
make_fixture "$incomplete" crash_evidence_incomplete unknown unknown
set +e
PF_ACTS_ROOT="$incomplete/worker-run" PF_ACTS_DMESG_FIXTURE="$incomplete/dmesg.fixture" \
    "$incomplete/worker-run/a-cts-dut" finalize-partial worker_rc_137 \
    >"$incomplete/finalize.out" 2>&1
finalize_rc=$?
set -e
[[ $finalize_rc -eq 0 ]] || {
    cat "$incomplete/finalize.out" >&2
    fail incomplete_finalize
}
[[ -s $incomplete/worker-run/results.tar.gz ]] || fail incomplete_archive
mkdir -p "$incomplete/unpacked"
tar -xzf "$incomplete/worker-run/results.tar.gz" -C "$incomplete/unpacked"
[[ $(awk -F '\t' '$3!="NotRun" { n++ } END { print n+0 }' "$incomplete/unpacked/ledger.tsv") -eq 447 ]] \
    || fail completed_cases_retained
[[ $(wc -l <"$incomplete/unpacked/ledger.tsv") -eq 2938 ]] || fail total_cases_retained
awk -F '\t' '$2=="dEQP-GLES3.functional.shaders.derivate.dfdx.fbo_msaa2.vec2_mediump" && \
    $18=="crash_evidence_incomplete" { found=1 } END { exit !found }' \
    "$incomplete/unpacked/crash-evidence.tsv" || fail incomplete_status_archived
set +e
"$KIT/verify-results.sh" "$incomplete/unpacked" >"$incomplete/verify.out" 2>&1
verify_rc=$?
set -e
[[ $verify_rc -ne 0 ]] || fail incomplete_verdict_fail_closed
grep -qx 'A_CTS_VERIFY FAIL outcome=partial verdict=invalid reason=crash_evidence_incomplete cases=1 evidence=verified final_match=yes qpa_match=yes' \
    "$incomplete/verify.out" || fail incomplete_verdict_marker

tampered=$TMP/tampered
mkdir -p "$tampered"
tar -xzf "$incomplete/worker-run/results.tar.gz" -C "$tampered"
printf 'tamper\n' >>"$tampered/crash-evidence/a5b-recovery-cases-r43.txt/0004-2.dmesg"
set +e
"$KIT/verify-results.sh" "$tampered" >"$tampered/verify.out" 2>&1
tampered_rc=$?
set -e
[[ $tampered_rc -ne 0 ]] || fail tampered_verdict
grep -q 'reason=crash_dmesg_size case=dEQP-GLES3.functional.shaders.derivate.dfdx.fbo_msaa2.vec2_mediump' \
    "$tampered/verify.out" || fail tampered_integrity_reason
! grep -q 'evidence=verified' "$tampered/verify.out" || fail tampered_not_verified

complete=$TMP/complete
make_fixture "$complete" complete kernel-log powervr-reset
PF_ACTS_ROOT="$complete/worker-run" PF_ACTS_DMESG_FIXTURE="$complete/dmesg.fixture" \
    "$complete/worker-run/a-cts-dut" finalize-partial worker_rc_137 \
    >"$complete/finalize.out" 2>&1 || fail complete_finalize
mkdir -p "$complete/unpacked"
tar -xzf "$complete/worker-run/results.tar.gz" -C "$complete/unpacked"
"$KIT/verify-results.sh" "$complete/unpacked" >"$complete/verify.out" \
    || fail complete_host_verify
grep -q '^A_CTS_VERIFY PASS outcome=partial expected=2938 ' "$complete/verify.out" \
    || fail complete_pass_marker

archive_sha_line=$(grep -n 'sha256sum "$R/results/results.tar.gz"' \
    "$KIT/direct-boot.sh" | cut -d: -f1)
host_verify_line=$(grep -n '"$K/verify-results.sh" "$R/results/unpacked"' \
    "$KIT/direct-boot.sh" | cut -d: -f1)
verdict_line=$(grep -n 'worker-verdict-invalid.*evidence=collected' \
    "$KIT/direct-boot.sh" | cut -d: -f1)
[[ -n $archive_sha_line && -n $host_verify_line && -n $verdict_line ]] \
    || fail collection_order_markers
[[ $archive_sha_line -lt $host_verify_line && $host_verify_line -lt $verdict_line ]] \
    || fail collection_before_verdict_order

printf 'A_CTS_EVIDENCE_FIRST_TEST PASS sequence=r43 completed=447 total=2938 archive=before-verdict incomplete=typed verdict=fail-closed tamper=rejected complete=accepted\n'
