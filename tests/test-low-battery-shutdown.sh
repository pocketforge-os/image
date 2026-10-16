#!/usr/bin/env bash
# Hermetic contract for the AXP717 low-battery userspace shutdown policy.
set -euo pipefail
umask 022

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${root}/rootfs-overlay/usr/lib/pocketforge/low-battery-shutdown.sh"
unit="${root}/rootfs-overlay/etc/systemd/system/pocketforge-low-battery-shutdown.service"
rule="${root}/rootfs-overlay/etc/udev/rules.d/81-pocketforge-low-battery-shutdown.rules"
builder="${root}/scripts/build-rootfs.sh"
dockerfile="${root}/build/Dockerfile.pf"
capability_emitter="${root}/scripts/emit-axp717-low-soc-capability.sh"
alarm_kernel_sha=973d40af95f2dc5754bfe57e2b7a9c18fc4e92c8
descendant_kernel_sha=1111111111111111111111111111111111111111
ancestor_kernel_sha=a811ccb911d019d24fa194ee74789b8ea83436dc
unrelated_kernel_sha=2222222222222222222222222222222222222222
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-low-battery.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -x "${policy}" ] || fail "missing executable low-battery policy ${policy}"
[ -f "${unit}" ] || fail "missing low-battery systemd unit"
[ -f "${rule}" ] || fail "missing low-battery udev rule"

cat > "${scratch}/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${PF_SYSTEMCTL_LOG:?}"
exit "${PF_SYSTEMCTL_RC:-0}"
EOF
chmod 0755 "${scratch}/systemctl"

make_fixture() {
    local dir="$1" capacity="$2" level="$3" voltage_uv="$4"
    local present="$5" external_online="$6"
    local battery="${dir}/sys/class/power_supply/axp20x-battery"
    local external="${dir}/sys/class/power_supply/axp20x-usb"

    mkdir -p "${battery}" "${external}" "${dir}/run"
    printf '%s\n' Battery > "${battery}/type"
    printf '%s\n' "${capacity}" > "${battery}/capacity"
    printf '%s\n' "${level}" > "${battery}/capacity_level"
    printf '%s\n' "${voltage_uv}" > "${battery}/voltage_now"
    printf '%s\n' "${present}" > "${battery}/present"
    printf '%s\n' USB > "${external}/type"
    printf '%s\n' "${external_online}" > "${external}/online"
    : > "${dir}/systemctl.log"
}

invoke() {
    local dir="$1" script="${2:-${policy}}" rc=0
    env -i PATH=/usr/bin:/bin \
        PF_SYSFS_ROOT="${dir}/sys" \
        PF_STATE_DIR="${dir}/run" \
        PF_SYSTEMCTL="${scratch}/systemctl" \
        PF_SYSTEMCTL_LOG="${dir}/systemctl.log" \
        PF_SYSTEMCTL_RC="${PF_SYSTEMCTL_RC:-0}" \
        bash "${script}" > "${dir}/stdout" 2> "${dir}/stderr" || rc=$?
    printf '%s' "${rc}"
}

expect_poweroff() {
    local label="$1" capacity="$2" level="$3" voltage_uv="$4"
    local dir="${scratch}/${label}" missed="${5:-0}"

    make_fixture "${dir}" "${capacity}" "${level}" "${voltage_uv}" 1 0
    [ "$(invoke "${dir}")" -eq 0 ] || fail "${label}: policy failed"
    [ "$(wc -l < "${dir}/systemctl.log")" -eq 1 ] \
        || fail "${label}: expected exactly one poweroff request"
    grep -Fx -- '--no-block poweroff' "${dir}/systemctl.log" >/dev/null \
        || fail "${label}: request was not an orderly systemctl poweroff"
    grep -Fx "missed_lvl1=${missed}" "${dir}/run/requested" >/dev/null \
        || fail "${label}: incorrect missed-LVL1 record"
}

expect_no_action() {
    local label="$1" capacity="$2" level="$3" voltage_uv="$4"
    local present="$5" external_online="$6" dir="${scratch}/${label}"

    make_fixture "${dir}" "${capacity}" "${level}" "${voltage_uv}" \
        "${present}" "${external_online}"
    [ "$(invoke "${dir}")" -eq 0 ] || fail "${label}: policy failed"
    [ ! -s "${dir}/systemctl.log" ] || fail "${label}: unexpected poweroff"
    [ ! -e "${dir}/run/requested" ] || fail "${label}: unexpected request marker"
}

# Thresholds and the independent voltage floor.
expect_poweroff soc-lvl1 5 Low 3600000 0
expect_poweroff soc-lvl2 0 Critical 3490000 1
expect_poweroff voltage-floor 80 Normal 3500000 0
expect_no_action safe 6 Normal 3500001 1 0
expect_no_action external-power 0 Critical 3400000 1 1
expect_no_action battery-absent 0 Critical 3400000 0 0

# Boot invokes the same oneshot without needing an event; this catches an alarm
# that arrived before userspace. The enablement assertion below proves the boot
# transaction actually starts it.
expect_poweroff boot-catches-earlier-irq 4 Low 3550000 0

# A second event after the first accepted request is coalesced by the durable
# /run marker. systemd additionally coalesces starts while the oneshot is active.
coalesce="${scratch}/coalesce"
make_fixture "${coalesce}" 5 Low 3600000 1 0
[ "$(invoke "${coalesce}")" -eq 0 ] || fail "coalesce: first run failed"
[ "$(invoke "${coalesce}")" -eq 0 ] || fail "coalesce: second run failed"
[ "$(wc -l < "${coalesce}/systemctl.log")" -eq 1 ] \
    || fail "coalesce: repeated event issued another poweroff"
grep -F 'decision=coalesced' "${coalesce}/stdout" >/dev/null \
    || fail "coalesce: repeated event was not recorded as coalesced"

# The merged alarm kernel does not currently expose capacity_level. Its
# absence is recorded, but cannot disable the numeric SOC safety threshold.
no_level="${scratch}/no-level"
make_fixture "${no_level}" 5 Low 3600000 1 0
rm "${no_level}/sys/class/power_supply/axp20x-battery/capacity_level"
[ "$(invoke "${no_level}")" -eq 0 ] || fail "missing capacity_level failed"
grep -Fx 'capacity_level=Unavailable' "${no_level}/run/requested" >/dev/null \
    || fail "missing capacity_level was not recorded"

# A rejected systemd request must release the latch so a later battery event
# can retry instead of being falsely coalesced forever.
systemctl_fail="${scratch}/systemctl-fail"
make_fixture "${systemctl_fail}" 5 Low 3600000 1 0
[ "$(PF_SYSTEMCTL_RC=1 invoke "${systemctl_fail}")" -ne 0 ] \
    || fail "failed systemctl request passed"
[ ! -e "${systemctl_fail}/run/requested" ] \
    || fail "failed systemctl request left a coalescing marker"

# Each valid safety signal remains authoritative when the other signal is
# unreadable or malformed. Unknown external-power state cannot suppress a
# proven critical condition; only a validated online=1 may do so.
missing_voltage="${scratch}/missing-voltage"
make_fixture "${missing_voltage}" 5 Low 3600000 1 0
rm "${missing_voltage}/sys/class/power_supply/axp20x-battery/voltage_now"
[ "$(invoke "${missing_voltage}")" -eq 0 ] || fail "missing voltage masked low SOC"
[ "$(wc -l < "${missing_voltage}/systemctl.log")" -eq 1 ] \
    || fail "missing voltage did not power off on low SOC"
grep -F 'degraded=voltage_unreadable' "${missing_voltage}/stderr" >/dev/null \
    || fail "missing voltage was not recorded as degraded evidence"

invalid_voltage="${scratch}/invalid-voltage"
make_fixture "${invalid_voltage}" 5 Low invalid 1 0
[ "$(invoke "${invalid_voltage}")" -eq 0 ] || fail "invalid voltage masked low SOC"
[ "$(wc -l < "${invalid_voltage}/systemctl.log")" -eq 1 ] \
    || fail "invalid voltage did not power off on low SOC"

missing_capacity="${scratch}/missing-capacity"
make_fixture "${missing_capacity}" 80 Normal 3500000 1 0
rm "${missing_capacity}/sys/class/power_supply/axp20x-battery/capacity"
[ "$(invoke "${missing_capacity}")" -eq 0 ] || fail "missing capacity masked low voltage"
[ "$(wc -l < "${missing_capacity}/systemctl.log")" -eq 1 ] \
    || fail "missing capacity did not power off on low voltage"
grep -F 'degraded=capacity_unreadable' "${missing_capacity}/stderr" >/dev/null \
    || fail "missing capacity was not recorded as degraded evidence"

invalid_capacity="${scratch}/invalid-capacity"
make_fixture "${invalid_capacity}" invalid Normal 3500000 1 0
[ "$(invoke "${invalid_capacity}")" -eq 0 ] || fail "invalid capacity masked low voltage"
[ "$(wc -l < "${invalid_capacity}/systemctl.log")" -eq 1 ] \
    || fail "invalid capacity did not power off on low voltage"

missing_external="${scratch}/missing-external"
make_fixture "${missing_external}" 5 Low 3600000 1 0
rm "${missing_external}/sys/class/power_supply/axp20x-usb/online"
[ "$(invoke "${missing_external}")" -eq 0 ] || fail "missing external state masked low SOC"
[ "$(wc -l < "${missing_external}/systemctl.log")" -eq 1 ] \
    || fail "missing external state did not power off on low SOC"
grep -F 'degraded=external_power_unreadable' "${missing_external}/stderr" >/dev/null \
    || fail "missing external state was not recorded as degraded evidence"

invalid_external="${scratch}/invalid-external"
make_fixture "${invalid_external}" 80 Normal 3500000 1 invalid
[ "$(invoke "${invalid_external}")" -eq 0 ] || fail "invalid external state masked low voltage"
[ "$(wc -l < "${invalid_external}/systemctl.log")" -eq 1 ] \
    || fail "invalid external state did not power off on low voltage"

no_threshold_evidence="${scratch}/no-threshold-evidence"
make_fixture "${no_threshold_evidence}" 80 Normal 3600000 1 0
rm "${no_threshold_evidence}/sys/class/power_supply/axp20x-battery/capacity"
rm "${no_threshold_evidence}/sys/class/power_supply/axp20x-battery/voltage_now"
[ "$(invoke "${no_threshold_evidence}")" -ne 0 ] \
    || fail "missing all threshold evidence passed"
[ ! -s "${no_threshold_evidence}/systemctl.log" ] \
    || fail "missing all threshold evidence powered off without a proven threshold"

# Mutation control: the same low-voltage/high-SOC oracle must reject a policy
# that skips the 3500 mV floor.
mutant="${scratch}/skip-voltage-floor.sh"
# shellcheck disable=SC2016 # Match literal production-shell variables.
sed 's/elif \[ "${voltage_valid}" -eq 1 \] && \[ "${voltage_uv}" -le "${VOLTAGE_FLOOR_UV}" \]; then/elif false; then/' \
    "${policy}" > "${mutant}"
chmod 0755 "${mutant}"
grep -F 'elif false; then' "${mutant}" >/dev/null \
    || fail "voltage-floor mutant did not apply"
mutant_case="${scratch}/mutant"
make_fixture "${mutant_case}" 80 Normal 3500000 1 0
[ "$(invoke "${mutant_case}" "${mutant}")" -eq 0 ] \
    || fail "voltage-floor mutant errored instead of exposing the defect"
[ ! -s "${mutant_case}/systemctl.log" ] \
    || fail "voltage-floor mutant unexpectedly retained the floor"
echo "mutation skip-voltage-floor: caught"

# Deployment wiring: root-owned oneshot, enabled at boot, and explicitly
# retriggered on every battery change notification.
grep -Fx 'User=root' "${unit}" >/dev/null || fail "unit is not explicitly root-owned"
grep -Fx 'Type=oneshot' "${unit}" >/dev/null || fail "unit is not oneshot"
grep -Fx 'RuntimeDirectory=pocketforge-low-battery-shutdown' "${unit}" >/dev/null \
    || fail "unit runtime directory drifted"
grep -Fx 'RuntimeDirectoryPreserve=yes' "${unit}" >/dev/null \
    || fail "unit does not preserve the coalescing marker"
grep -Fx 'WantedBy=multi-user.target' "${unit}" >/dev/null \
    || fail "unit is not enabled for the boot-time check"
grep -F 'ACTION=="change", SUBSYSTEM=="power_supply", KERNEL=="axp20x-battery"' \
    "${rule}" >/dev/null || fail "udev rule does not select battery change events"
grep -F 'systemctl --no-block start pocketforge-low-battery-shutdown.service' \
    "${rule}" >/dev/null || fail "udev rule does not start the policy"
# shellcheck disable=SC2016 # Match literal builder variables.
grep -F '"${rootfs}/etc/systemd/system/multi-user.target.wants/${unit}"' \
    "${builder}" >/dev/null || fail "rootfs builder does not enable the boot check"
[ "$(stat -c %a "${policy}")" = 755 ] || fail "policy mode is not 0755"
[ "$(stat -c %a "${unit}")" = 644 ] || fail "unit mode is not 0644"
[ "$(stat -c %a "${rule}")" = 644 ] || fail "udev rule mode is not 0644"

for attr in capacity capacity_level voltage_now present online; do
    grep -F "${attr}" "${policy}" >/dev/null \
        || fail "policy does not read ${attr}"
done
if grep -Ei 'regmap|i2c|/dev/mem' "${policy}" >/dev/null; then
    fail "policy reaches below power-supply sysfs"
fi

# Exercise the capability producer and real builder function. The producer runs
# the kernel-owned semantic checker against the authenticated source archive and
# binds the result to that archive's repo/SHA. A feature-preserving descendant
# passes without an equality allowlist; pre-feature and unrelated sources do not.
[ -x "${capability_emitter}" ] || fail "missing kernel capability emitter"
capable_source="${scratch}/kernel-capable"
descendant_source="${scratch}/kernel-descendant"
ancestor_source="${scratch}/kernel-ancestor"
unrelated_source="${scratch}/kernel-unrelated"
mkdir -p "${capable_source}/scripts" "${ancestor_source}" \
    "${unrelated_source}/scripts"
cat > "${capable_source}/scripts/test-check-a133-axp717-low-soc.py" <<'EOF'
#!/usr/bin/env python3
print("PASS: semantic low-SOC capability fixture")
EOF
cp -a "${capable_source}" "${descendant_source}"
printf '%s\n' 'unrelated follow-on kernel change' > "${descendant_source}/later-change"
cat > "${unrelated_source}/scripts/test-check-a133-axp717-low-soc.py" <<'EOF'
#!/usr/bin/env python3
raise SystemExit("low-SOC capability absent")
EOF

emit_receipt() {
    local source="$1" output="$2" repo="$3" sha="$4"
    "${capability_emitter}" "${source}" "${output}" "${repo}" "${sha}" \
        > "${output}.log" 2>&1
}
exact_receipt="${scratch}/receipts/exact"
descendant_receipt="${scratch}/receipts/descendant"
ancestor_receipt="${scratch}/receipts/ancestor"
unrelated_receipt="${scratch}/receipts/unrelated"
mkdir -p "${scratch}/receipts"
emit_receipt "${capable_source}" "${exact_receipt}" kernel-sunxi-7.x \
    "${alarm_kernel_sha}"
emit_receipt "${descendant_source}" "${descendant_receipt}" kernel-sunxi-7.x \
    "${descendant_kernel_sha}"
emit_receipt "${ancestor_source}" "${ancestor_receipt}" kernel-sunxi-7.x \
    "${ancestor_kernel_sha}"
emit_receipt "${unrelated_source}" "${unrelated_receipt}" kernel-sunxi-7.x \
    "${unrelated_kernel_sha}"
grep -Fx 'result=present' "${exact_receipt}" >/dev/null \
    || fail "exact #106 source did not produce a capability receipt"
grep -Fx 'result=present' "${descendant_receipt}" >/dev/null \
    || fail "feature-preserving descendant did not produce a capability receipt"
grep -Fx 'result=absent' "${ancestor_receipt}" >/dev/null \
    || fail "pre-#106 source falsely produced a capability receipt"
grep -Fx 'result=absent' "${unrelated_receipt}" >/dev/null \
    || fail "unrelated source falsely produced a capability receipt"

install_fn="${scratch}/install-low-battery-shutdown.sh"
awk '/^install_low_battery_shutdown\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' \
    "${builder}" > "${install_fn}"
[ "$(tail -n 1 "${install_fn}")" = '}' ] \
    || fail "could not extract install_low_battery_shutdown"
install_tree_from() {
    local function_file="$1" dest="$2" kernel="$3" sha="$4"
    local receipt="$5" device="$6"
    mkdir -p "${dest}"
    # shellcheck disable=SC2016 # Positional parameters expand in the inner bash.
    env -i PATH=/usr/bin:/bin bash -c \
        'set -euo pipefail; source "$1"; install_low_battery_shutdown "$2" "$3" "$4" "$5" "$6" "$7"' \
        _ "${function_file}" "${dest}" "${kernel}" "${sha}" "${receipt}" \
        "${device}" "${root}" \
        > "${dest}.log"
}
install_tree() {
    install_tree_from "${install_fn}" "$@"
}
install_tree "${scratch}/installed" kernel-sunxi-7.x "${alarm_kernel_sha}" \
    "${exact_receipt}" a133-open-7x-gpu
install_tree "${scratch}/descendant" kernel-sunxi-7.x "${descendant_kernel_sha}" \
    "${descendant_receipt}" a133-open-7x-gpu
for rel in \
    usr/lib/pocketforge/low-battery-shutdown.sh \
    etc/systemd/system/pocketforge-low-battery-shutdown.service \
    etc/udev/rules.d/81-pocketforge-low-battery-shutdown.rules; do
    [ -f "${scratch}/installed/${rel}" ] || fail "builder omitted ${rel}"
done
[ "$(readlink "${scratch}/installed/etc/systemd/system/multi-user.target.wants/pocketforge-low-battery-shutdown.service")" = \
    /etc/systemd/system/pocketforge-low-battery-shutdown.service ] \
    || fail "builder enablement link drifted"
if install_tree "${scratch}/wrong-kernel" kernel-sunxi-6.x "${alarm_kernel_sha}" \
    "${exact_receipt}" a133-open-7x-gpu; then
    fail "A133 image accepted the wrong kernel repository"
fi
if install_tree "${scratch}/pre-alarm-kernel" kernel-sunxi-7.x "${ancestor_kernel_sha}" \
    "${ancestor_receipt}" a133-open-7x-gpu; then
    fail "A133 image accepted a kernel revision without #106"
fi
if install_tree "${scratch}/unrelated-kernel" kernel-sunxi-7.x "${unrelated_kernel_sha}" \
    "${unrelated_receipt}" a133-open-7x-gpu; then
    fail "A133 image accepted an unrelated kernel without the capability"
fi
if install_tree "${scratch}/stale-receipt" kernel-sunxi-7.x "${descendant_kernel_sha}" \
    "${exact_receipt}" a133-open-7x-gpu; then
    fail "A133 image accepted a capability receipt from another kernel SHA"
fi
install_tree "${scratch}/wrong-device" kernel-sunxi-7.x '' /dev/null unrelated-device
[ -z "$(find "${scratch}/wrong-device" -mindepth 1 -print -quit)" ] \
    || fail "policy shipped on an unrelated device"

# Mutation control: reintroducing exact equality must reject the simulated
# feature-preserving descendant that the production capability gate accepts.
equality_mutant="${scratch}/install-equality-mutant.sh"
sed "/local unit=/a\\    [ \"\${kernel_sha}\" = \"${alarm_kernel_sha}\" ] || return 1" \
    "${install_fn}" > "${equality_mutant}"
grep -F "[ \"\${kernel_sha}\" = \"${alarm_kernel_sha}\" ] || return 1" \
    "${equality_mutant}" >/dev/null || fail "equality mutant did not apply"
if install_tree_from "${equality_mutant}" "${scratch}/equality-mutant" \
    kernel-sunxi-7.x "${descendant_kernel_sha}" "${descendant_receipt}" \
    a133-open-7x-gpu; then
    fail "exact-equality mutant accepted a feature-preserving descendant"
fi
echo "mutation exact-kernel-equality: caught"

# shellcheck disable=SC2016 # Match literal builder expansion in hook command.
grep -F 'PF_KERNEL_SHA=${PF_KERNEL_SHA}' "${builder}" >/dev/null \
    || fail "rootfs builder does not authenticate PF_KERNEL_SHA in the customize hook"
# shellcheck disable=SC2016 # Match literal builder expansion in hook command.
grep -F 'PF_KERNEL_CAPABILITY_RECEIPT=${PF_KERNEL_CAPABILITY_RECEIPT}' "${builder}" >/dev/null \
    || fail "rootfs builder does not pass the kernel capability receipt to the hook"
grep -F 'COPY --from=kernel /out/build/capabilities /work/kernel-capabilities' \
    "${dockerfile}" >/dev/null || fail "rootfs stage does not receive kernel capabilities"
grep -F 'COPY --chmod=0555 --from=image-src scripts/emit-axp717-low-soc-capability.sh' \
    "${dockerfile}" >/dev/null || fail "kernel stage does not receive the capability emitter"
grep -F '/work/kernel /out/build/capabilities/axp717-low-soc-alarm-irqs-v1' \
    "${dockerfile}" >/dev/null || fail "kernel stage does not verify its authenticated source"
if grep -F "${alarm_kernel_sha}" "${builder}" "${capability_emitter}" "${dockerfile}" \
    >/dev/null; then
    fail "production capability gate contains an exact #106 SHA allowlist"
fi

echo "PASS low-battery shutdown thresholds, external-power hold, coalescing, boot/event wiring, sysfs-only policy, and voltage-floor mutant"
