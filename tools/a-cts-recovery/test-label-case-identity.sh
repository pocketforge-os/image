#!/usr/bin/env bash
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d "${RUNNER_TEMP:-/tmp}/a-cts-label-case-test.XXXXXX")
cleanup() {
    find "$TMP" -mindepth 1 -delete
    rmdir "$TMP"
}
trap cleanup EXIT

fail() {
    printf 'A_CTS_LABEL_CASE_TEST FAIL step=%s\n' "$1" >&2
    exit 1
}

root=$TMP/positive
mkdir -p "$root"
set +e
PF_ACTS_ROOT="$root" PF_ACTS_SELFTEST=1 \
    "$KIT/a-cts-dut" label-case-selftest >"$TMP/positive.out" 2>&1
positive_rc=$?
set -e
if [[ $positive_rc -ne 0 ]]; then
    grep -Fq 'reason=duplicate_result' "$TMP/positive.out" \
        || fail "positive_rc_${positive_rc}_without_duplicate_result"
    grep -F 'reason=duplicate_result' "$TMP/positive.out" >&2
    printf 'A_CTS_LABEL_CASE_TEST FAIL step=cross_label_duplicate_result worker_rc=%s\n' \
        "$positive_rc" >&2
    exit 1
fi
grep -Fq 'A_CTS_LABEL_CASE_SELFTEST PASS b1_controls=committed b1_crash=committed reset=target-attributed decision=reject b2=prerequisite-gated matrix=prerequisite-gated archive=ready' \
    "$TMP/positive.out" || fail positive_marker
grep -Fxq $'B1\tdecision=reject\treason=candidate_target_reset' \
    "$root/r49-decisions.tsv" || fail b1_reject
awk -F '\t' '$1=="B1" && $3=="Pass" { pass++ } $1=="B1" && $3=="Crash" { crash++ } END { exit !(pass==2 && crash==1) }' \
    "$root/ledger.tsv" || fail b1_rows
awk -F '\t' '$1=="B1" && $5=="dEQP-GLES3.functional.texture.shadow.depth24_stencil8" { found=1 } END { exit !found }' \
    "$root/gpu-reset-events.tsv" || fail target_reset
for label in B2 MATRIX; do
    awk -F '\t' -v label="$label" '$1==label && $3=="NotRun" && $4=="prerequisite" { found=1 } END { exit !found }' \
        "$root/ledger.tsv" || fail "${label}_not_prerequisite_gated"
done

mkdir -p "$TMP/unpacked"
tar -xzf "$root/results.tar.gz" -C "$TMP/unpacked"
"$KIT/verify-results.sh" "$TMP/unpacked" >"$TMP/verify.out" \
    || { cat "$TMP/verify.out" >&2; fail archive_verify; }
grep -Fq 'A_CTS_VERIFY PASS outcome=complete expected=8 nonpass=3 final_match=yes qpa_match=yes crash_evidence=1' \
    "$TMP/verify.out" || fail verifier_marker

duplicate=$TMP/same-label
mkdir -p "$duplicate"
set +e
PF_ACTS_ROOT="$duplicate" PF_ACTS_SELFTEST=1 \
    "$KIT/a-cts-dut" same-label-duplicate-selftest >"$TMP/duplicate.out" 2>&1
duplicate_rc=$?
set -e
[[ $duplicate_rc -eq 1 ]] || fail same_label_duplicate_rc
grep -Fq 'reason=duplicate_result case=case.same' "$TMP/duplicate.out" \
    || fail same_label_duplicate_not_rejected

printf 'A_CTS_LABEL_CASE_TEST PASS identity=label+case repeated_case=accepted same_label_duplicate=rejected b1=reject prerequisite_skips=typed archive=verified\n'
