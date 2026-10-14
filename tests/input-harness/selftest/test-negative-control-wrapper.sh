#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -x "$root/negative-control.sh" ]]; then
  printf '%s\n' 'negative-control-wrapper: RED reason=wrapper_missing' >&2
  exit 1
fi
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/input-negative-control.XXXXXX")"
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT

cat >"$tmp/fake-runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
trap 'printf "%s\n" terminated >"${PF_TEST_KILLED:?}"; exit 143' TERM
[[ "$1" == --out ]]
out="$2"
mkdir -p "$out/screenshots"
printf '[{"target":"fixture"}]\n' >"$out/screenshots/manifest.json"
if [[ "${PF_TEST_CASE:?}" == appeared ]]; then
  sleep 0.05
  printf '\nI: Bus=0003 Vendor=0f0f Product=1202 Version=0001\nN: Name="PocketForge seeded device"\n' >>"${PF_INPUT_DEVICES_PATH:?}"
  sleep 5
fi
RUNNER

cat >"$tmp/fake-journalctl" <<'JOURNAL'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ "$args" == *" --show-cursor "* ]]; then
  if [[ "$args" == *" --user "* ]]; then
    printf '%s\n' '-- cursor: user-fixture-cursor'
  else
    printf '%s\n' '-- cursor: system-fixture-cursor'
  fi
elif [[ "${PF_TEST_CASE:?}" == journal && "$args" == *" --user "* ]]; then
  printf '%s\n' 'fixture XINPUT: Adding extended input device "PocketForge seeded"'
fi
JOURNAL

cat >"$tmp/fake-reporter" <<'REPORTER'
#!/usr/bin/env bash
set -euo pipefail
[[ -f "$1/screenshots/manifest.json" ]]
printf '%s\n' 'PASS: exact_widget_text pointer_activation negative_control pixel_deltas'
REPORTER
chmod +x "$tmp/fake-runner" "$tmp/fake-journalctl" "$tmp/fake-reporter"

set +e
PF_INPUT_DEVICES_PATH="$tmp/not-real-proc" \
  "$root/negative-control.sh" --timeout 1s --out "$tmp/override-out" \
    --receipt "$tmp/override-receipt" >"$tmp/override-stdout" 2>"$tmp/override-stderr"
override_rc=$?
set -e
[[ $override_rc -ne 0 ]]
grep -Fq 'reason=test_override_requires_opt_in' "$tmp/override-stdout"

run_case() {
  local name="$1" expected="$2"
  local case_dir="$tmp/$name"
  mkdir -p "$case_dir"
  printf '%s\n' \
    'I: Bus=0019 Vendor=0000 Product=0001 Version=0000' \
    'N: Name="baseline input"' >"$case_dir/devices"
  set +e
  PF_TEST_CASE="$name" \
    PF_NEGATIVE_CONTROL_TESTING=1 \
    PF_INPUT_DEVICES_PATH="$case_dir/devices" \
    PF_NEGATIVE_CONTROL_JOURNALCTL="$tmp/fake-journalctl" \
    PF_NEGATIVE_CONTROL_RUNNER="$tmp/fake-runner" \
    PF_NEGATIVE_CONTROL_REPORTER="$tmp/fake-reporter" \
    PF_NEGATIVE_CONTROL_POLL_INTERVAL=0.01 \
    PF_TEST_KILLED="$case_dir/killed" \
    "$root/negative-control.sh" --timeout 2s \
      --out "$case_dir/out" --receipt "$case_dir/receipt" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  local rc=$?
  set -e
  if [[ "$expected" == pass ]]; then
    [[ $rc -eq 0 ]]
    grep -Fq 'PASS: input-harness-negative-control' "$case_dir/stdout"
    grep -Fq 'PASS: exact_widget_text pointer_activation negative_control pixel_deltas' "$case_dir/receipt"
  else
    [[ $rc -ne 0 ]]
    grep -Fq "reason=$expected" "$case_dir/stdout"
    if [[ "$expected" == host_input_device_appeared ]]; then
      grep -Fqx terminated "$case_dir/killed"
    fi
  fi
  grep -Fq -- '--- before /proc/bus/input/devices (verbatim) ---' "$case_dir/receipt"
  grep -Fq 'N: Name="baseline input"' "$case_dir/receipt"
}

run_case appeared host_input_device_appeared
run_case journal host_input_journal_activity
run_case clean pass
printf '%s\n' 'negative-control-wrapper: PASS appeared=aborted journal=refused clean=passed device_inputs=faked'
