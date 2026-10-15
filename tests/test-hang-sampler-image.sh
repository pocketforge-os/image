#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${root}/scripts/check-hang-sampler-image.py"
args=(--root "${root}")
if [ -n "${PF_HANG_RUNTIME_ROOT:-}" ]; then
    args+=(--runtime-root "${PF_HANG_RUNTIME_ROOT}")
fi
python3 "${checker}" "${args[@]}"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/hang-sampler-image.XXXXXX")"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT
mkdir -p "${scratch}/scripts" "${scratch}/build"
cp -a "${root}/rootfs-overlay" "${scratch}/rootfs-overlay"
cp "${root}/scripts/build-rootfs.sh" "${scratch}/scripts/build-rootfs.sh"
cp "${root}/build/Dockerfile.pf" "${scratch}/build/Dockerfile.pf"

if [ -n "${PF_HANG_RUNTIME_ROOT:-}" ]; then
    mkdir -p "${scratch}/runtime/systemd" \
        "${scratch}/runtime/crates/pf-input-broker/systemd"
    cp "${PF_HANG_RUNTIME_ROOT}/systemd/pf-session-authorityd.service" \
        "${scratch}/runtime/systemd/pf-session-authorityd.service"
    cp "${PF_HANG_RUNTIME_ROOT}/crates/pf-input-broker/systemd/pf-input-broker.service" \
        "${scratch}/runtime/crates/pf-input-broker/systemd/pf-input-broker.service"
    sed -i '/^ExecStart=/s/$/ --fake-runtime-flag/' \
        "${scratch}/runtime/systemd/pf-session-authorityd.service"
    if python3 "${checker}" --root "${root}" --runtime-root "${scratch}/runtime" \
        >"${scratch}/execstart.out" 2>"${scratch}/execstart.err"; then
        echo "FAIL: hang sampler policy accepted paired runtime ExecStart drift" >&2
        exit 1
    fi
    grep -F 'authority ExecStart drift' "${scratch}/execstart.err" >/dev/null
fi

expect_refusal() {
    local reason="$1"
    if python3 "${checker}" --root "${scratch}" >"${scratch}/check.out" 2>"${scratch}/check.err"; then
        echo "FAIL: hang sampler policy accepted negative control: ${reason}" >&2
        exit 1
    fi
    grep -F "${reason}" "${scratch}/check.err" >/dev/null
}

service="${scratch}/rootfs-overlay/etc/systemd/system/pf-hang-sampler.service"
cp "${service}" "${scratch}/service.clean"
sed -i 's/CapabilityBoundingSet=CAP_SYS_PTRACE/CapabilityBoundingSet=CAP_SYS_PTRACE CAP_SYS_ADMIN/' "${service}"
expect_refusal 'sampler CapabilityBoundingSet must contain only CAP_SYS_PTRACE'
cp "${scratch}/service.clean" "${service}"

socket_unit="${scratch}/rootfs-overlay/etc/systemd/system/pf-hang-sampler.socket"
sed -i 's/SocketMode=0660/SocketMode=0666/' "${socket_unit}"
expect_refusal 'sampler socket unit: missing exact line: SocketMode=0660'
cp "${root}/rootfs-overlay/etc/systemd/system/pf-hang-sampler.socket" "${socket_unit}"

printf 'm pf-ime pf-hang-trigger\n' >>"${scratch}/rootfs-overlay/usr/lib/sysusers.d/pf-hang-sampler.conf"
expect_refusal 'trigger group membership must be exactly'
cp "${root}/rootfs-overlay/usr/lib/sysusers.d/pf-hang-sampler.conf" \
    "${scratch}/rootfs-overlay/usr/lib/sysusers.d/pf-hang-sampler.conf"

sed -i 's/ --systemd-socket/ --socket \/run\/pocketforge\/hang-sampler.sock/' "${service}"
expect_refusal 'production sampler service must never use path-bind --socket'
cp "${scratch}/service.clean" "${service}"

printf '\n[Service]\nSlice=pf-app.slice\n' \
    >>"${scratch}/rootfs-overlay/etc/systemd/system/pf-app@.service.d/30-cursor-theme.conf"
expect_refusal 'pf-app unit must keep default dedicated slice placement'
cp "${root}/rootfs-overlay/etc/systemd/system/pf-app@.service.d/30-cursor-theme.conf" \
    "${scratch}/rootfs-overlay/etc/systemd/system/pf-app@.service.d/30-cursor-theme.conf"

printf '\n[Service]\nCapabilityBoundingSet=CAP_SYS_PTRACE\n' \
    >>"${scratch}/rootfs-overlay/etc/systemd/system/pf-osk.service.d/10-pf-ime-sandbox.conf"
expect_refusal 'CAP_SYS_PTRACE granted outside sampler service'
cp "${root}/rootfs-overlay/etc/systemd/system/pf-osk.service.d/10-pf-ime-sandbox.conf" \
    "${scratch}/rootfs-overlay/etc/systemd/system/pf-osk.service.d/10-pf-ime-sandbox.conf"

printf 'kernel.yama.ptrace_scope = 0\n' \
    >"${scratch}/rootfs-overlay/etc/sysctl.d/99-bad-ptrace.conf"
expect_refusal 'image must not set or lower kernel.yama.ptrace_scope'
find "${scratch}/rootfs-overlay/etc/sysctl.d/99-bad-ptrace.conf" -maxdepth 0 -delete

printf '\n# bad enable: multi-user.target.wants/pf-hang-sampler.service\n' \
    >>"${scratch}/scripts/build-rootfs.sh"
expect_refusal 'sampler service must be socket-activated, not enabled at boot'

echo 'PASS: hang sampler image policy negative controls were refused'
