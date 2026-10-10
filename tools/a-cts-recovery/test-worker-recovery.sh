#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DUT=$HERE/a-cts-dut
VERIFY=$HERE/verify-results.sh
TMP=$(mktemp -d "${RUNNER_TEMP:-/tmp}/a-cts-worker-recovery.XXXXXX")
trap 'find "$TMP" -mindepth 1 -delete; rmdir "$TMP"' EXIT

fail() {
    printf 'A_CTS_RECOVERY_TEST FAIL step=%s\n' "$1" >&2
    exit 1
}

run_fixture() {
    fixture=$1
    PF_ACTS_SELFTEST=1 PF_ACTS_ROOT="$TMP/$fixture" \
        PF_ACTS_RECOVERY_FIXTURE="$fixture" \
        "$DUT" recovery-selftest >"$TMP/$fixture.out" \
        || fail "$fixture-runner"
    mkdir -p "$TMP/$fixture-unpacked"
    tar -xzf "$TMP/$fixture/results.tar.gz" -C "$TMP/$fixture-unpacked"
    "$VERIFY" "$TMP/$fixture-unpacked" >"$TMP/$fixture.verify" \
        || fail "$fixture-verify"
}

cat >"$TMP/gles-sanity-pass" <<'EOF'
#!/bin/sh
printf 'PF_GLES_SANITY verdict=pass clear=pass texture=pass renderer=zink-powervr\n'
EOF
cat >"$TMP/texcomp-not-sanity" <<'EOF'
#!/bin/sh
printf 'PF_TEXCOMP_RESULT verdict=pass controls_passed=5 controls_required=5\n'
EOF
chmod 0755 "$TMP/gles-sanity-pass" "$TMP/texcomp-not-sanity"
gles_sanity_sha=$(sha256sum "$TMP/gles-sanity-pass" | cut -d' ' -f1)
texcomp_sha=$(sha256sum "$TMP/texcomp-not-sanity" | cut -d' ' -f1)

PF_ACTS_ROOT="$TMP/sanity-pass" PF_ACTS_SANITY_PROBE="$TMP/gles-sanity-pass" \
    PF_ACTS_SANITY_PROBE_SHA="$gles_sanity_sha" \
    "$DUT" sanity-selftest >"$TMP/sanity-pass.out" || fail sanity-positive
grep -qx 'A_CTS_SANITY_SELFTEST verdict=pass instrument=gles-uncompressed' \
    "$TMP/sanity-pass.out" || fail sanity-positive-marker

# A successful texture-compression probe is still not the independent recovery
# instrument: known ETC defects can make that probe fail on a responsive GPU.
set +e
PF_ACTS_ROOT="$TMP/sanity-texcomp" PF_ACTS_SANITY_PROBE="$TMP/texcomp-not-sanity" \
    PF_ACTS_SANITY_PROBE_SHA="$texcomp_sha" \
    "$DUT" sanity-selftest >"$TMP/sanity-texcomp.out" 2>&1
texcomp_rc=$?
set -e
[[ $texcomp_rc -eq 79 ]] || fail texcomp-instrument-exit
grep -qx 'state=sanity_baseline_failed completed=0 total=0 reason=sanity_baseline_failed' \
    "$TMP/sanity-texcomp/state" || fail texcomp-baseline-stop

# Receipt r42 sequence: EGL/context initialization succeeded, the first
# clear/readback failed immediately after the reset, and a later healthy draw
# must allow the next case to run in a fresh process.
run_fixture r42-delayed
grep -qx 'A_CTS_RECOVERY_SELFTEST fixture=r42-delayed crash=1 pass=2 not_run=0 sanity=pass recovery_attempts=2 archive=ready' \
    "$TMP/r42-delayed.out" || fail delayed-marker
grep -q $'^1\t1\tfail\t' "$TMP/r42-delayed-unpacked/recovery-wait.tsv" \
    || fail delayed-first-failure
grep -q $'^2\t2\tpass\t' "$TMP/r42-delayed-unpacked/recovery-wait.tsv" \
    || fail delayed-second-pass
grep -q $'^recovery\tcase.crash\tCrash\t0000\t1$' \
    "$TMP/r42-delayed-unpacked/ledger.tsv" || fail delayed-crash-ledger
grep -q $'^recovery\tcase.after\tPass\t0000\t2$' \
    "$TMP/r42-delayed-unpacked/ledger.tsv" || fail delayed-resumed-next
grep -q 'case=case.crash .*sanity=pass gpu_reset=yes' \
    "$TMP/r42-delayed-unpacked/crash-evidence/recovery/0000-1.txt" \
    || fail delayed-reset-attribution
grep -q $'^recovery\t0000\t1\t1\tcase.crash\t' \
    "$TMP/r42-delayed-unpacked/gpu-reset-events.tsv" \
    || fail delayed-reset-event

PF_ACTS_SELFTEST=1 PF_ACTS_ROOT="$TMP/reset-gates" \
    "$DUT" reset-gate-selftest >"$TMP/reset-gates.out" \
    || fail reset-gates-runner
grep -qx 'A_CTS_RESET_GATE_SELFTEST zero_exit=recovered timeout=recovered empty_qpa=recovered reset_count=3 launches_blocked_until_sanity=yes' \
    "$TMP/reset-gates.out" || fail reset-gates-marker
[[ $(wc -l <"$TMP/reset-gates/gpu-reset-events.tsv") -eq 3 ]] \
    || fail reset-gates-event-count

PF_ACTS_SELFTEST=1 PF_ACTS_ROOT="$TMP/empty-qpa-reset" \
    "$DUT" empty-qpa-reset-selftest >"$TMP/empty-qpa-reset.out" \
    || fail empty-qpa-reset-runner
grep -qx 'A_CTS_EMPTY_QPA_RESET_SELFTEST recovered_matrix=3 exhausted_matrix=3 cap_matrix=3 retry_rc=81 exhausted_rc=77 cap_rc=80 remaining=preserved harness_errors=0' \
    "$TMP/empty-qpa-reset.out" || fail empty-qpa-reset-marker

# A process exit with no reset remains a Crash result but does not consume the
# reset budget or trigger GPU recovery polling.
run_fixture process-exit
grep -q 'signal=PROCESS_EXIT .*sanity=unknown gpu_reset=no' \
    "$TMP/process-exit-unpacked/crash-evidence/recovery/0000-1.txt" \
    || fail process-exit-classification
[[ ! -s $TMP/process-exit-unpacked/recovery-wait.tsv ]] \
    || fail process-exit-false-recovery

# Negative control: all five bounded checks fail, so the run stops only after
# retaining every retry and finalizing the untouched suffix as NotRun.
run_fixture unrecoverable
grep -qx 'A_CTS_RECOVERY_SELFTEST fixture=unrecoverable crash=1 pass=1 not_run=1 sanity=fail recovery_attempts=5 archive=ready' \
    "$TMP/unrecoverable.out" || fail exhausted-marker
[[ $(wc -l <"$TMP/unrecoverable-unpacked/recovery-wait.tsv") -eq 5 ]] \
    || fail exhausted-attempt-count
grep -q $'^recovery\tcase.after\tNotRun\tfinalize\t0$' \
    "$TMP/unrecoverable-unpacked/ledger.tsv" || fail exhausted-not-run

# Negative control: the per-boot reset-case cap is explicit and produces a
# verified partial archive without running another health probe.
run_fixture reset-cap
grep -qx 'A_CTS_RECOVERY_SELFTEST fixture=reset-cap crash=1 pass=1 not_run=1 sanity=unknown reset_count=64 reset_cap=64 archive=ready' \
    "$TMP/reset-cap.out" || fail cap-marker
grep -qx 'outcome=partial reason=reset_budget_exhausted completed=2 total=3' \
    "$TMP/reset-cap-unpacked/run-outcome.txt" || fail cap-outcome

PF_ACTS_SELFTEST=1 "$DUT" recovery-reason-selftest \
    >"$TMP/recovery-reasons.out" || fail typed-stop-reasons
grep -qx 'A_CTS_RECOVERY_REASON_SELFTEST rc77=gpu_unrecoverable rc80=reset_budget_exhausted rc76=worker_rc_76' \
    "$TMP/recovery-reasons.out" || fail typed-stop-reason-marker

grep -qx 'A_CTS_RECOVERY_RULE reset_case_cap=64 observed_rate=1/68 projected_full=43 retry_delays_s=1,2,4,8,15 probe_timeout_s=10 recovery_window_s=105 baseline=required stop=sanity_baseline_failed_or_retry_exhausted_or_reset_cap wall_clock=existing_list_budget' \
    "$TMP/r42-delayed-unpacked/recovery-policy.txt" || fail policy

printf 'A_CTS_RECOVERY_TEST PASS sanity_baseline=yes texcomp_rejected=yes r42_first_draw=fail delayed_draw=pass resumed_next=yes process_exit_separate=yes zero_exit_reset=recovered timeout_reset=recovered empty_qpa_reset=recovered empty_qpa_matrix=yes retry_exhaustion=yes reset_cap=64 typed_stop_reasons=yes archives_verified=yes\n'
