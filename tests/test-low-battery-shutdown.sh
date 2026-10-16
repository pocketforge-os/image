#!/usr/bin/env bash
# Hermetic contract for the AXP717 low-battery userspace shutdown policy.
set -euo pipefail
umask 022

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${root}/rootfs-overlay/usr/lib/pocketforge/low-battery-shutdown.sh"
unit="${root}/rootfs-overlay/etc/systemd/system/pocketforge-low-battery-shutdown.service"
rule="${root}/rootfs-overlay/etc/udev/rules.d/81-pocketforge-low-battery-shutdown.rules"
builder="${root}/scripts/build-rootfs.sh"
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

# Unreadable mandatory evidence must not silently become a threshold result.
unreadable="${scratch}/unreadable"
make_fixture "${unreadable}" 5 Low 3600000 1 0
rm "${unreadable}/sys/class/power_supply/axp20x-battery/voltage_now"
[ "$(invoke "${unreadable}")" -ne 0 ] || fail "unreadable voltage passed"
[ ! -s "${unreadable}/systemctl.log" ] || fail "unreadable voltage powered off"

# Mutation control: the same low-voltage/high-SOC oracle must reject a policy
# that skips the 3500 mV floor.
mutant="${scratch}/skip-voltage-floor.sh"
sed 's/elif \[ "${voltage_uv}" -le "${VOLTAGE_FLOOR_UV}" \]; then/elif false; then/' \
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
grep -F 'multi-user.target.wants/pocketforge-low-battery-shutdown.service' \
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

echo "PASS low-battery shutdown thresholds, external-power hold, coalescing, boot/event wiring, sysfs-only policy, and voltage-floor mutant"
