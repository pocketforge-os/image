#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/build-cache-audit-test.XXXXXX")"
cleanup() {
    find "$work" -mindepth 1 -delete
    rmdir "$work"
}
trap cleanup EXIT

own_records="$work/own.jsonl"
global_records="$work/global.jsonl"
builder_marker="$work/builder"
call_log="$work/docker.calls"
build_cache_builder=pf-sa-test-run

build_cache_docker() {
    printf 'docker %s\n' "$*" >>"$call_log"
    test "${1:-}" = buildx
    shift
    case "${1:-}" in
        create)
            test "$*" = "create --name $build_cache_builder --driver docker-container"
            printf '%s\n' "$build_cache_builder" >"$builder_marker"
            printf '%s\n' "$build_cache_builder"
            ;;
        inspect)
            test "${2:-}" = "$build_cache_builder"
            if test "${3:-}" = --bootstrap && test "${FAKE_BOOTSTRAP_FAIL:-0}" -eq 1; then
                return 42
            fi
            test -s "$builder_marker"
            ;;
        rm)
            test "${2:-}" = "$build_cache_builder"
            test -s "$builder_marker" || return 1
            find "$builder_marker" -delete
            ;;
        ls)
            test "${2:-}" = --format && test "${3:-}" = json
            test "${FAKE_LIST_FAIL:-0}" -eq 0 || return 55
            if test -s "$builder_marker"; then
                printf '{"Name":"%s","Driver":"docker-container"}\n' \
                    "$build_cache_builder"
            fi
            printf '%s\n' '{"Name":"foreign-builder","Driver":"docker-container"}'
            ;;
        du)
            if test "${2:-}" = --builder && test "${3:-}" = "$build_cache_builder"; then
                test "${4:-}" = --format && test "${5:-}" = json
                test ! -s "$own_records" || cat "$own_records"
            else
                test ! -s "$global_records" || cat "$global_records"
            fi
            ;;
        prune)
            test "${2:-}" = --builder && test "${3:-}" = "$build_cache_builder"
            cache_id="${6#id=}"
            if test "$cache_id" != "${FAKE_STUCK_ID:-}"; then
                python3 - "$own_records" "$cache_id" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
target = sys.argv[2]
records = [json.loads(line) for line in path.read_text().splitlines() if line]
path.write_text("".join(
    json.dumps(record, separators=(",", ":")) + "\n"
    for record in records if record["ID"] != target
))
PY
            fi
            ;;
        *) return 2 ;;
    esac
}

build_cache_cleanup_pause() { :; }

# shellcheck source=tests/session-authority-systemd/build-cache-audit.sh
source "$repo_root/tests/session-authority-systemd/build-cache-audit.sh"

# Bootstrap-failure negative: create succeeded, so ownership must already be
# recorded and mandatory teardown must still remove the run's builder.
build_cache_builder_created=0
FAKE_BOOTSTRAP_FAIL=1
export FAKE_BOOTSTRAP_FAIL
if create_run_build_cache_builder; then
    printf 'FAIL bootstrap failure passed builder creation\n' >&2
    exit 1
fi
test "$build_cache_builder_created" -eq 1
test -s "$builder_marker"
unset FAKE_BOOTSTRAP_FAIL
remove_run_build_cache_builder
test "$build_cache_builder_created" -eq 0

# Verification-query negative: a daemon/list failure after removal is not
# proof of absence. Ownership remains recorded until a retry confirms absence.
create_run_build_cache_builder
test "$build_cache_builder_created" -eq 1
FAKE_LIST_FAIL=1
export FAKE_LIST_FAIL
if remove_run_build_cache_builder; then
    printf 'FAIL builder list failure passed teardown verification\n' >&2
    exit 1
fi
test "$build_cache_builder_created" -eq 1
unset FAKE_LIST_FAIL
remove_run_build_cache_builder
test "$build_cache_builder_created" -eq 0

# Positive plus foreign-record negative: only the owned builder is visible to
# the audit, so a concurrent default-builder record survives without failing.
create_run_build_cache_builder
printf '%s\n' '{"ID":"own-base","Parents":null}' >"$own_records"
capture_build_cache_records "$work/baseline.tsv"
printf '%s\n' \
    '{"ID":"own-base","Parents":null}' \
    '{"ID":"own-created","Parents":["own-base"]}' >"$own_records"
printf '%s\n' '{"ID":"foreign-created","Parents":null}' >"$global_records"
cleanup_run_build_cache "$work/baseline.tsv" "$work/cleanup"
test "$build_cache_records_removed" -eq 1
grep -q 'foreign-created' "$global_records"
remove_run_build_cache_builder
test ! -e "$builder_marker"
grep -Fx "docker buildx rm $build_cache_builder" "$call_log"
! grep -F 'buildx rm foreign' "$call_log"

# Owned-leak negative: a record visible in the run builder that refuses exact
# pruning must fail with that record ID, before builder teardown removes it.
: >"$call_log"
create_run_build_cache_builder
printf '%s\n' '{"ID":"own-base","Parents":null}' >"$own_records"
capture_build_cache_records "$work/stuck-baseline.tsv"
printf '%s\n' \
    '{"ID":"own-base","Parents":null}' \
    '{"ID":"own-stuck","Parents":["own-base"]}' >"$own_records"
FAKE_STUCK_ID=own-stuck
export FAKE_STUCK_ID
if cleanup_run_build_cache "$work/stuck-baseline.tsv" "$work/stuck-cleanup"; then
    printf 'FAIL owned cache leak passed audit\n' >&2
    exit 1
fi
test "$(build_cache_drift_reason)" = \
    'BUILD_CACHE_USAGE_DRIFT:leftover_ids=own-stuck;missing_ids=none'
remove_run_build_cache_builder
unset FAKE_STUCK_ID

printf 'build-cache audit isolation test: PASS foreign=ignored own_leak=failed bootstrap=tracked verify_error=failed builder=owned-only\n'
