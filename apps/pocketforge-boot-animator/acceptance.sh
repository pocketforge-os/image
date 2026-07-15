#!/usr/bin/env bash
# apps/pocketforge-boot-animator/acceptance.sh
# tsp-3rd3.4 on-device acceptance wrapper.
#
# Runs after the combined-image flash (rotation-fix + charge-fix + this
# animator) has landed on pf-node-01's DUT and the DUT has cold-booted.
# Composes the tsp-3rd3.1 harness (boot-splash-verify.sh) with the
# animator-specific probes required by the acceptance criteria:
#   1. u-boot -> animator continuity + no rotation flip
#      (boot-splash-verify.sh window verdicts + rotation_consistency)
#   2. fbcon-clean / no console-text bleed-through between frames
#      (extra review-screen prompt on the fb0-window frames)
#   3. decode-timing < 62 ms/frame on A133
#      (ssh DUT: journalctl -u pocketforge-boot-animator | grep 'tick=')
#   4. RSS footprint <= 20 MiB
#      (ssh DUT: /proc/<pid>/status)
#   5. no boot-delay regression: t_login not measurably later than baseline
#      (compare t_login from boot-splash-verify vs tsp-3rd3.1 baseline)
#
# Prints a single machine-readable contract:
#   accept_status=ok|warn|failed
#   verify_status=... rotation_consistency=... window_fb0_verdict=...
#   fbcon_bleed=none|suspected|unknown
#   decode_p50_ms=... decode_p95_ms=... decode_over_budget_count=...
#   rss_kib=... rss_ceiling_kib=20480 rss_status=ok|over
#   t_login=... t_login_baseline=... t_login_delta_s=...
#
# Consumes the harness contract lines, so this script never reads whole logs
# into its own context — every log stays out of the caller's main loop.
#
# bd: tsp-3rd3.4
set -euo pipefail

DUT_HOST="matt@10.254.16.198"           # pf-node-01 (BPI); the BPI SSHes on to the DUT itself
DUT_DEVICE_HOST="root@192.168.86.101"   # base A133 IP (pf-node-01 target)
BASELINE_T_LOGIN_S=""                    # populated below from tsp-3rd3.1 baseline
RSS_CEILING_KIB=20480                    # coord-approved 20 MiB
TICK_BUDGET_MS=62                        # 62.5 ms rounded down (16 fps)
RUN_LABEL="tsp-3rd3.4-acceptance"
RUN_DIR=""
CONSUME_RUN=0                            # 1 = re-verdict existing --run-dir (no fresh cold-POR)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)                DUT_HOST="$2"; shift ;;
        --device)              DUT_DEVICE_HOST="$2"; shift ;;
        --baseline-t-login)    BASELINE_T_LOGIN_S="$2"; shift ;;
        --run-dir)             RUN_DIR="$2"; shift ;;
        --consume-run)         CONSUME_RUN=1 ;;
        --label)               RUN_LABEL="$2"; shift ;;
        -h|--help)
            sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown_arg=$1" >&2; exit 2 ;;
    esac
    shift
done

# --consume-run requires a --run-dir (nothing to consume without one).
if [ "$CONSUME_RUN" = 1 ] && [ -z "$RUN_DIR" ]; then
    echo "accept_status=failed reason=consume_run_needs_run_dir"
    exit 2
fi

# tsp-3rd3.1 comment recorded t_uboot_splash=5.103s and the run ended before
# kernel handoff on the drained battery. Baseline for t_login is TBD — coord
# will relay the number from the same tsp-3rd3.1 harness on a charged unit.
# If not passed, we skip the delta check and only report the raw value.

SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
HARNESS="/home/matt/pocketforge-automation/scripts/boot-splash-verify.sh"
[ -x "$HARNESS" ] || { echo "accept_status=failed reason=harness_missing path=$HARNESS"; exit 1; }

# Step 1: drive (or re-verdict) the tsp-3rd3.1 harness. With --consume-run
# we ADD --dry-run to the harness call so it re-verdicts the existing
# --run-dir instead of triggering a fresh cold-POR — this is the shared
# cold-POR flow (tsp-myp1.5.1 drives ONE boot, both lanes read the same
# frames). Contract lines only leave the harness; whole logs stay on-node.
echo "== acceptance: boot-splash-verify.sh (consume=$CONSUME_RUN) =="
HARNESS_OUT="$(mktemp)"
if [ "$CONSUME_RUN" = 1 ]; then
    HARNESS_ARGS=(--dry-run --run-dir "$RUN_DIR" --label "$RUN_LABEL")
else
    HARNESS_ARGS=(--host "$DUT_HOST" --label "$RUN_LABEL")
    [ -n "$RUN_DIR" ] && HARNESS_ARGS+=(--run-dir "$RUN_DIR")
fi
if ! "$HARNESS" "${HARNESS_ARGS[@]}" >"$HARNESS_OUT" 2>&1; then
    tail -20 "$HARNESS_OUT" >&2
    echo "accept_status=failed reason=harness_error"
    exit 1
fi
tail -20 "$HARNESS_OUT"

# Pull contract lines the harness emits.
extract() { grep -E "^$1=" "$HARNESS_OUT" | tail -1 | cut -d= -f2- ; }
verify_status="$(extract verify_status)"
rotation_consistency="$(extract rotation_consistency)"
window_uboot_verdict="$(extract window_uboot_verdict)"
window_handoff_verdict="$(extract window_handoff_verdict)"
window_fb0_verdict="$(extract window_fb0_verdict)"
window_login_verdict="$(extract window_login_verdict)"
t_login_s="$(extract t_login)"
RUN_DIR="${RUN_DIR:-$(extract run_dir)}"

# Step 2: animator per-frame timing from the DUT journal.
#
# The unit ships CLEAN by default (no --measure). Timing lines exist in the
# journal ONLY if this boot was the "measure boot" — meaning
# apps/pocketforge-boot-animator/measure.conf.example was installed as
# /etc/systemd/system/pocketforge-boot-animator.service.d/measure.conf and
# systemd was daemon-reloaded before this boot. If not present, decode_*
# fields report n/a and the run is fine — the OWNER-SIGNOFF boot deliberately
# does NOT carry --measure (coord directive 2026-07-14). Sequence:
#   a. Cold-POR boot #1: CLEAN (no drop-in) → owner-signoff panel look +
#      windows/rotation/fbcon/t_login/RSS. This is the run acceptance.sh is
#      designed for by default.
#   b. Cold-POR boot #2: measure drop-in installed → decode_p50/p95 + over-
#      budget count. Run acceptance.sh again; it will find the timing lines.
#   c. Remove the drop-in + daemon-reload.
echo "== acceptance: animator per-frame timing =="
timing_raw="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$DUT_DEVICE_HOST" \
    "journalctl -u pocketforge-boot-animator.service --no-pager -o cat 2>/dev/null | grep -E 'tick=' || true")"
decode_p50_ms=""; decode_p95_ms=""; decode_over_budget_count=""
if [ -n "$timing_raw" ]; then
    read -r decode_p50_ms decode_p95_ms decode_over_budget_count <<EOF
$(echo "$timing_raw" | awk -v budget="$TICK_BUDGET_MS" '
    match($0, /decode=([0-9.]+)ms/, m) {
        v = m[1] + 0; a[++n] = v; if (v > budget) over++;
    }
    END {
        if (n == 0) { print "n/a n/a 0"; exit; }
        # sort a[] ascending
        for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) if (a[j]<a[i]) { t=a[i]; a[i]=a[j]; a[j]=t; }
        p50 = a[int((n+1)/2)];
        p95_idx = int(n*0.95); if (p95_idx<1) p95_idx=1;
        p95 = a[p95_idx];
        printf "%.2f %.2f %d\n", p50, p95, over+0;
    }')
EOF
fi

# Step 3: RSS + fbcon-clean check.
echo "== acceptance: RSS / fbcon-clean =="
rss_kib="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$DUT_DEVICE_HOST" \
    'pid=$(pidof pocketforge-boot-animator 2>/dev/null || true); \
     if [ -n "$pid" ]; then awk "/^VmRSS:/ {print \$2}" /proc/$pid/status; else echo unknown; fi' 2>/dev/null || echo unknown)"
if [ "$rss_kib" != "unknown" ] && [ "$rss_kib" -le "$RSS_CEILING_KIB" ] 2>/dev/null; then
    rss_status=ok
else
    rss_status=over
fi

# fbcon bleed heuristic: ask review-screen on the fb0-window frame with a
# yes/no prompt. review-screen returns text; grep for "console" or
# "text" phrases. Fail-safe unknown on prompt error.
FB0_FRAME="$(grep -E '^window_fb0_frame=' "$HARNESS_OUT" | tail -1 | cut -d= -f2- || true)"
fbcon_bleed=unknown
if [ -n "$FB0_FRAME" ] && [ -f "$FB0_FRAME" ]; then
    prompt='Look at this photo of a device screen. Are there any visible KERNEL CONSOLE TEXT GLYPHS (small monospace letters, dmesg-style lines, boot messages, cursor block) anywhere on the panel? Answer strictly "YES with details" or "NO none visible". Do NOT invent detail; if uncertain say "UNCLEAR".'
    verdict="$(/home/matt/pocketforge-automation/scripts/review-screen.sh "$FB0_FRAME" --prompt "$prompt" 2>/dev/null || true)"
    case "$verdict" in
        *NO*none*)  fbcon_bleed=none ;;
        *UNCLEAR*)  fbcon_bleed=unknown ;;
        *YES*)      fbcon_bleed=suspected ;;
    esac
fi

# Step 4: t_login regression vs baseline (if provided).
t_login_delta_s=""; t_login_status="unknown"
if [ -n "$BASELINE_T_LOGIN_S" ] && [ -n "$t_login_s" ] && [ "$t_login_s" != "n/a" ]; then
    t_login_delta_s="$(awk -v n="$t_login_s" -v b="$BASELINE_T_LOGIN_S" 'BEGIN {printf "%.2f", n - b}')"
    # <=1.0s slop = ok; 1.0-3.0s = warn; > 3.0s = fail
    t_login_status="$(awk -v d="$t_login_delta_s" 'BEGIN {
        d = (d < 0 ? -d : d);
        if (d <= 1.0) print "ok"; else if (d <= 3.0) print "warn"; else print "failed";
    }')"
fi

# Compose final verdict.
accept="ok"
[ "$verify_status" = "warn" ] && accept="warn"
[ "$verify_status" = "failed" ] && accept="failed"
[ "$rotation_consistency" != "CONSISTENT" ] && accept="failed"
[ "$fbcon_bleed" = "suspected" ] && accept="failed"
[ "$rss_status" = "over" ] && accept="failed"
[ "$t_login_status" = "warn" ] && [ "$accept" = "ok" ] && accept="warn"
[ "$t_login_status" = "failed" ] && accept="failed"
if [ -n "$decode_over_budget_count" ] && [ "$decode_over_budget_count" -gt 5 ] 2>/dev/null; then
    # more than a handful of overruns during the acceptance window = jank
    [ "$accept" = "ok" ] && accept="warn"
fi

cat <<EOF

accept_status=${accept}
run_dir=${RUN_DIR}
verify_status=${verify_status}
rotation_consistency=${rotation_consistency}
window_uboot_verdict=${window_uboot_verdict}
window_handoff_verdict=${window_handoff_verdict}
window_fb0_verdict=${window_fb0_verdict}
window_login_verdict=${window_login_verdict}
fbcon_bleed=${fbcon_bleed}
decode_p50_ms=${decode_p50_ms:-n/a}
decode_p95_ms=${decode_p95_ms:-n/a}
decode_over_budget_count=${decode_over_budget_count:-0}
decode_budget_ms=${TICK_BUDGET_MS}
rss_kib=${rss_kib}
rss_ceiling_kib=${RSS_CEILING_KIB}
rss_status=${rss_status}
t_login=${t_login_s:-n/a}
t_login_baseline=${BASELINE_T_LOGIN_S:-n/a}
t_login_delta_s=${t_login_delta_s:-n/a}
t_login_status=${t_login_status}
EOF
