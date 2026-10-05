#!/usr/bin/env bash
# The generated mmdebstrap customize hook must define every function it calls,
# and must fail on any command that is not found, even where errexit does not
# apply (tsp-mc9m.41.986).  Every assertion runs against the hook exactly as
# scripts/build-rootfs.sh generates it, never against source fragments.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rootfs_script="${root}/scripts/build-rootfs.sh"
scratch="$(mktemp -d)"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT

# shellcheck source=tests/lib/capture-customize-hook.sh
. "${root}/tests/lib/capture-customize-hook.sh"
hook="${scratch}/customize-hook.sh"
capture_customize_hook "${root}" "${scratch}/fixture" "${hook}"
bash -n "${hook}"
grep -F "/customize-hook.sh \"\$1\"" "${hook}.cmd" >/dev/null

# shellcheck disable=SC2016 # literal hook source line
rootfs_marker='ROOTFS="$1"'
if [ "$(grep -Fxc "${rootfs_marker}" "${hook}")" -ne 1 ]; then
    echo "FAIL: generated hook must assign ${rootfs_marker} exactly once" >&2
    exit 1
fi
prelude_end="$(grep -Fnx "${rootfs_marker}" "${hook}" | cut -d: -f1)"

# Legacy/direct consumers execute the separately generated hook without any of
# the newer Gamescope environment.  Exercise the real hook prefix through its
# Gamescope gate: omission selects not-shipped, while explicit invalid and g1
# cross-device modes remain fail-closed.
gamescope_boundary="${scratch}/gamescope-boundary.sh"
awk '{ print }
     /^case "\$\{PF_GAMESCOPE_MODE\}" in$/ { in_gamescope = 1; next }
     in_gamescope && /^esac$/ { exit }' "${hook}" > "${gamescope_boundary}"
printf 'printf '\''gamescope-mode=%%s\n'\'' "$PF_GAMESCOPE_MODE"\n' \
    >> "${gamescope_boundary}"

legacy_root="${scratch}/legacy-root"
mkdir -p "${legacy_root}"
legacy_status=0
env -i PATH="${PATH}" TMPDIR="${scratch}" \
    bash "${gamescope_boundary}" "${legacy_root}" \
    > "${scratch}/gamescope-legacy.out" 2> "${scratch}/gamescope-legacy.err" \
    || legacy_status=$?
if [ "${legacy_status}" -ne 0 ]; then
    cat "${scratch}/gamescope-legacy.err" >&2
    echo "FAIL: generated hook rejected an omitted Gamescope environment (status ${legacy_status})" >&2
    exit 1
fi
grep -Fx 'gamescope-mode=not-shipped' "${scratch}/gamescope-legacy.out" >/dev/null
[ ! -s "${scratch}/gamescope-legacy.err" ]

if env -i PATH="${PATH}" TMPDIR="${scratch}" PF_GAMESCOPE_MODE=invalid \
    bash "${gamescope_boundary}" "${legacy_root}" \
    > "${scratch}/gamescope-invalid.out" 2> "${scratch}/gamescope-invalid.err"; then
    echo 'FAIL: generated hook accepted an invalid explicit Gamescope mode' >&2
    exit 1
fi
grep -F 'invalid Gamescope mode in customize hook' \
    "${scratch}/gamescope-invalid.err" >/dev/null

if env -i PATH="${PATH}" TMPDIR="${scratch}" PF_GAMESCOPE_MODE=g1 \
    PF_DEVICE_ID=legacy-direct \
    bash "${gamescope_boundary}" "${legacy_root}" \
    > "${scratch}/gamescope-g1-device.out" 2> "${scratch}/gamescope-g1-device.err"; then
    echo 'FAIL: generated hook accepted Gamescope g1 on a legacy device' >&2
    exit 1
fi
grep -F 'refusing Gamescope package on legacy-direct' \
    "${scratch}/gamescope-g1-device.err" >/dev/null

# 1. A function that build-rootfs.sh (or a library it sources) defines and the
# hook calls must also be defined in the hook: the hook is a separate process.
hook_code="${scratch}/hook-code.sh"
grep -Ev '^[[:space:]]*#' "${hook}" > "${hook_code}"
outer_functions="$(grep -ohE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{$' \
    "${rootfs_script}" "${root}/scripts/kernel-module-form.sh" \
    | sed 's/() {$//' | sort -u)"
[ -n "${outer_functions}" ]
missing_definitions=""
for function_name in ${outer_functions}; do
    grep -qw -- "${function_name}" "${hook_code}" || continue
    grep -Eq "^${function_name} ?\(\)" "${hook_code}" \
        || missing_definitions="${missing_definitions} ${function_name}"
done
if [ -n "${missing_definitions}" ]; then
    echo "FAIL: generated customize hook calls functions it does not define:${missing_definitions}" >&2
    exit 1
fi

# The EXIT trap is the fail-closed mechanism.  A second EXIT trap later in the
# hook would silently replace it.
if [ "$(grep -Ec '^[[:space:]]*trap .*[[:space:]]EXIT$' "${hook_code}")" -ne 1 ]; then
    echo 'FAIL: generated customize hook must install exactly one EXIT trap' >&2
    exit 1
fi

# 2. The hook's own prelude fails closed on a command that is not found in
# every context where errexit is suppressed.  The controls in the same loop
# prove the prelude preserves ordinary success, failure and exit statuses.
prelude="${scratch}/prelude.sh"
head -n "$((prelude_end - 1))" "${hook}" > "${prelude}"
hook_tmp="${scratch}/hook-tmp"
mkdir -p "${hook_tmp}"
run_prelude_case() {
    local label="$1"
    local body="$2"
    local status=0
    { cat "${prelude}"; printf '%s\necho AFTER\n' "${body}"; } > "${scratch}/${label}.sh"
    TMPDIR="${hook_tmp}" bash "${scratch}/${label}.sh" \
        > "${scratch}/${label}.out" 2> "${scratch}/${label}.err" || status=$?
    if [ -n "$(find "${hook_tmp}" -mindepth 1 -print -quit)" ]; then
        echo "FAIL: prelude case ${label} leaked its missing-command record" >&2
        exit 1
    fi
    printf '%s\n' "${status}"
}
# shellcheck disable=SC2016 # literal hook bodies, expanded by the hook
masked_cases=(
    'if ! pf_test_undefined_command arg; then echo MASKED; fi'
    'if pf_test_undefined_command; then :; else echo MASKED; fi'
    'pf_test_undefined_command || echo MASKED'
    'pf_test_undefined_command && echo never; echo MASKED'
    '! pf_test_undefined_command; echo MASKED'
    'while pf_test_undefined_command; do :; done; echo MASKED'
    'value="$(pf_test_undefined_command)" || echo MASKED'
    '( pf_test_undefined_command ) || echo MASKED'
    'pf_test_undefined_command'
)
index=0
for body in "${masked_cases[@]}"; do
    index=$((index + 1))
    status="$(run_prelude_case "masked-${index}" "${body}")"
    if [ "${status}" -ne 127 ]; then
        echo "FAIL: undefined command did not fail the hook (status ${status}): ${body}" >&2
        exit 1
    fi
    grep -Fx 'FATAL: customize-hook: command not found: pf_test_undefined_command' \
        "${scratch}/masked-${index}.err" >/dev/null
    grep -F 'FATAL: customize-hook called undefined command(s): pf_test_undefined_command' \
        "${scratch}/masked-${index}.err" >/dev/null
done
[ "$(run_prelude_case control-true 'true')" -eq 0 ]
grep -Fx AFTER "${scratch}/control-true.out" >/dev/null
[ ! -s "${scratch}/control-true.err" ]
[ "$(run_prelude_case control-false 'false')" -eq 1 ]
[ "$(run_prelude_case control-exit 'exit 3')" -eq 3 ]
[ "$(run_prelude_case control-shared 'is_a133_open_7x_gpu_device a133-open-7x-gpu')" -eq 0 ]

# 3. The gated PowerVR option is written by the generated hook itself.  Run the
# hook's own definitions (prelude through install_open_gpu_module_options, with
# no top-level rootfs mutation) in a clean environment, then call the helper.
options_helper="${scratch}/options-helper.sh"
awk '{ print } /^install_open_gpu_module_options\(\) \{$/ { in_helper = 1 }
     in_helper && /^}$/ { exit }' "${hook}" > "${options_helper}"
grep -Fx 'install_open_gpu_module_options() {' "${options_helper}" >/dev/null
[ "$(tail -n 1 "${options_helper}")" = '}' ]
if grep -Eq '^(chroot|install|cp|ln|rm|mkdir) ' "${options_helper}"; then
    echo 'FAIL: hook prefix mutates the rootfs before install_open_gpu_module_options' >&2
    exit 1
fi
printf 'install_open_gpu_module_options\n' >> "${options_helper}"
options_file=etc/modprobe.d/powervr-a133-open-7x-gpu.conf

run_options_helper() {
    local label="$1"
    local device_id="$2"
    local gpu_model="$3"
    local gpu_km_model="$4"
    local status=0
    mkdir -p "${scratch}/${label}-root"
    env -i PATH="${PATH}" TMPDIR="${hook_tmp}" PF_DEVICE_ID="${device_id}" \
        PF_GPU_MODEL="${gpu_model}" PF_GPU_KM_MODEL="${gpu_km_model}" \
        bash "${options_helper}" "${scratch}/${label}-root" \
        > "${scratch}/${label}.out" 2> "${scratch}/${label}.err" || status=$?
    printf '%s\n' "${status}"
}

for device_id in a133-open-7x-gpu a133-open-7x-gpu-noradio; do
    status="$(run_options_helper "options-${device_id}" "${device_id}" open in-tree-7.x)"
    if [ "${status}" -ne 0 ] || grep -F 'command not found' "${scratch}/options-${device_id}.err" >&2; then
        echo "FAIL: generated hook could not evaluate the ${device_id} PowerVR option gate (status ${status})" >&2
        exit 1
    fi
    [ "$(cat "${scratch}/options-${device_id}-root/${options_file}")" = \
        'options powervr exp_hw_support=1' ] || {
        echo "FAIL: generated hook skipped the ${device_id} PowerVR exp_hw_support option" >&2
        exit 1
    }
    # The build log carries a positive line for the post-merge build check.
    grep -Fx "[customize] PowerVR: /etc/modprobe.d/powervr-a133-open-7x-gpu.conf (options powervr exp_hw_support=1) for ${device_id}" \
        "${scratch}/options-${device_id}.out" >/dev/null
done

# Only the two named sibling profiles may receive the option; near matches and
# other devices are excluded without error.
for tuple in \
    'a133-open open in-tree-6.x' \
    'a133-open-7x none none' \
    'a133-open-7x-gpu-extra open in-tree-7.x' \
    'a133-open-7x-gpu-noradio-extra open in-tree-7.x' \
    'unknown open in-tree-7.x' \
    'a133 ddk out-of-tree-ddk' \
    'a523 ddk out-of-tree-ddk'; do
    read -r device_id gpu_model gpu_km_model <<< "${tuple}"
    status="$(run_options_helper "excluded-${device_id}" "${device_id}" "${gpu_model}" "${gpu_km_model}")"
    [ "${status}" -eq 0 ] || {
        echo "FAIL: ${device_id} PowerVR option gate failed (status ${status})" >&2
        exit 1
    }
    [ ! -e "${scratch}/excluded-${device_id}-root/${options_file}" ] || {
        echo "FAIL: ${device_id} received the a133-open-7x-gpu PowerVR option" >&2
        exit 1
    }
    if grep -F '[customize] PowerVR:' "${scratch}/excluded-${device_id}.out" >&2; then
        echo "FAIL: ${device_id} logged the a133-open-7x-gpu PowerVR option" >&2
        exit 1
    fi
done

# A 7.x GPU device ID without the exact open/in-tree-7.x contract is refused.
for device_id in a133-open-7x-gpu a133-open-7x-gpu-noradio; do
    status="$(run_options_helper "wrong-${device_id}" "${device_id}" open in-tree-6.x)"
    [ "${status}" -ne 0 ] || {
        echo "FAIL: ${device_id} PowerVR option accepted a non-7.x contract" >&2
        exit 1
    }
    grep -F 'without its exact open/in-tree-7.x contract' \
        "${scratch}/wrong-${device_id}.err" >/dev/null
done

echo 'customize-hook-fail-closed=PASS'
