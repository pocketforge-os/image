#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
workflow=$root/.github/workflows/hermetic-tests.yml
probe=$root/tests/probe-hermetic-test-runner.sh

fail()
{
    printf 'hermetic_test_placement=FAIL reason=%s\n' "$1" >&2
    exit 1
}

test "$(grep -Fxc '    runs-on: [self-hosted, pf-ci-container]' "$workflow")" -eq 1 \
    || fail 'hermetic-tests must use exactly self-hosted,pf-ci-container'
if grep -Eq '^[[:space:]]*runs-on:.*pf-builder-vm' "$workflow"; then
    fail 'hermetic-tests still requests the builder class'
fi
test "$(grep -Fc 'github.event.pull_request.head.repo.full_name == github.repository' "$workflow")" -eq 1 \
    || fail 'fork guard is missing or duplicated'
grep -Fq 'tests/probe-hermetic-test-runner.sh' "$workflow" \
    || fail 'runner capability probe is not wired into the job'
test -x "$probe" || fail 'runner capability probe is missing or not executable'

scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/image-hermetic-placement.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT
tools='bwrap python3 systemd'

for tool in $tools; do
    : >"$scratch/$tool"
    chmod +x "$scratch/$tool"
done

for missing in $tools; do
    mv "$scratch/$missing" "$scratch/$missing.absent"
    set +e
    PATH=$scratch "$probe" >"$scratch/stdout" 2>"$scratch/stderr"
    rc=$?
    set -e
    test "$rc" -eq 75 || fail "missing $missing returned $rc instead of 75"
    grep -Fq "BLOCKED: missing $missing" "$scratch/stderr" \
        || fail "missing $missing did not report BLOCKED"
    mv "$scratch/$missing.absent" "$scratch/$missing"
done

set +e
PF_HERMETIC_PROBE_INOTIFY=missing PATH=$scratch \
    "$probe" >"$scratch/stdout" 2>"$scratch/stderr"
rc=$?
set -e
test "$rc" -eq 75 || fail "missing inotify returned $rc instead of 75"
grep -Fq 'BLOCKED: missing inotify' "$scratch/stderr" \
    || fail 'missing inotify did not report BLOCKED'

PATH=$scratch "$probe" >"$scratch/stdout" 2>"$scratch/stderr" \
    || fail 'complete capability fixture was refused'
grep -Fq 'hermetic_runner_probe=PASS' "$scratch/stdout" \
    || fail 'successful probe did not emit a receipt'

printf '%s\n' \
    'hermetic_test_placement=PASS runner=pf-ci-container fork_guard=same-repository probe=fail-closed'
