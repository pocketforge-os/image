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
  chmod 0600 "${PF_INPUT_DEVICES_PATH:?}"
  printf '\nI: Bus=0003 Vendor=0f0f Product=1202 Version=0001\nN: Name="PocketForge seeded device"\n' >>"${PF_INPUT_DEVICES_PATH:?}"
  chmod 0444 "${PF_INPUT_DEVICES_PATH:?}"
  sleep 5
fi
if [[ "${PF_TEST_CASE:?}" == timeout ]]; then
  sleep 5
fi
sleep 0.5
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
elif [[ "$args" == *" --user "* ]]; then
  case "${PF_TEST_CASE:?}" in
    generic_service)
      printf '%s\n' 'systemd: Starting service - PocketForge exclusively owned Beads SSH transport'
      ;;
    hazard_fake)
      printf '%s\n' 'fixture: PocketForge Fake Keyboard appeared'
      ;;
    hazard_xinput)
      printf '%s\n' 'xf86-input-libinput: XINPUT: Adding extended input device "seeded"'
      ;;
    hazard_desktop)
      printf '%s\n' 'gnome-shell: libinput Adding device seeded pointer'
      ;;
    hazard_kernel)
      printf '%s\n' 'kernel: input: seeded keyboard registered'
      ;;
  esac
fi
JOURNAL

cat >"$tmp/fake-reporter" <<'REPORTER'
#!/usr/bin/env bash
set -euo pipefail
[[ -f "$1/screenshots/manifest.json" ]]
printf '%s\n' 'PASS: exact_widget_text pointer_activation negative_control pixel_deltas'
REPORTER
chmod +x "$tmp/fake-runner" "$tmp/fake-journalctl" "$tmp/fake-reporter"

cat >"$tmp/arbitrary-runner" <<'ARBITRARY'
#!/bin/sh
exit 0
ARBITRARY
chmod +x "$tmp/arbitrary-runner"
ln -s "$root/run.sh" "$tmp/run-link"

check_runner_allowlist() {
  local name="$1" candidate="$2" expected_rc="$3"
  set +e
  PF_NEGATIVE_CONTROL_TESTING=1 \
    PF_NEGATIVE_CONTROL_TEST_RUNNER_ALLOWLIST_ONLY=1 \
    "$root/negative-control.sh" --runner "$candidate" \
      >"$tmp/allowlist-$name.stdout" 2>"$tmp/allowlist-$name.stderr"
  local rc=$?
  set -e
  if [[ "$expected_rc" == 0 ]]; then
    [[ $rc -eq 0 ]]
    grep -Fq 'runner-allowlist=PASS' "$tmp/allowlist-$name.stdout"
  else
    [[ $rc -ne 0 ]]
    grep -Fq 'reason=runner_not_allowlisted' "$tmp/allowlist-$name.stdout"
  fi
}

check_runner_allowlist run_guest "$root/run-guest.sh" 0
check_runner_allowlist arbitrary "$tmp/arbitrary-runner" 1
check_runner_allowlist symlink "$tmp/run-link" 1
check_runner_allowlist traversal "$root/selftest/../run.sh" 1

pfvd_checkout="$tmp/pfvd"
mkdir -p "$pfvd_checkout/ci"
git init -q "$pfvd_checkout"
cat >"$pfvd_checkout/ci/run-input-harness-e2e.sh" <<'HOST_DRIVER'
#!/bin/sh
set -eu
[ "$1" = --out ]
mkdir -p "$2"
printf '%s\n' 'host-dispatch=PASS' >"$2/host-dispatch.txt"
HOST_DRIVER
chmod +x "$pfvd_checkout/ci/run-input-harness-e2e.sh"
git -C "$pfvd_checkout" add ci/run-input-harness-e2e.sh
git -C "$pfvd_checkout" -c user.name=test -c user.email=test@example.invalid \
  commit -q -m fixture
pfvd_commit="$(git -C "$pfvd_checkout" rev-parse HEAD)"
PF_INPUT_HARNESS_PFVD_ROOT="$pfvd_checkout" \
  PF_INPUT_HARNESS_PFVD_COMMIT="$pfvd_commit" \
  "$root/run-guest.sh" --out "$tmp/host-out"
grep -Fqx 'host-dispatch=PASS' "$tmp/host-out/host-dispatch.txt"
set +e
PF_INPUT_HARNESS_PFVD_ROOT="$pfvd_checkout" \
  PF_INPUT_HARNESS_PFVD_COMMIT=0000000000000000000000000000000000000000 \
  "$root/run-guest.sh" --out "$tmp/host-mismatch" \
  >"$tmp/host-mismatch.stdout" 2>"$tmp/host-mismatch.stderr"
host_mismatch_rc=$?
set -e
[[ $host_mismatch_rc -ne 0 ]]
grep -Fq 'reason=pfvd_commit_mismatch' "$tmp/host-mismatch.stdout"
mv "$pfvd_checkout/ci/run-input-harness-e2e.sh" "$tmp/original-host-driver"
ln -s "$tmp/arbitrary-runner" "$pfvd_checkout/ci/run-input-harness-e2e.sh"
set +e
PF_INPUT_HARNESS_PFVD_ROOT="$pfvd_checkout" \
  PF_INPUT_HARNESS_PFVD_COMMIT="$pfvd_commit" \
  "$root/run-guest.sh" --out "$tmp/host-symlink" \
  >"$tmp/host-symlink.stdout" 2>"$tmp/host-symlink.stderr"
host_symlink_rc=$?
set -e
[[ $host_symlink_rc -ne 0 ]]
grep -Fq 'reason=invalid_pfvd_driver' "$tmp/host-symlink.stdout"

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
  local timeout=2s
  local hazard_key=""
  mkdir -p "$case_dir"
  printf '%s\n' \
    'I: Bus=0019 Vendor=0000 Product=0001 Version=0000' \
    'N: Name="baseline input"' >"$case_dir/devices"
  chmod 0444 "$case_dir/devices"
  [[ "$(stat -c '%a' "$case_dir/devices")" == 444 ]]
  local internal_after=""
  if [[ "$name" == internal ]]; then
    internal_after=2
  fi
  if [[ "$name" == timeout ]]; then
    timeout=0.3s
  fi
  case "$name" in
    hazard_fake) hazard_key=pocketforge_fake ;;
    hazard_xinput) hazard_key=xinput_xf86 ;;
    hazard_desktop) hazard_key=desktop_input ;;
    hazard_kernel) hazard_key=kernel_input ;;
  esac
  set +e
  PF_TEST_CASE="$name" \
    PF_NEGATIVE_CONTROL_TESTING=1 \
    PF_INPUT_DEVICES_PATH="$case_dir/devices" \
    PF_NEGATIVE_CONTROL_JOURNALCTL="$tmp/fake-journalctl" \
    PF_NEGATIVE_CONTROL_RUNNER="$tmp/fake-runner" \
    PF_NEGATIVE_CONTROL_REPORTER="$tmp/fake-reporter" \
    PF_NEGATIVE_CONTROL_POLL_INTERVAL=0.01 \
    PF_NEGATIVE_CONTROL_TEST_INTERNAL_ERROR_AFTER_POLLS="$internal_after" \
    PF_TEST_KILLED="$case_dir/killed" \
    "$root/negative-control.sh" --timeout "$timeout" \
      --out "$case_dir/out" --receipt "$case_dir/receipt" \
      >"$case_dir/stdout" 2>"$case_dir/stderr"
  local rc=$?
  set -e
  if [[ ! -s "$case_dir/receipt" ]]; then
    printf 'negative-control-wrapper: RED case=%s reason=receipt_missing rc=%s\n' "$name" "$rc" >&2
    return 1
  fi
  if [[ "$expected" == pass ]]; then
    if [[ $rc -ne 0 ]]; then
      printf 'negative-control-wrapper: RED case=%s reason=unexpected_failure rc=%s\n' "$name" "$rc" >&2
      return 1
    fi
    grep -Fq 'PASS: input-harness-negative-control' "$case_dir/stdout"
    grep -Fq 'PASS: exact_widget_text pointer_activation negative_control pixel_deltas' "$case_dir/receipt"
  else
    if [[ $rc -eq 0 ]] || ! grep -Fq "reason=$expected" "$case_dir/stdout"; then
      printf 'negative-control-wrapper: RED case=%s reason=expected_%s rc=%s\n' "$name" "$expected" "$rc" >&2
      sed -n '1,24p' "$case_dir/receipt" >&2
      return 1
    fi
    if [[ "$expected" == host_input_device_appeared ]]; then
      grep -Fqx terminated "$case_dir/killed"
    fi
  fi
  grep -Fq -- '--- before /proc/bus/input/devices (verbatim) ---' "$case_dir/receipt"
  grep -Fq -- '--- after /proc/bus/input/devices (verbatim) ---' "$case_dir/receipt"
  grep -Fq 'N: Name="baseline input"' "$case_dir/receipt"
  grep -Fqx "reason=$expected" "$case_dir/receipt"
  grep -Fqx 'test_mode=1' "$case_dir/receipt"
  grep -Fqx "devices_path=$case_dir/devices" "$case_dir/receipt"
  grep -Fqx "journalctl_path=$tmp/fake-journalctl" "$case_dir/receipt"
  grep -Fqx "runner=$(realpath -e "$tmp/fake-runner")" "$case_dir/receipt"
  grep -Fqx "runner_sha256=$(sha256sum "$tmp/fake-runner" | awk '{print $1}')" "$case_dir/receipt"
  grep -Fqx "reporter_path=$tmp/fake-reporter" "$case_dir/receipt"
  grep -Fqx "out_path=$case_dir/out" "$case_dir/receipt"
  grep -Fqx "receipt_path=$case_dir/receipt" "$case_dir/receipt"
  grep -Fqx "evidence_path=$case_dir/receipt.evidence" "$case_dir/receipt"
  grep -Eq '^journal_hazard_pattern_pocketforge_fake=' "$case_dir/receipt"
  grep -Eq '^journal_hazard_pattern_xinput_xf86=' "$case_dir/receipt"
  grep -Eq '^journal_hazard_pattern_desktop_input=' "$case_dir/receipt"
  grep -Eq '^journal_hazard_pattern_kernel_input=' "$case_dir/receipt"
  if [[ "$name" != appeared ]]; then
    awk -F= '$1 == "poll_count" { found=1; if ($2 < 2) exit 1 } END { if (!found) exit 1 }' "$case_dir/receipt"
  fi
  grep -Eq '^user_pocketforge_info_count=[0-9]+$' "$case_dir/receipt"
  grep -Eq '^user_input_hazard_count=[0-9]+$' "$case_dir/receipt"
  grep -Eq '^system_pocketforge_info_count=[0-9]+$' "$case_dir/receipt"
  grep -Eq '^system_input_hazard_count=[0-9]+$' "$case_dir/receipt"
  if [[ "$name" == generic_service ]]; then
    grep -Fqx 'user_pocketforge_info_count=1' "$case_dir/receipt"
    grep -Fqx 'user_input_hazard_count=0' "$case_dir/receipt"
  elif [[ -n "$hazard_key" ]]; then
    grep -Fqx "user_hazard_${hazard_key}_count=1" "$case_dir/receipt"
  fi
  [[ -r "$case_dir/receipt.evidence/devices.before" ]]
  [[ -r "$case_dir/receipt.evidence/user.cursor.raw" ]]
  [[ -r "$case_dir/receipt.evidence/system.cursor.raw" ]]
  grep -Fq 'N: Name="baseline input"' "$case_dir/receipt.evidence/devices.before"
  if grep -Fq 'PocketForge seeded device' "$case_dir/receipt.evidence/devices.before"; then
    printf 'negative-control-wrapper: RED case=%s reason=before_snapshot_overwritten\n' "$name" >&2
    return 1
  fi
  grep -Fq -- '-- cursor: user-fixture-cursor' "$case_dir/receipt.evidence/user.cursor.raw"
  grep -Fq -- '-- cursor: system-fixture-cursor' "$case_dir/receipt.evidence/system.cursor.raw"
}

run_case generic_service pass
run_case internal wrapper_internal_error
run_case appeared host_input_device_appeared
run_case timeout harness_timeout
run_case hazard_fake host_input_journal_activity
run_case hazard_xinput host_input_journal_activity
run_case hazard_desktop host_input_journal_activity
run_case hazard_kernel host_input_journal_activity
run_case clean pass
printf '%s\n' 'negative-control-wrapper: PASS runner_allowlist=run-guest-only arbitrary=refused symlink=refused traversal=refused host_dispatch=fixed-commit mismatch=refused nested_symlink=refused internal=receipted appeared=aborted timeout=receipted generic_pocketforge=info hazards=4_refused clean=passed proc_mode=0444 device_inputs=faked'
