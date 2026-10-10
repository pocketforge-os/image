#!/usr/bin/env bash
set -euo pipefail

ROOT=${1:?unpacked A-CTS result directory}
fail() { printf 'A_CTS_VERIFY FAIL %s\n' "$*" >&2; exit 1; }
for file in expected.tsv ledger.tsv precondition.txt worker-environment.txt recovery-policy.txt run-outcome.txt dmesg.full final.txt state; do
    [[ -s "$ROOT/$file" ]] || fail "reason=missing_file file=$file"
done
for file in qpa-manifest.tsv crash-evidence.tsv harness-errors.tsv; do
    [[ -f "$ROOT/$file" ]] || fail "reason=missing_file file=$file"
done
grep -q '^GL_VERSION ' "$ROOT/precondition.txt" || fail reason=gl_version_missing
grep -q '^GL_EXTENSIONS ' "$ROOT/precondition.txt" || fail reason=gl_extensions_missing
outcome=$(sed -n 's/^outcome=\([^ ]*\).*/\1/p' "$ROOT/run-outcome.txt")
case "$outcome" in
    complete|complete_with_harness_error)
        grep -q 'OpenGL ES 3\.2' "$ROOT/precondition.txt" || fail reason=gl_version_not_es32
        ;;
    partial) ;;
    *) fail reason=run_outcome ;;
esac
grep -qx 'A_CTS_RECOVERY_RULE recoverable_crash_cap=none baseline=required stop=sanity_baseline_failed_or_first_failed_post_crash_draw wall_clock=existing_list_budget' \
    "$ROOT/recovery-policy.txt" || fail reason=recovery_policy
for line in \
    'RUN_AS=gamer' \
    'EGL_PLATFORM=surfaceless' \
    'MESA_LOADER_DRIVER_OVERRIDE=unset' \
    'VK_DRIVER_FILES=loader-discovery:/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json' \
    'VK_ICD_FILENAMES=unset' \
    'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1'; do
    grep -Fxq "$line" "$ROOT/worker-environment.txt" \
        || fail "reason=worker_environment line=$line"
done

expected=$(wc -l <"$ROOT/expected.tsv")
actual=$(wc -l <"$ROOT/ledger.tsv")
[[ $expected -eq $actual ]] || fail "reason=unseen expected=$expected actual=$actual"
awk -F '\t' '$3!="Pass" && $3!="Fail" && $3!="NotSupported" && $3!="Crash" && $3!="NotRun" { bad=1 } END { exit bad }' \
    "$ROOT/ledger.tsv" || fail reason=ledger_status
awk -F '\t' '
    NR==FNR { expected[$1 FS $2]=1; next }
    { key=$1 FS $2; if (!(key in expected)) unknown=1; if (++seen[key] > 1) duplicate=1 }
    END { if (unknown) exit 2; if (duplicate) exit 3 }
' "$ROOT/expected.tsv" "$ROOT/ledger.tsv" || fail reason=duplicate_or_unknown

while IFS=$'\t' read -r label case_name status unit attempt; do
    [[ $status == Pass ]] && continue
    qpa="$ROOT/nonpass-qpa/$label/$unit-$attempt.qpa"
    [[ -f $qpa ]] || fail "reason=nonpass_qpa_missing case=$case_name"
    manifest_sha=$(awk -F '\t' -v l="$label" -v u="$unit" -v a="$attempt" \
        '$1==l && $2==u && $3==a { print $4; exit }' "$ROOT/qpa-manifest.tsv")
    [[ -n $manifest_sha ]] || fail "reason=qpa_manifest_missing case=$case_name"
    [[ $(sha256sum "$qpa" | cut -d' ' -f1) == "$manifest_sha" ]] \
        || fail "reason=qpa_sha_mismatch case=$case_name"
done <"$ROOT/ledger.tsv"

crash_count=$(awk -F '\t' '$3=="Crash" { n++ } END { print n+0 }' "$ROOT/ledger.tsv")
evidence_count=$(wc -l <"$ROOT/crash-evidence.tsv")
[[ $crash_count -eq $evidence_count ]] || fail reason=crash_evidence_count
if [[ $outcome == complete || $outcome == complete_with_harness_error || $crash_count -gt 0 ]]; then
    [[ -s $ROOT/recovery-sanity/baseline.result ]] || fail reason=sanity_baseline_missing
    grep -q ' verdict=pass ' "$ROOT/recovery-sanity/baseline.result" \
        || fail reason=sanity_baseline_failed
fi
while IFS=$'\t' read -r label case_name signal pc module_offset unit attempt bytes sha started ended sanity dmesg_bytes dmesg_sha gpu_reset first_reset_bytes first_reset_sha; do
    [[ -n $case_name ]] || continue
    awk -F '\t' -v l="$label" -v c="$case_name" -v u="$unit" -v a="$attempt" \
        '$1==l && $2==c && $3=="Crash" && $4==u && $5==a { found=1 } END { exit !found }' \
        "$ROOT/ledger.tsv" || fail "reason=crash_evidence_orphan case=$case_name"
    case "$signal" in SIG*|GPU_RESET|PROCESS_EXIT) ;; *) fail "reason=crash_signal_missing case=$case_name" ;; esac
    case "$pc" in 0x*|kernel-log|qpa-active) ;; *) fail "reason=crash_pc_missing case=$case_name" ;; esac
    [[ $module_offset != unknown ]] || fail "reason=crash_module_offset_missing case=$case_name"
    evidence="$ROOT/crash-evidence/$label/$unit-$attempt.txt"
    [[ -f $evidence ]] || fail "reason=crash_evidence_missing case=$case_name"
    [[ $bytes -le 4096 && $(wc -c <"$evidence") -eq $bytes ]] \
        || fail "reason=crash_evidence_size case=$case_name"
    [[ $(sha256sum "$evidence" | cut -d' ' -f1) == "$sha" ]] \
        || fail "reason=crash_evidence_sha case=$case_name"
    dmesg_evidence="$ROOT/crash-evidence/$label/$unit-$attempt.dmesg"
    [[ -f $dmesg_evidence ]] || fail "reason=crash_dmesg_missing case=$case_name"
    [[ $(wc -c <"$dmesg_evidence") -eq $dmesg_bytes ]] \
        || fail "reason=crash_dmesg_size case=$case_name"
    [[ $(sha256sum "$dmesg_evidence" | cut -d' ' -f1) == "$dmesg_sha" ]] \
        || fail "reason=crash_dmesg_sha case=$case_name"
    case "$gpu_reset" in yes|no) ;; *) fail "reason=crash_gpu_reset case=$case_name" ;; esac
    first_reset="$ROOT/crash-evidence/$label/$unit-$attempt.first-reset"
    [[ -f $first_reset ]] || fail "reason=crash_first_reset_missing case=$case_name"
    [[ $(wc -c <"$first_reset") -eq $first_reset_bytes ]] \
        || fail "reason=crash_first_reset_size case=$case_name"
    [[ $(sha256sum "$first_reset" | cut -d' ' -f1) == "$first_reset_sha" ]] \
        || fail "reason=crash_first_reset_sha case=$case_name"
    if [[ $gpu_reset == yes ]]; then
        [[ $(cat "$first_reset") != none ]] || fail "reason=crash_first_reset_empty case=$case_name"
    else
        [[ $(cat "$first_reset") == none ]] || fail "reason=crash_false_reset_line case=$case_name"
    fi
    case "$sanity" in pass|fail|unknown) ;; *) fail "reason=crash_sanity case=$case_name" ;; esac
done <"$ROOT/crash-evidence.tsv"

if [[ $outcome == complete && -s $ROOT/harness-errors.tsv ]]; then fail reason=harness_errors; fi

computed=$(mktemp "${RUNNER_TEMP:-/tmp}/a-cts-final.XXXXXX")
trap 'find "$computed" -maxdepth 0 -type f -delete' EXIT
: >"$computed"
cut -f1 "$ROOT/expected.tsv" | awk '!seen[$0]++' | while IFS= read -r label; do
    awk -F '\t' -v label="$label" '
        $1==label { c[$3]++; total++ }
        END { printf "A_CTS_LIST list=%s Pass=%d Fail=%d NotSupported=%d Crash=%d NotRun=%d Total=%d unseen=0 HarnessErrors=%d\n",label,c["Pass"],c["Fail"],c["NotSupported"],c["Crash"],c["NotRun"],total,harness }
    ' harness="$(awk -F '\t' -v label="$label" '$1==label { n++ } END { print n+0 }' "$ROOT/harness-errors.tsv")" "$ROOT/ledger.tsv"
done >>"$computed"
awk -F '\t' '
    { c[$3]++; total++ }
    END { printf "A_CTS_FINAL Pass=%d Fail=%d NotSupported=%d Crash=%d NotRun=%d Total=%d unseen=0 HarnessErrors=%d\n",c["Pass"],c["Fail"],c["NotSupported"],c["Crash"],c["NotRun"],total,harness }
' harness="$(wc -l <"$ROOT/harness-errors.tsv")" "$ROOT/ledger.tsv" >>"$computed"
cmp -s "$computed" "$ROOT/final.txt" || fail reason=final_mismatch
grep -Eq '^state=(complete|complete_with_harness_error|aggregating|partial) ' "$ROOT/state" || fail reason=state_not_complete
printf 'A_CTS_VERIFY PASS outcome=%s expected=%s nonpass=%s final_match=yes qpa_match=yes crash_evidence=%s\n' \
    "$outcome" "$expected" "$(awk -F '\t' '$3!="Pass" { n++ } END { print n+0 }' "$ROOT/ledger.tsv")" "$evidence_count"
